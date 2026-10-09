import type { ThreadId } from "@t3tools/contracts";
import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as PubSub from "effect/PubSub";
import * as Queue from "effect/Queue";
import * as Ref from "effect/Ref";
import * as Stream from "effect/Stream";

/** Threads remembered at once; the oldest suggestion is dropped past this. */
const MAX_TRACKED_THREADS = 256;

/**
 * Latest provider-predicted next prompt per thread (Claude's
 * `prompt_suggestion`). Deliberately ephemeral: nothing is persisted or
 * event-sourced, so a suggestion lives only until the thread's next turn
 * starts or the server restarts. Adapters write through `set`/`clear`;
 * clients read the current value and later changes through `stream`.
 *
 * The default reference drops writes and streams null, which keeps adapter
 * construction dependency-free in tests. The live layer must be the same
 * layer reference for the adapter infrastructure and the WebSocket handlers
 * so layer memoization yields one shared store.
 */
export interface PromptSuggestionsShape {
  readonly set: (threadId: ThreadId, suggestion: string) => Effect.Effect<void>;
  readonly clear: (threadId: ThreadId) => Effect.Effect<void>;
  /** Emits the current suggestion (or null) first, then every change. */
  readonly stream: (threadId: ThreadId) => Stream.Stream<string | null>;
}

export class PromptSuggestions extends Context.Reference<PromptSuggestionsShape>(
  "t3/orchestration-v2/PromptSuggestions",
  {
    defaultValue: () => ({
      set: () => Effect.void,
      clear: () => Effect.void,
      stream: () => Stream.make(null),
    }),
  },
) {}

export const make: Effect.Effect<PromptSuggestionsShape> = Effect.gen(function* () {
  const suggestions = yield* Ref.make(new Map<ThreadId, string>());
  const changes = yield* PubSub.unbounded<{
    readonly threadId: ThreadId;
    readonly suggestion: string | null;
  }>();

  const publish = (threadId: ThreadId, suggestion: string | null) =>
    PubSub.publish(changes, { threadId, suggestion }).pipe(Effect.asVoid);

  const set = (threadId: ThreadId, suggestion: string) =>
    Ref.update(suggestions, (current) => {
      const next = new Map(current);
      // Re-insert so iteration order tracks recency for the size cap.
      next.delete(threadId);
      next.set(threadId, suggestion);
      for (const oldest of next.keys()) {
        if (next.size <= MAX_TRACKED_THREADS) break;
        next.delete(oldest);
      }
      return next;
    }).pipe(Effect.andThen(publish(threadId, suggestion)));

  const clear = (threadId: ThreadId) =>
    Ref.modify(suggestions, (current) => {
      if (!current.has(threadId)) return [false, current] as const;
      const next = new Map(current);
      next.delete(threadId);
      return [true, next] as const;
    }).pipe(Effect.flatMap((removed) => (removed ? publish(threadId, null) : Effect.void)));

  // One-slot sliding mailbox per subscriber: only the newest value matters.
  const stream = (threadId: ThreadId) =>
    Stream.callback<string | null>(
      (mailbox) =>
        Effect.gen(function* () {
          const subscription = yield* PubSub.subscribe(changes);
          const initial = (yield* Ref.get(suggestions)).get(threadId) ?? null;
          Queue.offerUnsafe(mailbox, initial);
          yield* Stream.fromSubscription(subscription).pipe(
            Stream.runForEach((change) =>
              Effect.sync(() => {
                if (change.threadId === threadId) Queue.offerUnsafe(mailbox, change.suggestion);
              }),
            ),
            Effect.forkScoped,
          );
        }),
      { bufferSize: 1, strategy: "sliding" },
    );

  return { set, clear, stream };
});

export const layer = Layer.effect(PromptSuggestions, make);
