import * as Schema from "effect/Schema";

import { ThreadId } from "./baseSchemas.ts";

export const PromptSuggestionSubscribeInput = Schema.Struct({
  threadId: ThreadId,
});
export type PromptSuggestionSubscribeInput = typeof PromptSuggestionSubscribeInput.Type;

/**
 * The provider's predicted next prompt for the thread, or null when there is
 * none. Sent first, then after every change. Ephemeral server memory: a new
 * turn or a server restart clears it.
 */
export const PromptSuggestionStreamEvent = Schema.NullOr(Schema.String);
export type PromptSuggestionStreamEvent = typeof PromptSuggestionStreamEvent.Type;
