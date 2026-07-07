# Discuss Chat: Intent-Driven Drafts + Docked Input — Design

**Date:** 2026-07-07
**Status:** Approved by owner (live-testing feedback round)
**Amends:** `docs/superpowers/specs/2026-07-07-situation-discuss-chat-design.md`

## Problems (owner feedback after live use)

1. **The Draft reply button is wrong.** It asks the model to invent a reply
   with no input from the owner. The owner decides WHAT to say; the
   secretary's job is turning that intent into a polished, ready-to-send
   message in the owner's voice.
2. **The chat input doesn't render.** `ChatInput` wraps an `NSTextView`
   inside a nested `NSScrollView`; every prior consumer (main Chat, Target
   chat) docks it OUTSIDE the scrolling content. The Discuss section placed
   it inside `SituationReviewPane`'s `ScrollView`, where the nested AppKit
   scroll view collapses — the owner had nowhere to type.

## Changes

### 1. Intent-driven draft contract (no button)

- Remove `draftReply()` and `draftRequestText` from `SituationChatViewModel`
  and the "Draft reply" button from the UI.
- Rewrite the system prompt's DRAFT CONTRACT: when the user states what to
  reply (their intent — "tell them we'll roll back tomorrow"), produce
  ready-to-send Slack text in the owner's voice (thread language, owner's
  register with these people), preserving the user's meaning and **adding no
  commitments or content they didn't state**. Draft as a plain copyable
  block; commentary after, clearly separated. Without a stated intent,
  discuss and advise — never push an unsolicited draft.
- Empty-state copy: "Tell me what to reply — I'll draft it in your voice.
  Or just ask about this situation."
- Input placeholder: "Tell me what to reply, or ask about this situation…"

### 2. Docked input (bug fix)

- `SituationReviewPane` owns the Discuss state: `@State discussExpanded`,
  `@State chatVM: SituationChatViewModel?` (still reset per situation by the
  pane's existing `.id(situation.id)`).
- In the scroll content, the Discuss section keeps only the collapsed header
  (badge unchanged) and, when expanded, the message bubbles.
- When expanded, the pane renders `ChatInput` (+ inline error label) docked
  BELOW the ScrollView and ABOVE the action bar, outside any scroll — same
  placement pattern as `TargetChatSection`. Collapse still cancels a live
  stream and refreshes the badge.

## Non-changes

- Point 2 of the feedback round ("Generate from my messages" placement) —
  owner decided to leave it in the Profile tab as is.
- Style profile pipeline, people-card/register-sample prompt blocks,
  conversation persistence, inertness-while-collapsed: unchanged.

## Testing

- VM tests: drop the draft-button test; keep/adjust resumed-carry and
  stream tests; assert the new contract text markers in `buildSystemPrompt`
  (e.g. "adding no commitments", "unsolicited") replacing the old
  "ready-to-send" assertion if wording shifts.
- View gate: build + full suite + `make lint-swift`; owner smoke for the
  docked input.
- Docs: app-guide Discuss paragraph reworded (no Draft reply button;
  intent-flow); CLAUDE.md bullet's "Draft-reply contract" → intent-draft.
