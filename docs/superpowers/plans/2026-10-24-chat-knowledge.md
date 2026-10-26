# AI chats feed the knowledge base — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Decisions and facts settled in AI chats, and artifacts the owner keeps, reach `search_knowledge` — model proposals only after the owner's Approve in Inbox → Ideas, the owner's prefixed words at once.

**Architecture:** Chats become one more source of the ideas & decisions registry: chat turns are rendered straight into the stage-2 `ideas.consolidate` material behind a chat floor, and a chat-born item (`ideas.chat_born = 1`) waits for Approve and stays out of every agent-visible reader until it is active. The owner's `решили:`/`факт:` messages are written by Swift through `IdeaQueries`, like the owner-create sheet. Kept artifacts are pinned versions in a new table, indexed by a new `chat_artifact` KB source.

**Tech Stack:** Go 1.26 (`internal/ideas`, `internal/kb`, `internal/db`, `internal/tools`, goose migrations), SwiftUI + GRDB (WatchtowerCore, Desktop).

**Spec:** `docs/superpowers/specs/2026-10-24-chat-knowledge-design.md` (approved, ask #551 — including the IDEA and KB contract amendments).

## Global Constraints

- Prefixes, exact: `решили:`, `decided:` → kind `decision`; `факт:`, `fact:` → kind `note`. Case-insensitive, leading whitespace skipped, same Unicode handling as part A's `ParseRemember` (NBSP/NEL as space, `İ` lowered, combining marks kept). The body is the text after the colon **trimmed, otherwise verbatim** (newlines kept — unlike remember, which collapses to one line).
- Chat mention: `idea_mentions.source = 'chat'`, `ref = "chat:<conversation_id>:<message_id>"`.
- `ideas.chat_born` (INTEGER 0/1) is set once at creation, never updated.
- Hidden from agents/search: `chat_born = 1 AND status != 'active'`. One Go SQL fragment, one Swift twin.
- Quiet rule: a chat message is minable once `created_at <= now − 30 min`.
- Mined surfaces: every `chat_conversations` row except `context_type = 'idea'`.
- Kept artifacts: kinds `document`, `table`, `code`, `html` only.
- Model call outside any write transaction; prompt on stdin; `planusage.NearLimit` skip unchanged; both providers.
- IDEA-01..05 and KB-01..03 guard tests are extended, never weakened, renamed or split.
- Public repo hygiene: no live chat text in tests or fixtures.
- Inner loop per task (CLAUDE.md "Agent-driven runs"); Swift briefs include `make lint-swift` (lint-diff is Go-only).

## Review Focus

1. A chat-born proposed decision reaching an agent through any reader — `search_knowledge`, `list_ideas`/`get_idea`, Catch-Up decisions, the Decisions ledger badge. Pinned in Task 3.
2. Slack/meeting evidence attached to a proposed chat-born item activating it or making it searchable. Pinned in Task 4.
3. A `new_note` op citing a Slack ref creating a note (must be dropped and counted). Pinned in Task 4.
4. The chat floor skipping a message: a conversation still within the quiet window, or a budget-dropped message, buried under the floor. Pinned in Task 4 (IDEA-01 guards).
5. Undo of a prefixed decision the owner already edited or approved/merged deleting their work. Pinned in Task 6.

---

### Task 1: Storage — migration 00154

**Depends on:** none

**Files:**
- Create: `internal/db/migrations/00154_chat_knowledge.sql`
- Modify: `internal/db/schema.sql`, `internal/db/ideas.go` (Idea struct, `CreateIdeaTx`, floor accessors), `internal/db/db_test.go` (`TestAllTablesExist`), `internal/db/testdata/schema_v*.golden`, `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift` (regenerated)
- Create: `internal/db/chat_knowledge.go`, `internal/db/chat_knowledge_test.go`

**Interfaces:**
- Produces:
  - `ideas.chat_born INTEGER NOT NULL DEFAULT 0`; `db.Idea.ChatBorn bool`, written by `CreateIdeaTx`.
  - `idea_mentions.source` CHECK gains `'chat'` (table recreation, carry the AUTOINCREMENT sequence as 00135 did; one-transaction rebuild per CLAUDE.md).
  - `workspace.ideas_chat_floor INTEGER NOT NULL DEFAULT 0` (highest `chat_messages.id` consumed); migration seeds it to the current `MAX(chat_messages.id)` (the 00050 precedent: no backfill of history). `db.GetIdeasChatFloor() (int64, error)`, `db.SetIdeasChatFloorTx(tx, id int64) error`.
  - Table `chat_knowledge_artifacts(conversation_id INTEGER NOT NULL REFERENCES chat_conversations(id) ON DELETE CASCADE, artifact_key TEXT NOT NULL, version INTEGER NOT NULL, kept_at TEXT NOT NULL, PRIMARY KEY(conversation_id, artifact_key))`.
  - `db.ListChatTurnsForIdeas(afterID int64, cutoffISO string, limit int) ([]ChatTurnForIdeas, error)` — `ChatTurnForIdeas{ID, ConversationID int64; ConversationTitle, Role, Text, CreatedAt string}`, rows of `chat_messages` with `id > afterID`, `created_at <= cutoff`, role `user`/`assistant`, on the active branch (reuse part A's `activeBranchCTE`/`onActiveBranch`), conversation `context_type != 'idea'`, ordered by `id`.
  - `db.KnowledgeVisibleIdeaSQL` (string const, column-qualified by an alias parameter or written for alias `ideas`): `NOT (chat_born = 1 AND status != 'active')`.

- [ ] **Step 1:** Write `TestMigration00154_ChatKnowledge` (in `internal/db/chat_knowledge_test.go`): after migrating, an `idea_mentions` row with source `chat` inserts; one with source `bogus` fails the CHECK; existing mention rows and the `idea_mentions` sqlite_sequence survive; `ideas.chat_born` defaults 0; `workspace.ideas_chat_floor` equals the pre-migration max chat message id; deleting a conversation deletes its `chat_knowledge_artifacts` rows.
- [ ] **Step 2:** Write `TestListChatTurnsForIdeas`: skips `context_type='idea'` conversations, rows newer than the cutoff, rows at or below `afterID`, and off-branch rows; returns id order.
- [ ] **Step 3:** Run `go test ./internal/db -run 'Migration00154|ListChatTurnsForIdeas'` — FAIL.
- [ ] **Step 4:** Write the migration (follow `add-migration`; `00150_builtin_automations.sql` for the rebuild shape), the accessors, mirror `schema.sql`, add the table to `TestAllTablesExist`, regenerate (`go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`).
- [ ] **Step 5:** `go test ./internal/db` — PASS; `make lint-diff`.
- [ ] **Step 6:** Commit `feat(db): chat knowledge storage — chat mentions, chat_born, chat floor, kept artifacts`.

### Task 2: The knowledge prefix parser (Go) and its fixture

**Depends on:** none

**Files:**
- Create: `internal/ideas/chatprefix.go`, `internal/ideas/chatprefix_test.go`, `internal/ideas/testdata/knowledge_prefix_cases.json`

**Interfaces:**
- Produces: `ideas.ParseKnowledgePrefix(text string) (kind, body string, ok bool)` — kind `"decision"` or `"note"`; `ok` true with an empty body for `решили:   `.
- Fixture rows: `{"text", "ok", "kind", "body"}`. Must include at least: `решили: переезжаем на X` → decision/`переезжаем на X`; `ФАКТ:  сервис в Y` → note; `Decided:x` → decision/`x`; `fact:\nline 1\nline 2` → note/`line 1\nline 2` (newlines kept); `fact:   ` → ok, empty body; `мы решили: x` → not ok; `решили x` → not ok; NBSP after the colon; NEL before the prefix; `remember: x` → not ok; empty text → not ok.

- [ ] **Step 1:** Write `TestParseKnowledgePrefix_Fixture` reading the fixture (the `internal/instructions/remember_test.go` pattern).
- [ ] **Step 2:** Run `go test ./internal/ideas -run ParseKnowledgePrefix` — FAIL.
- [ ] **Step 3:** Implement, sharing the whitespace/lowering helpers' behaviour with `internal/instructions/remember.go` (copy is fine; do not import `instructions` into `ideas` if it creates a cycle).
- [ ] **Step 4:** PASS; `make lint-diff`. Commit `feat(ideas): knowledge prefix parser with a shared fixture`.

### Task 3: Hide unapproved chat-born items from every agent-visible reader

**Depends on:** Task 1

**Files:**
- Modify: `internal/kb/source_derived.go` (`ideaSource.Changed`/`Keys`/`Build`), `internal/tools/ideas.go` + `internal/db/ideas.go` (`ListIdeas`, the `get_idea` read), `internal/db/catchup.go` (`ListCatchupDecisions`), `internal/db/ideas.go` (`CountIdeasForReview`)
- Test: `internal/kb/source_derived_test.go`, `internal/tools/ideas_test.go`, `internal/db/catchup_test.go`, `internal/db/ideas_test.go`

**Interfaces:**
- Consumes: `db.KnowledgeVisibleIdeaSQL`, `ideas.chat_born`.
- Produces: `CountIdeasForReview` counts `(status='proposed' OR needs_review=1) AND (kind != 'decision' OR chat_born = 1)`.

- [ ] **Step 1:** Tests:
  - `TestKB_IdeaSourceSkipsUnapprovedChatBorn` (KB-contract name per `docs/inventory/knowledge-search.md` numbering): a chat-born `proposed` decision is not in `Keys`, `Build` returns nil; after status → `active` (with `updated_at` bumped) it is indexed; after → `rejected` it leaves on the next run. A non-chat `proposed` idea is still indexed (unchanged).
  - `TestListIdeas_HidesUnapprovedChatBorn`, `TestGetIdea_UnapprovedChatBornNotFound` (the tool answers as for a missing id).
  - `TestCatchupDecisions_SkipUnapprovedChatBorn`.
  - `TestCountIdeasForReview_CountsChatBornDecisions`: a chat-born proposed decision counts; a mined Slack decision with `needs_review=1` still does not.
- [ ] **Step 2:** Run the four packages' new tests — FAIL.
- [ ] **Step 3:** Apply `KnowledgeVisibleIdeaSQL` in each reader; the review count change in `CountIdeasForReview`.
- [ ] **Step 4:** `go test ./internal/kb ./internal/tools ./internal/db` — PASS; `make lint-diff`. Commit `feat(ideas): unapproved chat-born items stay out of search, tools and Catch-Up`.

### Task 4: Chats in the stage-2 consolidation

**Depends on:** Task 1, Task 2, Task 3

**Files:**
- Modify: `internal/ideas/consolidate.go` (`consolidateInput`, `workspaceFloors`, `gatherConsolidateInput`, a new `addChatTurns` + `renderChatUnit`, `applyConsolidateOps`/`applyNewIdeaOp`, `applyAttachMentionOp`), `internal/ideas/backfill.go` (the chat floor in saved/raised workspace floors), `internal/prompts/defaults.go` (`defaultIdeasConsolidate`, version 4 → 5), `internal/prompts/defaults_extra_test.go`
- Test: `internal/ideas/consolidate_test.go`, `internal/ideas/consolidate_floors_test.go`

**Interfaces:**
- Consumes: `db.ListChatTurnsForIdeas`, `db.GetIdeasChatFloor`/`SetIdeasChatFloorTx`, `ideas.ParseKnowledgePrefix`, `instructions.ParseRemember`, `db.Idea.ChatBorn`.
- Produces: op `new_note`; valid refs `chat:<conv>:<msg>` with source `chat`.

Rules:
- Turns load in id order (cutoff = now − 30 min; Backfill's `to` caps it too). Skip (but consume) turns whose text parses as a knowledge prefix or a remember command. Render consecutive turns of one conversation under one header `[chat "<title>"]`, each line `owner|assistant: <text> ref=chat:<conv>:<msg>`, assistant text cut to a cap the builder picks (and states in a const). Budget stop at the first turn that does not fit; the chat floor advances to the last rendered (or skipped) id — never past a dropped one (IDEA-01). Both owner and assistant turns are citable refs.
- `new_note` is accepted only when every surviving mention's source is `chat`; otherwise the op is dropped and counted in `refs_rejected`.
- An item created by `new_idea`/`new_decision`/`new_note` whose surviving mentions are **all** `chat` gets `ChatBorn = true` and status `proposed` (decisions included). Mixed or non-chat → today's behaviour (decision `active`, idea `proposed`).
- `attach_mention` never changes the status of a chat-born item (IDEA-04's `needs_review` flag still applies as today for rejected/not_now/dropped).
- Prompt v5: the material may contain chat turns; from chat material propose only decisions (`new_decision`) and facts/state changes (`new_note`), never ideas; a chat line already matching a registry item is an `attach_mention`. Follow `add-ai-prompt` (both providers; the Idea finder built-in's `PromptRef` keeps working — check `internal/automations/builtin` for the prompt version pin).

- [ ] **Step 1:** Tests (IDEA-contract names, `TestIdeas01_…`/`TestIdeas02_…` where they pin those contracts):
  - `TestIdeas01_ChatFloorStopsAtBudgetDroppedTurn`, `TestIdeas01_ChatTurnsInsideQuietWindowNotConsumed`, `TestIdeas01_ChatPrefixedTurnsConsumedNotRendered`.
  - `TestIdeas02_ChatInventedRefDropped` (a `chat:` ref not rendered this run).
  - `TestConsolidate_ChatOnlyDecisionBornProposedChatBorn`, `TestConsolidate_MixedEvidenceDecisionBornActive`, `TestConsolidate_NewNoteFromSlackRefDropped`, `TestConsolidate_NewNoteFromChatCreatesProposedNote`, `TestConsolidate_SlackAttachDoesNotActivateChatBorn`, `TestConsolidate_IdeaContextConversationsNotMined`.
  - Backfill: `TestBackfill_ChatFloorRestoredAfterWindow` (the memFloors precedent).
- [ ] **Step 2:** Run `go test ./internal/ideas -run 'Chat|NewNote'` — FAIL.
- [ ] **Step 3:** Implement; bump the prompt; update `defaults_extra_test.go`.
- [ ] **Step 4:** `go test ./internal/ideas ./internal/prompts ./internal/automations/...` — PASS; `make lint-diff`. Commit `feat(ideas): AI chats are a registry source; chat-born items wait for Approve`.

### Task 5: Kept artifacts in the knowledge index (Go)

**Depends on:** Task 1

**Files:**
- Create: `internal/kb/source_chat_artifact.go`, `internal/kb/source_chat_artifact_test.go`
- Modify: `internal/kb/source.go` (`allSources`, after `ideaSource{}`)

**Interfaces:**
- Produces: source name `chat_artifact`, doc key `chat_artifact:<conversation_id>:<artifact_key>`; the document renders the **kept** version (`chat_knowledge_artifacts.version`) — title, meta = conversation title + kind, body = content (`html` reduced to text: tags dropped, script/style removed; `table` as its text form). `Changed` by `kept_at`; `Keys` = every kept row whose artifact version still exists; `Build` nil when the row or version is gone.

- [ ] **Step 1:** Tests: `TestChatArtifactSource_IndexesKeptVersionOnly` (a newer version is not indexed until the row's version moves), `TestChatArtifactSource_HTMLRenderedAsText`, `TestChatArtifactSource_GoneWithConversation`, plus the source-name list test that enumerates sources (`contracts_test.go` / `sourceNames`).
- [ ] **Step 2:** FAIL → implement → `go test ./internal/kb` PASS; `make lint-diff`. Commit `feat(kb): artifacts the owner keeps are searchable`.

### Task 6: WatchtowerCore — prefix twin, chat-born queries, kept-artifact queries

**Depends on:** Task 1 (regenerated Swift test schema), Task 2 (fixture)

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/KnowledgePrefix.swift`, `WatchtowerDesktop/Tests/Core/KnowledgePrefixFixtureTests.swift` (reads `internal/ideas/testdata/knowledge_prefix_cases.json` by relative path, the `RememberCommandFixtureTests` pattern)
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/IdeaQueries.swift`, the `Idea` model (`chatBorn`), `WatchtowerDesktop/Sources/WatchtowerCore/Services/Inbox/InboxCards.swift` (`awaitsVerdict`), `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/ChatArtifactQueries.swift`
- Test: `WatchtowerDesktop/Tests/Core/IdeaQueriesTests.swift` (or the existing IdeaQueries test file), `WatchtowerDesktop/Tests/Core/ChatArtifactQueriesTests.swift`

**Interfaces:**
- Produces:
  - `KnowledgePrefix.parse(_ text: String) -> (kind: String, body: String)?`.
  - `IdeaQueries.createFromChat(_ db, kind: String, body: String, conversationID: Int64, messageID: Int64) throws -> Int64` — `source='owner'`, `status='active'`, `chat_born=1`, `essence = body`, `title` = first line cut to 120 characters, one mention `source='chat'`, `ref="chat:<c>:<m>"`, `quote = body`.
  - `IdeaQueries.chatIdea(_ db, conversationID:, messageID:) throws -> Idea?` (the mark's rebuild on reopen).
  - `IdeaQueries.undoChatIdea(_ db, id:, createdUpdatedAt: String) throws -> Bool` — deletes only when the row is still `active`, unmerged, and `updated_at` equals the value recorded at creation; otherwise false (the caller opens the item).
  - `fetchForReview`/`countForReview`/`reviewCountsByKind`: `kind != 'decision'` becomes `(kind != 'decision' OR chat_born = 1)` — Go `CountIdeasForReview` twin.
  - Decision ledger / unread / new-since readers skip `chat_born = 1 AND status != 'active'` (`IdeaQueries.knowledgeVisibleSQL`, twin of `db.KnowledgeVisibleIdeaSQL`).
  - `Idea.awaitsVerdict`: `isForReview && (kind != .decision || chatBorn)`.
  - `ChatArtifactQueries.keep(_ db, conversationID:, artifactKey:, version:)`, `unkeep(...)`, `keptVersion(_ db, conversationID:, artifactKey:) -> Int?`.

- [ ] **Step 1:** Tests: fixture parity; `testCreateFromChatWritesChatBornActiveWithChatMention`; `testUndoChatIdeaRefusesEditedOrApprovedOrMerged`; `testChatBornProposedDecisionAwaitsVerdictAndCounts`; `testMinedNeedsReviewDecisionStillInformational`; `testDecisionLedgerSkipsUnapprovedChatBorn`; kept-artifact keep/unkeep/keptVersion.
- [ ] **Step 2:** `make test-swift FILTER='KnowledgePrefix|IdeaQueries|ChatArtifactQueries|InboxCards'` — FAIL → implement → PASS; `make lint-swift`. Commit `feat(core): chat knowledge queries and the prefix twin`.

### Task 7: Desktop — saved-in-chat mark, chat-born decision cards, chat links

**Depends on:** Task 6

**Files:**
- Create: `WatchtowerDesktop/Sources/Services/ChatKnowledgeCenter.swift`, `WatchtowerDesktop/Sources/Views/Chat/ChatKnowledgeMarkView.swift`, `WatchtowerDesktop/Tests/ChatKnowledgeCenterTests.swift`
- Modify: `WatchtowerDesktop/Sources/App/AppState+Remember.swift` (the main chat's `onOwnerMessageStored` also feeds the new center), `WatchtowerDesktop/Sources/Services/EmbeddedChatWiring.swift` (same for embedded engines), `WatchtowerDesktop/Sources/Views/Chat/ChatMessageRow.swift` (show the knowledge mark beside the remember mark, gated like `showsRememberMark`), `WatchtowerDesktop/Sources/Views/Ideas/IdeaDetailPane.swift` (verdict strip for a chat-born decision; a `chat` mention links to its conversation and message, "Chat deleted" when the conversation is gone), `WatchtowerDesktop/Sources/Views/Inbox/InboxListRow.swift` (source label for `chat`)

**Interfaces:**
- Consumes: `KnowledgePrefix.parse`, `IdeaQueries.createFromChat`/`chatIdea`/`undoChatIdea`.
- Produces: `ChatKnowledgeCenter.ownerMessageSent(text:conversationID:messageID:)`, `mark(for messageID:) -> ChatKnowledgeMark?` (`saved(kind, ideaID)`, `empty`, `undone`, `changed(ideaID)`, `failed(String)`); writes run off the send path (the `RememberCenter` shape, tasks pruned when done — not only in `waitForIdle`).
- Copy: "Saved as a decision" / "Saved as a fact", **Undo**, **Open in Inbox**; empty body: "Nothing to save — write the decision after the colon"; changed: "Changed since — opened in Inbox".

- [ ] **Step 1:** Tests: `ChatKnowledgeCenterTests` (prefixed decision → saved mark + row; empty → no row; undo → row gone + `undone`; undo after an edit → `changed`; remember-prefixed text ignored here; marks rebuilt from `chatIdea` on reopen); an `IdeaDetailPane`/`InboxIdeaPane` test that a chat-born proposed decision shows Approve.
- [ ] **Step 2:** `make test-swift FILTER='ChatKnowledgeCenter|InboxIdeaPane|IdeaDetailPane'` — FAIL → implement → PASS; `make lint-swift`; `make desktop-shots` of the mark and the decision card for the reviewer. Commit `feat(desktop): save a decision or fact from any chat, approve chat-born decisions in Inbox`.

### Task 8: Desktop — Add to Knowledge on artifacts

**Depends on:** Task 6

**Files:**
- Modify: `WatchtowerDesktop/Sources/Views/Chat/ArtifactPanelView.swift` (header button), `WatchtowerDesktop/Sources/Views/Chat/ArtifactCardView.swift` (a small "In Knowledge" badge)
- Test: `WatchtowerDesktop/Tests/ArtifactKnowledgeTests.swift`

**Interfaces:**
- Consumes: `ChatArtifactQueries.keep`/`unkeep`/`keptVersion`.
- Button states, for kinds `document`/`table`/`code`/`html` only: not kept → **Add to Knowledge**; kept = shown version → **Remove from Knowledge**; kept < shown version → **Update in Knowledge** (and Remove in its menu). Copy in English like the rest of the app.

- [ ] **Step 1:** Tests for the state function (`ArtifactKnowledgeState.for(kind:shownVersion:keptVersion:)`) and that `email`/`slack`/`event` get no button.
- [ ] **Step 2:** FAIL → implement → PASS; `make lint-swift`; screenshot for the reviewer. Commit `feat(desktop): Add to Knowledge on chat artifacts`.

### Task 9: Contracts, docs, guide, full gate

**Depends on:** Tasks 1–8

**Files:**
- Modify: `docs/inventory/ideas.md` (IDEA-01/02/05 extended to the chat source; the "decisions born active" exception for chat-born items; review-queue predicate; changelog entry citing ask #551), `docs/inventory/knowledge-search.md` (the `chat_artifact` source; the chat-born visibility rule; changelog), `docs/features/ideas-decisions-registry.md`, `docs/features/knowledge-search.md`, `docs/features/chat-redesign.md` or `embedded-chat.md` (the prefix), `docs/guide/` pages for Inbox → Ideas and the chat (prefixes, Add to Knowledge; 8 KB cap, `go test ./docs/guide`), `CLAUDE.md` feature lines.

- [ ] **Step 1:** Write the amendments and docs.
- [ ] **Step 2:** Gate (controller): `make test`, `go test -timeout 30m ./cmd/...`, `make test-swift`, `make lint-all`, `go test ./docs/guide`.
- [ ] **Step 3:** Commit `docs: chats feed the knowledge base — IDEA/KB amendments, feature notes, guide`.

## Parallel lanes

After Task 1: Tasks 2, 3, 5 and 6 in parallel lanes (6 needs Task 2's fixture file — start it after Task 2 merges, or give it the fixture rows from Task 2's brief). Task 4 after 2 + 3. Tasks 7 and 8 in parallel after 6. Task 9 last.
