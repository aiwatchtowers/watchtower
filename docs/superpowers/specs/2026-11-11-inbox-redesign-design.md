# Inbox redesign — sections by urgency, one brief, counts you can act on

**Board:** #1076 (under the inbox builder umbrella #917). **Status:** design for owner review.
**Mockup (agreed in the brainstorm, sample data):** `docs/design/mockups/inbox-redesign/inbox-redesign.html`.
**Builds on:** `docs/features/inbox-folders.md` (sub-project B), `docs/features/inbox-card-blocks.md` (A), the umbrella `docs/superpowers/specs/2026-11-02-inbox-builder-design.md` (raw window, sub-project C).

## For the owner (one page)

The Inbox today is a flat list the owner does not open: a Morning brief row for every unread day, counts nobody can act on ("200 waiting", "1689 unread", "546 to judge"), rows that say nothing about their content, and an empty right half ("Select a card"). The redesign makes the page answer one question — *what needs me now* — and shows the rest quietly.

What the owner gets:

1. **Inbox at the top of the sidebar**, in Targets' place; Targets moves into FOCUS next to Catch Up.
2. **Sections by urgency:** Needs you → Today → Running → Earlier.
3. **One Morning brief row**, always today's. Past days are inside it (‹ › and History). An older brief counts as read once a newer one exists.
4. **Rows that show their content:** a coloured tile per kind, the first real line ("Colleague B in a DM: Will you approve the budget?"), time on the right, a count of what is new.
5. **Counts mean "act":** people waiting today, threads with news, ideas in today's batch. The backlog is a grey second line. The sidebar badge = Needs approval + people waiting today. Mail never counts.
6. **Never an empty pane:** the Inbox opens today's brief, or the last thing the owner looked at.
7. **Waiting for me = people** (Slack, Jira, Linear). Mail moves to its own row, **Mail waiting**, grouped by sender: Mark All Done for a sender, Mute a sender.
8. **Old things leave with one press:** waiting items older than 7 days (Mark All Done…), threads quiet for 30 days (Stop Tracking Quiet Ones…), ideas older than 30 days (Clear Old Ideas…). Nothing disappears on its own.
9. **Idea finder hands out a daily batch** (13) one card at a time: Keep / Drop / Later.
10. **Needs approval grouped by kind** (messages, tracks to create, targets, Confluence and Jira); a group of the same kind has Approve All.
11. **Mail closes itself when you reply** (Gmail), like Slack already does.
12. **Slack today** — a new built-in: what happened in your channels since you last looked, by channel, each line marked decided / asks you / needs someone / fyi. Reads Slack directly, no digests.

Shipped in five phases (below), each mergeable on its own; phases 1–3 need no new AI.

## Intent

Make the Inbox the place the owner opens first in the morning and after every absence, by showing what needs them before what merely happened, and by turning every large number into either a short list or one bulk press.

## Goals

- The first screen shows the few things that need the owner, with their content, without a click.
- Every count on the page is a number the owner can bring to zero today.
- Every backlog (old waiting items, quiet threads, old ideas, a busy mail sender) can be cleared in one press, confirmed once.
- Mail no longer drowns messages from people.
- The owner sees what happened in Slack channels without digests.

## Non-goals

- No new folder features (folders, routes, menus stay as sub-project B shipped them).
- No change to how the detector decides what is actionable (beyond mail closing on reply).
- No phone changes (the phone keeps its current Inbox slice; sub-project F).
- IMAP mail does not close on reply in this project (no Sent folder sync, no thread headers today).
- Morning brief, Track my threads and Idea finder are not moved off digests here (that stays sub-project C, #920); only the raw window primitive is built here, for Slack today.

## Anti-goals

- **Anything disappears without the owner's press.** Every bulk clear is an owner gesture with a confirmation that states the count; nothing expires on its own (owner's call in the brainstorm).
- **Mail in the badge or in Needs you.**
- **A count that cannot reach zero today** (a total, a backlog) shown as the row's main number.
- **Layout jumps on hover.** Row actions appear over the row's trailing edge, never by growing the row (owner's comment on the mockup).
- Live numbers from the owner's install in the repo (spec, mockup, tests, fixtures).

## Constraints

