# AI chats feed the knowledge base — decisions, facts and kept artifacts (2026-10-24)

Board: #907 (track "Knowledge storage"), part B of two; part A (owner instructions in every chat) shipped in PR #458. Owner decisions: asks #514, #516, #517, #545, #546, #548. Current-state audit: comment on #915.

## Intent and the why

The owner solves hard problems and changes the system's state in AI chats. What gets decided there stays in that chat: the agents in workbench sessions, the briefing, search and the next chat do not know it, and today it comes back only if the owner passes an artifact on and a source sync happens to pick it up again (ask #514). Part B makes what a chat settles reach the machine's knowledge base, so every consumer of `search_knowledge` sees it.

The owner's worst case is "quietly wrote a fabrication as fact" (ask #516). So: the owner's own words may be written at once; anything the model concluded becomes knowledge only after the owner approves a card (ask #517).

Success: a decision or fact settled in a chat shows up, after one approval or one prefix, when an agent or a later chat searches the knowledge base; nothing the model inferred is there without the owner's press.

## Goals

1. **Chats are a source of the ideas & decisions registry** (`internal/ideas`). A background pass, like the one for Slack (ask #546), reads AI chat conversations and proposes **decisions** ("we do X this way", "we dropped Y") and **facts / state changes** ("service X now lives in Y", "access moved to Z").
2. **The owner confirms them in Inbox → Ideas**, under **Needs your decision**, as today (ask #546). Approve makes the item active knowledge; Reject / Not now / Merge work as for any registry item. Each card links to the chat message it came from.
3. **The owner's own words are written at once** behind a prefix, like `запомни:` in part A: `решили:` / `decided:` → an active decision, `факт:` / `fact:` → an active fact, verbatim, with an inline mark and **Undo** (ask #546).
4. **A chat artifact the owner keeps goes into knowledge** through a **В знания** (Add to Knowledge) button on the artifact (ask #548), and can be taken out again.
5. Everything above is found by `search_knowledge`, so the workbench agents, every AI chat and the briefing see it with no further wiring.

## Non-goals

- Sync between the owner's Macs: knowledge stays on the machine where the chat was (ask #545).
- Knowledge from images (the track's other group, #908 — next).
- "Found fixes for problems" as a separate kind (not chosen in ask #546); a fix the owner wants kept is a fact, said with `факт:` or approved from a proposal.
- Redesigning memory (`internal/memory`) or its `remember:` chat ingest.
- Editing existing knowledge in place from a chat (e.g. rewriting a Confluence page). A chat decision can supersede an older registry decision through the existing **Supersede** action, nothing more.
- Phone surfaces.

## Anti-goals (a failure even if it works)

- A model conclusion is searchable as knowledge before the owner approved it — including as a "proposed" item an agent could read as fact.
- The owner's prefixed words are paraphrased, summarised or rewritten.
- A chat that nags ("Shall I save this as a decision?") during the conversation.
- Proposals that duplicate a decision already in the registry from Slack or a meeting instead of attaching to it.

## Current state (what exists)

- **Registry** (`ideas`, `idea_mentions`, `stream_digests`; feature note `docs/features/ideas-decisions-registry.md`, contracts IDEA-01..05 in `docs/inventory/ideas.md`). Stage 1 extracts candidates per source (Slack digests, meeting recaps, the light-tier `ideas.digest_email` / `ideas.digest_jira` passes into `stream_digests`); stage 2, `ideas.consolidate` (strong tier, the **Idea finder** built-in, every `ideas.mine_interval_hours`), turns them into `new_idea` / `new_decision` / `attach_mention` ops that Go validates (IDEA-02: no invented provenance) and applies; floors make each source mined once (IDEA-01). Kinds `idea` / `decision` / `note`. **Mined decisions are born `active` and never enter the review queue** (2026-08-12 split); ideas and notes are born `proposed` and wait under **Needs your decision**.
- **Knowledge search** (`internal/kb`, KB-01..03): the `idea` source indexes **every** registry row, any status, with `kind status` in its meta. AI chats are not a source of the registry or of the index.
- **Owner-created items**: Swift writes them directly (`IdeaQueries` create, `source='owner'`, status `active`, an `owner` mention carrying the text).
- **Chat artifacts** (`chat_artifacts`: `document`, `table`, `email`, `slack`, `event`, `code`, `html`, versioned per `artifact_key`): no "kept" or "approved" state; not indexed.
- **Part A** built the pattern this reuses: a shared Go/Swift prefix parser pinned by a fixture, the inline mark with Undo, chat turns read by a daily pass.

## The design

### 1. Chats as a registry source (model proposals)

- **Material:** AI chat conversations stored in `chat_messages` (every surface with `chat_conversations` rows; in-memory setup assistants have none), owner and assistant turns of the active branch, newer than a chat floor. A conversation is mined once it has been quiet for a while (builder picks the delay, e.g. 30 minutes), so a live discussion is not mined half-way. Turns already written by the direct prefix (§2) and remember turns (part A) are left out; pasted blocks and tool chatter are trimmed as for session feeds.
- **Pass shape:** conversations go straight into the regular stage-2 consolidation (see "Settled after the builder check"), which already dedups against the registry (`attach_mention` onto an existing Slack/meeting decision instead of a new one); from chat material it proposes decisions and facts only. Floor and ref rules: IDEA-01 and IDEA-02 extended to the new source, never relaxed — a candidate whose message ref is not a real `chat_messages` row is dropped and counted.
- **Kinds:** a decision → `kind='decision'`; a fact or state change → `kind='note'`.
- **Born proposed, decisions included.** A registry item **created from chat material alone** is born `proposed` and sits under **Needs your decision**, whatever its kind. This is a deliberate exception to "decisions never ask for approval", for the chat source only, because the owner's rule for chats is the card (ask #517). Slack/meeting/email/Jira decisions keep being born active. A chat mention attached to an existing item changes nothing about that item's status.
- **The card** shows the chat as the mention's source with a link that opens the conversation at the message (Swift already opens chats by id). Approve → `active`. All other verdicts unchanged (IDEA-04).

### 2. The owner's words, at once (prefix)

- **Trigger:** an owner message in any chat that carries owner instructions (part A's surfaces) whose first non-space characters are `решили:`, `decided:`, `факт:` or `fact:` (case-insensitive, the same normalisation rules as part A's `ParseRemember`). Everything after the colon, trimmed, is the text. Nothing else triggers it.
- **Effect:** a registry item written at once — `решили:`/`decided:` → `kind='decision'`, `факт:`/`fact:` → `kind='note'`; `source='owner'`, status `active`, essence = the text verbatim, title = its first line cut to the registry's title length; one mention with source `chat`, ref = the conversation and message, quote = the text. The message is still sent to the model as usual.
- **Mark:** under the owner's message, "Saved as a decision" / "Saved as a fact" with **Undo** (deletes that item if it has not been changed since; otherwise opens it) and **Open in Inbox**. Rebuilt on reopen from the mention's message ref. An empty text writes nothing and the mark says why.
- **Who writes:** Swift, directly through `IdeaQueries` (the owner-create precedent), with one shared Swift/Go parser pinned by a fixture (part A's `remember_cases.json` pattern; one parser and fixture for all prefixes is fine). The mined pass (§1) skips messages that carry a prefix.

### 3. Artifacts the owner keeps

- An artifact of kind `document`, `table`, `code` or `html` gets **В знания** / **Add to Knowledge** in its header (`email`, `slack`, `event` are drafts of messages, not knowledge).
- Pressing it pins **that version** as knowledge: a small table of kept artifacts (conversation, artifact key, version, kept at). A later version does not replace it silently: the header then shows **Update in Knowledge** for the newer version, and **Remove from Knowledge** removes it. The model never marks an artifact.
- A new knowledge source `chat_artifact` in `internal/kb` indexes each kept version (title, the conversation's title as meta, the content rendered as text; `html` stripped to text). Deleting the chat or the artifact removes the document (the reconcile already handles vanished ids).

### 4. What search sees

- The `idea` source in `internal/kb` skips registry items that **only chat material** backs while they are not `active` (proposed, not now, rejected, dropped): they enter the index when approved and leave it when rejected or reversed. Items from other sources are indexed as today.
- Owner-prefixed items (§2) and kept artifacts (§3) are active knowledge from the moment they are written.

## Settled after the builder check (my calls)

- **No stage-1 table for chats.** `stream_digests` is indexed for search (`internal/kb/source_derived.go` stream-digest source) and listed in Digests/Catch-Up, and needs an `account_id`, so chat candidates never go there. Chat conversations are rendered straight into the stage-2 `ideas.consolidate` material, as meeting transcripts already are (`addTranscripts`), behind a chat floor that advances only past rendered conversations (IDEA-01). This replaces the `ideas.digest_chat` stage-1 pass in §1; the prompt change is a version bump of `ideas.consolidate` (both providers).
- **Facts from chats:** stage 2 gains a `new_note` op that Go accepts **only when all its refs are chat refs**; for other sources it is dropped and counted like an invalid ref, so Slack/meeting/email/Jira behaviour does not change.
- **The chat-born mark is a column**, `ideas.chat_born` (0/1), set once at creation when every ref of the creating op is a chat ref (and for owner-prefixed items). It never changes afterwards. Go and Swift read the same column.
- **Status rule:** a chat-born item is created `proposed` (mined) or `active` (owner prefix). Evidence attached later from any source never activates it; only the owner's Approve does. Search skips `chat_born = 1 AND status != 'active'`.
- **Review queue:** it admits decisions only when `chat_born = 1` and they await a verdict by the existing idea rules; the decision card then gets the same verdict strip as an idea (Approve, Not now, Reject, Merge). Other decisions, `needs_review` ones included, stay informational as today.
- **Mined surfaces:** the part A surfaces (main chat, Ask Watchtower, target, track, meeting, code question, automation editor chats) except a Discuss chat about a registry item (`context_type = 'idea'`), which would propose its own item back. Setup assistants keep no rows anyway.
- **A deleted chat** leaves its registry items alone (approved knowledge is the owner's; a proposed one can still be judged); the card shows "chat deleted" instead of the link. Kept artifacts leave with the chat (§3).
- **Prefix path:** only on stored chats (every surface carrying owner instructions is stored); Swift writes the item through `IdeaQueries` as the owner-create sheet already does — no CLI, because the registry is already written by Swift and needs no Go-owned format.
- The Approve write must bump `ideas.updated_at`, which the `idea` index source's cursor watches.

## Constraints

- **Locked contracts:** IDEA-01..05 (`docs/inventory/ideas.md`) — extended to the chat source (floor, ref validation, dedup, verdict resurfacing); the "decisions born active" rule gains the chat exception, and the review-queue predicate (Go `CountIdeasForReview`, Swift `fetchForReview`/`countForReview`) admits chat-born proposed decisions. KB-01..03 (`docs/inventory/knowledge-search.md`) — the new source and the status filter for chat-only items. Both amendments need the owner's explicit approval with this document; guard tests are extended, never weakened.
- **Migrations:** `idea_mentions.source` CHECK gains `'chat'` (table-recreation dance, `add-migration` skill, carry the AUTOINCREMENT sequence as 00135 did); `ideas.chat_born`; a chat floor (workspace column, the `ideas_transcript_floor` precedent); the kept-artifacts table. Mirror into `schema.sql`, regenerate golden + Swift test schema.
- **Dual paths:** the prefix parser (Go + Swift, one fixture); the review-queue predicate (Go + Swift); the chat-only-and-not-active rule (Go index + any Swift reader that lists knowledge).
- **Model calls** outside any write transaction, prompt text on stdin (CHAT-04), the `planusage.NearLimit` skip, both providers.
- Public repo hygiene: no live chat text in tests or fixtures.
- User guide: the Inbox/Ideas page and the chat page gain the prefixes, the chat source and **Add to Knowledge** (`docs/guide/WRITING.md`, 8 KB cap).

## Left to the builder

- The quiet delay before a conversation is mined, and how a conversation that continues after being mined is picked up again (re-mine only the new turns above the floor is enough).
- Exact prompt wording and caps of `ideas.digest_chat`, the title cut, the mark's copy.
- The floor's storage, the kept-artifacts table shape, the KB document layout of a kept artifact.
- Whether `html` is rendered to text in Go or skipped if that proves heavy (then say so in the guide).
- Phasing (sensible order: storage + prefix path → kept artifacts → mined chat source → search filter and docs; the search filter must ship with or before the mined source).

## Calls made by me (for the owner to check)

1. Chats become one more source of the existing registry; the confirmation card is the existing Inbox → Ideas review, not a new screen.
2. Chat-born decisions wait for Approve, unlike decisions mined from Slack — your card rule for chats wins over the registry's "decisions are a quiet journal".
3. Unapproved chat proposals stay out of `search_knowledge` entirely, not just labelled "proposed".
4. A fact is the registry's `note` kind; no new kind.
5. **Add to Knowledge** pins the version you pressed it on; a newer version needs **Update in Knowledge**. Only documents, tables, code and html get the button.
6. The mined pass reads both your turns and the assistant's answers (a decision is often worded by the assistant and agreed by you); what it proposes still waits for your Approve.
