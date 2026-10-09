import { ThreadId } from "@t3tools/contracts";
import { assert, describe, it } from "@effect/vitest";
import * as Effect from "effect/Effect";
import * as Queue from "effect/Queue";
import * as Stream from "effect/Stream";

import * as PromptSuggestions from "./PromptSuggestions.ts";

const threadA = ThreadId.make("thread-a");
const threadB = ThreadId.make("thread-b");

describe("PromptSuggestions", () => {
  it.effect("streams the current suggestion first, then only its thread's changes", () =>
    Effect.gen(function* () {
      const store = yield* PromptSuggestions.make;
      yield* store.set(threadA, "Run the tests");
      const received = yield* Queue.unbounded<string | null>();
      yield* store.stream(threadA).pipe(
        Stream.runForEach((value) => Queue.offer(received, value)),
        Effect.forkScoped,
      );
      assert.equal(yield* Queue.take(received), "Run the tests");
      yield* store.set(threadB, "Other thread");
      yield* store.clear(threadA);
      assert.equal(yield* Queue.take(received), null);
      yield* store.set(threadA, "Commit it");
      assert.equal(yield* Queue.take(received), "Commit it");
      assert.equal(yield* Queue.size(received), 0);
    }),
  );

  it.effect("starts a stream with null when the thread has no suggestion", () =>
    Effect.gen(function* () {
      const store = yield* PromptSuggestions.make;
      yield* store.set(threadB, "Elsewhere");
      const first = yield* store.stream(threadA).pipe(Stream.take(1), Stream.runCollect);
      assert.deepEqual(Array.from(first), [null]);
    }),
  );
});