- Desktop code follows `docs/review/review-rules.md` (Swift / Desktop conventions) and the design kit (`docs/design/desktop-style-guide.md`): tokens only, `.kitRow`, no row dividers, one prominent action per screen, `PanelSplit`, empty states through `FeatureEmptyState`/`TabEmptyState`/`ContentAwareEmptyState`. New screens get DesignShotCatalog shots (light + dark).
- Desktop writes stay where they are today (STRIP-03): idea verdicts through `IdeaQueries` (GRDB), reminders through GRDB, inbox items and tracks through the CLI; every new bulk verb is a CLI write refused under an agent marker.
- Inventory contracts are load-bearing (`docs/inventory/`). The amendments this design needs are listed under **Inventory**; each needs the owner's approval before code (asked in one ask with the spec review).
- Built-ins follow `docs/features/built-in-automations.md` ("How to add a built-in"); new prompts follow the `add-ai-prompt` skill (both providers, tier chosen per call).
- Go↔Swift dual paths (counts, open-item clauses, track news rule) get a shared fixture or parity test, like `InboxRefStateParityTests`.

## The design

### Sidebar (phase 1)

`SidebarDestination.rootItems` = `[.home, .inbox, .workbench, .automations, .calendar]`; `SidebarSection.today.items` = `[.catchUp, .targets]`. The Inbox keeps its badge in the root. Tests pinning the order move with it (`SidebarSectionTests`, `HomeLandingTests`, `SidebarAutomationsVisibilityTests`, `ConnectionsTabTests`). The FOCUS section comment and the guide's sidebar page are updated.

### Layout (phase 1)

Three columns as today — rail, list, reading pane — with these changes:

- **Rail:** stays the kit's side list width (170–360, ideal 220). The **Folders** heading and owner folders appear only when at least one owner folder exists; until then the rail shows Inbox and Needs approval only. **New Artifact…** and a New Folder icon button share one row at the bottom.
- **List column:** fixed width range (`PaneWidth` gets a new token pair, e.g. `inboxListMin` 320 / `inboxListIdeal` 372 / `inboxListMax` 460 — builder's call on the numbers, added to `Tokens.swift` and `TokenTests`). The reading pane takes the rest. This fixes the oversized list column (today the list takes all leftover width and the pane is fixed).
- **Reading pane:** one centred readable column (`ReadableColumn.maxLineWidth`). The pane's own header row carries the entry's actions (stepper, History, Run Now, ⋯, ?), so the duplicate "Inbox" title over the list goes away; the window keeps one "Inbox" title with the search field next to it.
- **Search field:** filters the list by title and preview text (client-side, the loaded entries only). *(Agent's call: no full-text search in v1.)*

### The list (phase 1)

Sections, in this order; a section with no rows is not drawn:

| Section | Entries |
|---|---|
| **Needs you** | Waiting for me (people), Mail waiting, Thread briefs of the last 24 h (listed, never counted: a brief is a result, ask #609) |
| **Today** | Morning brief (today), Slack today, owner artifacts written today |
| **Running** | Track my threads, Idea finder, owner artifacts not written today |
| **Earlier** | one quiet line: "Past briefs are inside Morning brief · N unread this month" (opens the brief's History) |

In an owner folder the list has Today and Earlier only (by `changedAt`).

**Row anatomy** (`InboxListRow` replaces `InboxFolderListRowView`; `.kitRow`):

- leading tile (30 pt, `Radius.row`) tinted by kind: brief = sun, people waiting = orange, mail = green, threads/Slack = accent, ideas = purple, approvals = orange check. Owner artifacts use their folder icon on the accent tint. *(Agent's call: colours through `Tone`/`ChipTint`, no new colours.)*
- title (`.headline`-weight body) with a blue unread dot before it;
- preview: up to two lines of real content (see per entry below), `.secondary`;
- meta line: the backlog or provenance, `.tertiary` caption;
- trailing: time (`.monospacedDigit`, "08:02" today, "yesterday", weekday, date) above a count pill. Pill tones: orange for Needs you, accent for news, neutral for a batch.
- selection: `Fill.selected`; the tile keeps its tint at `Fill.card` when selected so the row does not turn into one blue block (owner's comment on the mockup). 2 pt between rows.

Per-entry row content:

| Entry | Preview | Meta | Pill |
|---|---|---|---|
| Waiting for me | newest item "<who> <where>: “<text>”" + "and N more today" | "People in Slack and Jira · N older, folded" | people items newer than 24 h |
| Mail waiting | "N new today. Most of it comes from K senders…" | "N open · X% from 10 senders" | mail newer than 24 h (neutral) |
| Morning brief | the brief's lead sentence (first `attention` line, else first `your_day` line) | weekday + date | none |
| Slack today | the first two lines of the artifact | "Built in · today · N messages" | channels with news (neutral) |
| Track my threads | the newest two threads with news, one line each | "N quiet threads folded" | threads with news (accent) |
| Idea finder | "Today’s N ideas to judge. Top one: “…”" | "N in the backlog · M older than 30 days" | left in today's batch (neutral) |
| Owner artifact | its `body` plain text (A's `PlainText`) | "Your automation · run #N" or "every sync" | its ref rows waiting, as today |

**Counts** (`InboxFolderCounts`, `ActionStripViewModel.badgeCount`): the Inbox root count = people waiting newer than 24 h + unread today's brief (0/1) + unread artifacts in the root. An owner folder counts its own unread artifacts on its rail row, as today; those never reach the badge. Thread briefs are never counted (ask #609). Needs approval keeps its own count (open approvals, as today). The sidebar badge = Needs approval + people waiting newer than 24 h. Mail, tracks and ideas never enter a badge. *(Owner's call in the brainstorm.)*

### Selection (phase 1)

On entering the Inbox (or a folder): restore the last selected entry of that folder if it is still listed (`inbox.entry.<folderID>` in UserDefaults), else today's Morning brief in the root, else the first entry. `selectFolder` no longer leaves the pane empty. "Select a card" remains only for a folder with no entries, where the folder's empty state is shown instead.

### Morning brief (phase 1)

- **One row.** `InboxListBuilder.rootDays` returns today only (or the placeholder before it exists). The `Earlier` line counts unread briefs of the last 30 days and opens History.
- **Read rule:** a brief is read once opened, or once a newer brief exists. The Desktop writes `read_at` for every older unread brief when it reads the feed and a newer brief exists (one `UPDATE … WHERE date < ? AND read_at IS NULL`, GRDB, like `BriefingQueries.markRead`). *(Agent's call: the Desktop writes it, since the Desktop already owns `briefings.read_at` writes; Catch Up's bulk mark stays.)*
- **Pane:** `InboxDayPane` keeps its content and gains a header with a date stepper (‹ date ›, › disabled on today) and a **History** menu (the last 30 days, unread ones marked). The pane order follows the mockup: lead + "Start here" (top three attention items with one action each), Your day (plan + calendar, conflicts as a `Tone` chip), Waiting on you (top three people items, link to Waiting for me), Moved overnight (tracks with news, link to Track my threads). *(Agent's call: the sections map onto the existing `BriefingSectionsView` blocks; no new brief content, no prompt change.)*

### Waiting for me and Mail waiting (phase 2)

**Go:**

- `attention.waiting` returns people and mail with separate caps: up to 200 items whose trigger is not `email_received`, and up to 200 `email_received` items, each newest first, each within its own byte budget. *(Agent's call: one primitive, a `kind` field on each row — `people` | `mail` — so both recipes share one read.)* Rows from a muted mail sender (below) are left out.
- `waiting-for-me` recipe: people rows only; sections Today (< 24 h), This week (< 7 d), Older (folded, with a note row that carries the bulk action). Title stays "Waiting for me".
- New built-in **`mail-waiting`** ("Mail waiting"): slot `waiting_for_me` (runs right after Waiting for me in the same phase), `FeatureIDs: [secretary-inbox]`, capability `builtin:attention.waiting`, `DefaultFolder: inbox`, no `llm()`, living artifact keyed `mail`. One row per sender (`ref {kind: mail_sender, id: <address>}`), busiest first, with the sender's open count, today's count and the newest subject; the top ten senders' share in the header line.
- **Bulk CLI writes** (owner verbs, refused under an agent marker, `--json` with pinned keys `resolved` and `ids`):
  - `watchtower inbox resolve --sender <address> --trigger email_received` — resolves every open mail item from that sender (reason "Marked done in bulk").
  - `watchtower inbox resolve --older-than 7d --people` — resolves every open people item older than 7 days.
  - Both print the count first with `--dry-run`, which the Desktop uses for the confirmation text.
- **Mute a sender:** a learned rule `source_mute` with scope `email:<address>` (existing `inbox_learned_rules` store; written by the Desktop's existing rules writer). The primitive leaves muted senders' mail out of `mail-waiting`; the items themselves are not changed. Unmute in Learned Rules (root ⋯), as today. **Needs the INBOX-05 amendment below.**

**Desktop:**

- `InboxRefHooks` gains the `mail_sender` kind: **Open** (opens the sender's newest thread in Gmail), **Mark All Done…** (confirm with the dry-run count → CLI), **Mute** (rule write → re-read).
- Waiting for me's Older note row gets **Mark All Done…** (confirm with count → CLI).
- Keyboard in both panes: J/K move, E done, R reply (people only), S snooze, ⏎ open, ⌘K hand to agent. *(Agent's call: on the focused row; Desktop only.)*
- Row actions appear over the row's trailing edge on hover/focus (opacity), replacing the age chip; the row height never changes.
- The Messages stand-in rule stays for Waiting for me; Mail waiting has none (no row until its first run).

### Track my threads (phase 3)

- **With news** = `has_updates = 1`, or never read and last event within 3 days. *(Agent's call: matches TRACKS-04's "news" for read tracks and keeps fresh, never-opened tracks visible; shared fixture for the Swift and Go twins.)* Everything else is **quiet**.
- The reading pane (folder path, replacing `InboxCardPlaceholder`) lists threads with news (one row each: title, latest line, new count, reason chip: reply to you / decision / mention / attachment), then "N more with news", then a note: "N threads have nothing new for you. M of them have been quiet for over 30 days." with **Stop Tracking Quiet Ones…**. Selecting a thread opens today's `InboxTrackPane` in the same pane with a back button.
- **CLI:** `watchtower tracks dismiss --quiet-days 30 [--dry-run] [--json]` sets `dismissed_at` on active tracks with no news and no event for 30 days (TRACKS-07: `dismissed_at` is the only negative state). Restore stays per track (Stopped fold).

### Idea finder (phase 3)

- **Daily batch:** the ideas awaiting a verdict, oldest first among the last 30 days, 13 per local day (`ideas.dailyBatch`, default 13, in the app's defaults). *(Owner-agreed number; the key lets it change without a release.)* The batch is fixed once per local day: the first read of the day stores its idea ids and the date (`ideas.batch.date`, `ideas.batch.ids` in UserDefaults); later reads show those ids that still await a verdict. When none is left, the row reads "Today’s batch done · N in the backlog" (no pill) and the pane offers **Next 13** (takes a new batch the same day). *(Agent's call.)* The row's pill = left in today's batch.
- **Pane:** one card at a time (title, why, source quote, provenance chip), **Keep** (prominent) / **Drop** / **Later** / **Make a Target…**, progress bar, then "Kept today". Keys K / D / L / T. Keep → `active`, Drop → `rejected`, Later → `not_now` through `IdeaQueries.setStatus` (as today). The full list stays reachable through **Backlog · N**, which opens today's `InboxSplitView` ideas list.
- **Clear Old Ideas…** (Backlog header): sets `not_now` on every idea awaiting a verdict older than 30 days, after a confirmation with the count. `not_now` keeps them findable and reversible. *(Agent's call on the status: reversible, an owner verdict per IDEA-04.)*

### Needs approval (phase 1)

`NeedsApprovalSelection` keeps its rules (APPROVAL-01) and adds grouping for the list: Messages (Slack sends, replies, Jira/Linear comments), Tracks to create, Targets, Confluence and Jira (edits, board connects), Reminders, Other. Groups sorted by the oldest item in each; within a group oldest first. A group of one tool and more than one item shows **Approve All N…** (confirmation with the count; approves each through the existing per-action path, stops at the first failure and shows it on that card). Messages never get Approve All. *(Agent's call: sending text to people stays one by one.)*

### Mail closes on reply (phase 4)

- Gmail sync also lists the owner's sent messages (`in:sent`, same incremental window and backfill rules), storing them in `gmail_messages` with their `thread_id` and a `SENT` label. **Sent mail is ordinary mail** (owner's decision, ask #634): every reader of `gmail_messages` sees it — knowledge search, memory, media, `list_emails`/`get_email`. Two readers must still treat it as the owner's own: the Gmail detector (no `email_received` for a message from the owner; it already skips those) and the `gmail.new_messages` automation event (the owner's own messages are not news, AUTO-09's event rule). The builder checks every other reader for an assumption that a row is received mail (counts, "from" labels) and lists them in the plan.
- `autoResolveByRules` gains a mail branch: an open `email_received` item whose Gmail thread has a sent message from the owner newer than the item → `ResolveInboxItem(id, "User replied")`. Same watermark rules (INBOX-09). INBOX-02 is extended to mail (amendment below).
- IMAP: not in this project (no Sent folder sync, no thread headers). Documented as a v1 limit.
- Source deletions and purge treat sent rows like received ones (SRCDEL, PURGE scopes checked by the builder).

### Slack today (phase 5)

- **Raw window primitive** as specified in the umbrella (scope, per-automation cursor advanced only on success, `concurrency: 1`, 500 messages / 200 k characters caps, 7-day skip, `fenceData`), Slack only in this project. Board #920 takes the remaining sources and the moves of the other built-ins.
- **Built-in `slack-today`** ("Slack today"): runs after each sync, at most once per hour *(agent's call)*; scope = every channel the owner is a member of, minus channels muted for AI (owner's decision, ask #634); reads the raw window since its cursor; one `llm()` step (light tier) that groups by channel and labels each line `decided` | `asks you` | `needs someone` | `fyi`, dropping channels with nothing for the owner; writes one living artifact with a block per channel (heading with new count and **Open in Slack**, chip + line), a folded "N channels with nothing for you" line, and the header "Today · N messages in K channels". Lines addressed to the owner personally are left out (they live in Waiting for me).
- **The window is today** (local midnight to now), read incrementally: each run reads only the raw window since its cursor and merges its labelled lines into the automation's state for today; the state resets at local midnight; the artifact is rewritten from the state. So each message goes through the model once. The header reads "Today · N messages in K channels"; **Mark All Seen** marks the artifact read (the living rule makes it unread again when a new line lands). *(Agent's call: cheaper and simpler than a window from the owner's last open, which would re-read the same messages every hour; the name already says "today".)* A channel's "muted" = the existing `is_muted_for_llm` flag.
- New feature id `slack-today` (FEAT-01: off reads nothing), default on when Slack is connected; Settings and the guide list it with the other built-ins.
- Prompt `inbox.slack_today` via `add-ai-prompt` (claude + codex, light tier).

### Mockup and screenshots

The agreed mockup is committed with sample numbers only at `docs/design/mockups/inbox-redesign/inbox-redesign.html`. Each phase registers its screens in DesignShotCatalog (`inbox-r-*`, light + dark) on `acme` / `example.com` fixtures and attaches them to its PR.

## Phases

| Phase | What | Go | Swift | AI |
|---|---|---|---|---|
| 1 | Sidebar, layout, list sections and rows, counts and badge, selection, one brief + history, Needs approval groups | — | yes | — |
| 2 | Waiting for me (people) + Mail waiting, bulk CLI, mute | yes | yes | — |
| 3 | Track my threads news + Stop Tracking Quiet Ones; Idea finder batch + Clear Old Ideas | CLI | yes | — |
| 4 | Mail closes on reply (Gmail) | yes | — | — |
| 5 | Raw window (Slack) + Slack today | yes | yes | yes |

Phases 1, 3 and 4 are independent; 2 after 1 (row/pane components); 5 after 1. Each phase is one PR into `feature/inbox-redesign`; the branch goes to main in one PR with the owner's OK.

## Inventory

Needs the owner's approval before the phase that relies on it:

- **INBOX-05** (phase 2): a `source_mute` rule with scope `email:<address>` hides that sender's mail from the Mail waiting artifact. Still never an `inbox_items` row change; the Desktop's rules writer gains the Mute button as an entry point (still the same writer).
- **INBOX-02** (phase 4): "I reply… the item disappears" extended to Gmail mail; IMAP named as not covered.
- **IDEA-04** note (phase 3): Clear Old Ideas is one owner action applying `not_now` to many ideas; still owner-only, never automatic.
- **TRACKS-07** note (phase 3): bulk Stop Tracking sets `dismissed_at` only.
- **AUTO-*** (phase 5): the raw window primitive's contracts as the umbrella spec states them (AUTO-01 capability, AUTO-04 cursor on success, AUTO-05 concurrency 1); FEAT-01 for `slack-today`.
- **Raw window scope** (phase 5, umbrella amendment): a built-in may widen the scope to every channel the owner is a member of, minus channels muted for AI (owner's decision, ask #634). Owner recipes keep the umbrella's narrow scope.

Approved by the owner in ask #634: INBOX-05, INBOX-02, the STRIP badge change, the raw window scope for Slack today, sent mail as ordinary mail.

- **STRIP badge** (phase 1): the sidebar badge becomes Needs approval + people waiting newer than 24 h (owner's choice in the brainstorm); ideas, briefings and owner-folder artifacts leave it; the guard `InboxFeedQueriesTests::testBadgeCountsDecisionsUnreadMessagesLatestUnreadDayAndDueReminders` is rewritten to the new terms.

Unchanged and relied on: APPROVAL-01 (every open approval still drawn; Approve All goes through the per-action path), STRIP-01/03, FOLDER-01, TRACKS-04, IDEA-03, INBOX-09.

## Left to the builder

- Exact token values for the list column and tile, icon choices per kind (SF Symbols from the kit), the text styles per line.
- Whether the root sections are built in `InboxFolderEntries.build` or a new builder over its output (keep `InboxFolderEntries` the single source of entries).
- How the Waiting for me recipe draws its Older section and note row with the blocks schema (A's eight block types).
- Gmail `in:sent` paging and backfill details within the existing sync budget.
- Slack today's prompt wording and block layout within the A schema.
- The guide pages: `docs/guide/features/inbox.md`, the built-ins page, the sidebar page.
