# Inbox builder — automations make artifacts, the Inbox shows them (umbrella design)

**Board:** #1400 (umbrella). **Status:** product design for owner review; each sub-project below gets its own spec (with DesignShotCatalog mockups for every state) and plan before code.

**Mockups agreed in the brainstorm** (sample data only): [`docs/design/mockups/inbox-builder/01-artifact-look.html`](../../design/mockups/inbox-builder/01-artifact-look.html) — the Look step with chat and live preview; [`docs/design/mockups/inbox-builder/02-inbox-menu.html`](../../design/mockups/inbox-builder/02-inbox-menu.html) — the Inbox with its folder menu and the ⋯ menu. Note: the second mockup predates ask #947 — its menu entries are drawn as one automation each; the model below (folders that many automations write into) is what holds. Sub-projects A and B redraw these screens in DesignShotCatalog and must not contradict them otherwise.

## Intent

The owner does not open the Inbox today. It is a list of what the pipelines produced — briefs, tracks, ideas, digests — shaped by us, not by the owner. Meanwhile the most expensive background pipeline, Slack Digests, produces summaries nobody reads directly: on the owner's live install no digest has been written since mid-July and nobody noticed.

The new model:

- **Automations are the owner's tool for making artifacts.** The owner tells the agent what to collect and how it should look; the automation runs on its trigger and produces an artifact.
- **The Inbox is where the owner looks at artifacts.** It has a menu of folders the owner configures. Automations write into folders; one folder may receive the output of many automations.
- **Built-in features become preinstalled automations** with their own default look: Morning brief, Track my threads, Idea finder, People, Catch Up. Their separate screens go away.
- **Digests are removed entirely.** Each automation reads raw source data itself.

Success: the Inbox is the screen the owner opens first because it holds exactly the artifacts they built; the Digests tab, the digest pipelines and their tables are gone; background AI spend drops (threshold under "Spend").

## Goals

1. An artifact is built from a fixed set of native **blocks**; the owner designs its look **in words**, in a chat with the agent, beside a **live preview** rendered from a dry run.
2. The Inbox has a **configurable menu of folders**: a root folder that everything lands in by default, nested folders, order, names and icons; folders are created from the menu and from the automation editor.
3. Automations are **managed from the Inbox menu** (run now, edit what it collects, edit the look, schedule, move, turn off, history, delete) — the Automations tab stays as the full editor and list.
4. **People** and **Catch Up** become built-in automations whose artifacts live in the Inbox; their tabs leave the sidebar.
5. **Approvals** (agent proposals, Slack sends, reminders) live in a built-in, pinned folder **Needs approval**.
6. **Digests are dropped**: Slack Digests, Stream Digests, daily/weekly rollups, their tables, the Digests tab, tools, CLI and feature switches. Every former consumer reads raw data or is removed.

## Non-goals

- Free-form HTML artifacts. The block set is the only way to draw an artifact (ask #871). A chart block may come later as a block, not as HTML.
- Hand-editing the layout in the preview (drag, resize, inline rename). The look is changed in words (ask #871).
- Deciding the fate of Workload, Blockers, Project Map, Releases and Statistics. The owner is undecided (ask #947); they stay as they are until a separate decision.
- The phone app's Inbox (#1170) — it will render the same blocks, but it is its own sub-project.
- Version history of a living artifact (see Artifacts).

## Anti-goals

- An Inbox that again fills with things the owner did not ask for. Nothing appears in the Inbox that is not the output of an automation the owner has (built-in ones included) or an approval that waits on them.
- A design flow that needs the owner to know the block names or the recipe syntax.
- Built-in automations that are special screens in disguise: a built-in artifact uses the same blocks, folders and menu as one the owner made.
- Replacing one expensive shared pipeline with five expensive private ones: removing digests must lower background AI spend, not move it.
- A message silently missed: a raw window never drops messages without saying so.

## The model

### Folders (the Inbox menu)

- The Inbox menu is a tree of **folders** kept as configuration: database rows written only by the Go CLI (`watchtower inbox folders …`); the Desktop edits them through the CLI, like automations. Every write is compare-and-set on a per-tree `revision`, so a Desktop drag and a CLI edit at the same moment cannot both land — the loser gets "the menu changed, reload" and the Desktop re-reads. *(Agent's call.)*
- The **root folder** is the Inbox itself: the general feed that every artifact lands in unless its automation names another folder (ask #947). It is always first and cannot be deleted or moved.
- **Needs approval** is a built-in folder pinned under the root (ask #947). It shows proposals, Slack sends and reminders. Its cards are drawn by a built-in recipe, `needs-approval`, like any other built-in: its look is changed in words in the Look step (in keeping with "every Inbox item can be customised"). The recipe has an `approval` event trigger fired by the tool registry whenever an action changes state — proposed, approved, rejected, expired, applied, failed, retried or dismissed — and when a reminder is created or comes due (the registry wakes the executor the way `automations wake` does), reads the pending actions and reminders through a read primitive, and writes one living artifact per action or reminder, keyed by kind and id (`action:<id>`, `reminder:<id>`, so an action and a reminder with the same id never share an artifact). The Approve / Reject / Edit actions are not part of the look: the Desktop always adds them, bound to the action id. Until the recipe has drawn a new action — or when it fails — the Desktop shows the action in the default native card, so an approval never waits on a run. An action needs the owner while it is pending or failed after approval; it is closed once rejected, expired, applied successfully or dismissed. The `approval` run deletes the artifact of a closed action (a living output can be removed by key) and rewrites the artifact of an action that failed after approval, now with today's **Retry** and **Dismiss** (a successful retry closes it). Reminders in this folder get the reminder row actions, Done and Snooze, not Approve / Reject (the `reminder` ref below). The Desktop shows a card only while its action or reminder still needs the owner, reading that state itself at render time, so a closed approval never piles up even before the run, and a failed one never vanishes: if its artifact was already deleted, the native card shows it until the run redraws it. The recipe can be turned off but not deleted (it is a built-in); while it is off, or after its run fails, every pending action shows in the native card, so the folder is never silently empty. The shipped recipe has no `llm()` step: it maps the action's fields to blocks, so an approval costs no AI; an owner's look that adds AI-written text adds an `llm()` step, and the Look step says so before saving. *(Agent's call.)*
- Owner folders: title, icon, parent, position, hidden. Folders nest; drag to reorder and re-parent. A folder has an unread count: the sum over its artifacts, where an artifact counts as 1 when unread, or — when it lists rows with a `ref` (below) — the number of its open rows, so Waiting for me shows how many things wait, not 1. *(Agent's call.)*
- A folder holds the artifacts of every automation that writes into it; many automations may write into one folder (ask #947). A folder has no look of its own — each artifact keeps the look its automation gave it.
- Folders are created from the menu (**+ New folder**) and from the automation editor: when the owner says "put this into a Release folder", the agent proposes the folder and saving the automation creates it (shown in the save sheet). *(Agent's call: no separate approval step for creating a folder.)*
- Deleting a folder moves its artifacts and the automations pointing at it to the parent folder; nothing is deleted with it. *(Agent's call.)*

### Artifacts

- An artifact is one automation output: a title, a priority, a link, actions and a **block tree**.
- Two lifecycles, chosen per automation *(agent's call)*:
  - **feed** — every run adds new artifacts (Morning brief: one per day);
  - **living** — the automation keeps one artifact per `key` (e.g. per person) and each run replaces it in place (Track my threads, People). The owner sees "updated 10 min ago", not a pile of copies. Earlier versions are not kept in v1; the run history still shows each run.
- A living write is one upsert on `(automation_id, key)` in the run's commit transaction. A recipe that writes living artifacts or reads the raw window must have `concurrency: 1` — the validator refuses a higher value with a readable error — so two runs of one automation never overlap, and a key belongs to one automation, so two writers of one artifact cannot race. A retry that produces the same content (same content hash) keeps its read state; a living artifact becomes unread again only when its content hash changed.
- Read / Done / Dismiss keep their current meaning (`automation_outputs.read_at`/`dismissed_at`).

### Blocks (v1 set, agent's call — refined in sub-project A)

heading · text (markdown) · list (rows: title, subtitle, badge, tone by condition, row actions) · table · person (photo, name, role, lines) · metric row · link · actions (open, reply, chat, agent, create target — the existing `output.inbox` action kinds). Colours only through `Tone`; no row separators; rendered by DesignKit components on the Mac and later the same JSON on the phone. The block JSON is versioned and validated in Go (unknown block → the run's output is refused with a readable error, the same way a bad `output.inbox` is today). An existing markdown output (no blocks) is shown as a single text block.

### Designing the look

- The automation editor gets a **Look** step beside **What it collects** and **When it runs**. Same editor chat (`automation_editor` surface); the agent edits the part of the recipe that builds the blocks.
- The preview pane renders the blocks of a **dry run** on real data (dry runs already write nothing). After each turn that changed the look, the preview re-renders. **Save look** saves the recipe as any edit does (approval hash, confirmation sheet).
- The script emits blocks directly (`output.inbox({title, blocks, folder?, key?})`); there is no separate template language. *(Agent's call: one source of truth in the recipe; the preview is a dry run, not a second renderer.)*

### Managing from the Inbox

Each artifact's header and each folder entry carry **⋯**: Run now, Edit what it collects…, Edit the look…, Schedule…, Rename / icon (folder), Move to folder ▸, Turn off, Run history, Delete…. **+ New artifact…** in the menu opens the editor chat at "what should it collect". These are the existing automation verbs; the Inbox calls them, it does not duplicate them.

## Built-ins

| Built-in | Becomes | Default folder | Lifecycle | Sub-project |
|---|---|---|---|---|
| Morning brief | unchanged automation, blocks instead of markdown | root | feed | C |
| Track my threads | reads raw windows, not digests | root | living | C |
| Idea finder | reads raw windows, not digests | root | feed | C |
| People | new built-in automation; replaces the People Cards pipeline and the People tab | People | living, one per person | D |
| Catch Up | new built-in automation with a new built-in-only trigger `return` (below); replaces the Catch Up tab | root | feed | D |
| Needs approval | built-in recipe `needs-approval` over `agent_actions` / reminders, `approval` event trigger | Needs approval | living, one per action | B |
| Waiting for me | new built-in automation over the attention detector (`internal/inbox`, mechanical, no AI): mentions, DMs and questions to the owner (ask #952); replaces the Messages filter | root | living, one artifact listing everything that waits (owner's confirmation, ask #959) | B |
| Reactions | unchanged (writes no artifact) | — | — | — |

**Catch Up trigger.** Automations today have schedule, button, event, manual and sync triggers; none fires on the owner's return. Sub-project D adds a built-in-only trigger `return`: the Desktop's existing absence detection (the one that opens Catch Up today) calls `automations run catch-up --since <absence start>`, and the run's window is the absence. The CATCHUP-01..04 guarantees move with it.

**Filters become folders** (ask #952): the Inbox filters Day / Messages / Tracks / Ideas / Automations go away. Existing content moves as follows — briefs and day plans: Morning brief artifacts in the root; tracks: the rows stay in `tracks` and Track my threads renders them; ideas: the rows stay in the registry and Idea finder renders them; existing automation outputs: their folder is the root, markdown shown as a text block; proposals and reminders: Needs approval; attention-detection items (`inbox_items`): the rows stay and the Waiting for me built-in renders them in the root. Sub-project B owns the move.

**Acting on one row of a list** (ask #959). One artifact can list many things the owner acts on one by one — the pings in Waiting for me, the threads in Track my threads. A list row may carry a `ref` to the thing it shows: `inbox_item`, `track`, `idea`, `reminder` or `action` plus its id. For a row with a `ref` the Desktop adds exactly the actions that kind's Inbox card has today, no fewer: an attention item — Done, Snooze, Hide, Reply; a track — Done, Stop watching, Make a Task (and Restore on a stopped one, under the artifact's "Show stopped"); an idea — the idea card's actions; a reminder — Done, Snooze; an action — Approve / Reject / Edit, and Retry / Dismiss when it failed (the Needs approval rule above). Like the approval buttons, these are not part of the look and cannot be removed from it; they act on the row's own record through the existing paths (`messageDone`, `snoozeMessage`, `hideMessage`, `markTrackDone`, `stopWatching`, `restoreTrack`, `markReminderDone`, `snoozeReminder`, `retry`, `dismiss`). While the write runs the row shows busy; once it succeeds the row leaves the list, and the next run leaves it out because the record is closed or snoozed. If the write fails the row stays, with the error line and Retry the card shows today — a failed Done never hides a row. *(Agent's call on the `ref` mechanism, sub-project A for the block field, B for the native actions.)*

**When Waiting for me runs.** It has the built-in `sync` trigger: it runs after every sync cycle, right after the attention detector, and after each native row action. A snoozed row comes back at the first cycle after its snooze ends, so at most one sync interval late. *(Agent's call.)*

The recipe's own row actions (open, reply, chat, agent, create target) stay beside them, except a kind the native set already has: on a row with a `ref` the native action wins and the recipe's duplicate is not drawn (so a ping has one Reply).

**A stale run never brings a closed row back.** Like approval cards, the Desktop draws a row with a `ref` only while its record is still open — not done, hidden, stopped or snoozed — reading the record's state at render time. A run that read its data before a Done and wrote after it therefore cannot show the closed row again; the row stays hidden, and the next run leaves it out. The folder count uses the same rule.

**What else sits by the Inbox today** (ask #959). The Inbox screen (`ActionStripView`) is the old action strip; its list and reading pane are replaced by the folder menu and the artifacts, and its per-kind Done / Dismiss / Hide / Snooze move into artifact and row actions. The header's **?** (reaction cheat sheet) stays in the Inbox header. **Learned Rules** and **Assistant Profile** move into the root folder's ⋯ menu and still open in the reading pane: learned rules still feed the tracks, brief and Catch Up prompts (the digest pipeline's rules go with the digests), and the profile still feeds Catch Up and the idea chat. Sub-project B owns this. *(Agent's call.)*

## Removing digests

Removed: the Slack Digests and Stream Digests features and their daemon phases, daily/weekly rollups, `digests`/`digest_topics`/`stream_digests` (and dependent views/indexes), the Digests tab, `get_digest`/`list_digests` and the `digests:read` capability, the `digest`/`trends`/`decisions` CLI, `needsDigests` readiness and the onboarding/feature-manager entries. The owner confirmed these removals without replacement in ask #952: the "discussed without a Jira ticket" detector, the `digest`/`trends`/`decisions` CLI, digest topics in knowledge search with `get_digest`/`list_digests`, and digest history with no export.

**Desktop readers** (all must stop reading before the tables go): `DigestQueries`, `StreamDigestQueries`, `DigestViewModel`, `DigestDetailView`/`DecisionDetailView`, `StreamDigest` model, `TargetPrefillBuilder` (prefill from a digest), `CatchUpQueries`/`CatchUpViewModel`/`CatchUpSourceCard`, `TrackQueries`/`TracksViewModel`, `IdeaQueries`/`IdeaMention`, `JiraQueries`, `ChannelStatsQueries`, `ReadinessQueries`/`Readiness`, `EmptyStateCopy` and the Home "turn on Digests" copy, `SidebarCountsViewModel`, `DatabaseObserver`, `AutomationCardPresentation`, `UsageView`, `PipelineRun`. Sub-project E starts with a sweep (`grep` over `WatchtowerDesktop`, `WatchtowerKit`, `WatchtowerMobile`) and a test that the Desktop opens a database without the tables.

**Dropping the tables, in two releases.** Release N stops every read and write (Go and Swift) and leaves the tables in place; release N+1 drops them by migration. So a one-version rollback still opens the database, and nothing in N depends on the tables existing. Digest history is not exported (ask #952). *(Agent's call on the two-step.)*

| Consumer | After |
|---|---|
| Track my threads, Idea finder (Slack), People | read the **raw window** primitive (below) |
| Idea finder (mail, Jira) | reads raw mail/Jira windows instead of stream digests |
| Morning brief | reads tracks, targets, calendar, approvals; the "what happened in your channels" section is removed with the digests (ask #952) |
| Catch Up | reads raw windows for the absence period itself |
| Meeting prep | person context from the People artifacts; when People is off or has no card for an attendee, from a raw window of that person's recent messages *(agent's call)* |
| Knowledge search | the digest-topic source is dropped (raw messages, mail and Jira are indexed already) — ask #952 |
| "Discussed without a Jira ticket" detector | removed, no replacement (ask #952) |
| Memory `digest_compare` (dark, off by default) | removed |
| History backfill | no digest chunk; backfill only fills raw data |

### Raw window primitive

One shared, non-AI step: the messages since this automation's cursor that concern the owner. *(Agent's call, refined in sub-project C.)*

- **Scope:** mentions of the owner, DMs, threads the owner wrote in, watched channels and channels the owner adds per automation. Everything else is invisible to these automations — this is a narrowing, stated here so it can be refused.
- **Cursor:** per automation, kept in its state, advanced only when the run ends `succeeded`. A failed, cancelled or interrupted run leaves it, so the next run sees the same messages again. A recipe that reads the window must have `concurrency: 1` (refused otherwise, as for living artifacts), so one cursor has one reader at a time.
- **Caps:** v1 defaults 500 messages and 200 000 characters per run, oldest first. When the cap cuts the window, the cursor moves to the last message included — the rest come in the next run, not lost. When the backlog is older than 7 days the run includes the newest 7 days and the artifact says "N older messages skipped" with the count; the skip is never silent.
- **Untrusted input:** the window is returned as structured JSON (author, channel, time, text) and reaches the model only through `llm()`'s input, which is fenced as data (`fenceData`), never concatenated into the prompt. This follows epic #551's split: the primitive parses and filters (no AI), the automation processes. Rendered blocks show source text as plain text; reply actions are bound to the message's own thread and channel and still go through the approval path. The digest layer was itself an LLM over raw text, so this is not a new exposure, but the fence becomes mandatory for every built-in.

### Spend

Before sub-project C ships, measure background tokens per day of digests + tracks + people + ideas on the owner's install (`pipeline_runs`/`llm_calls`, read-only) as the baseline. Target: the new built-ins together use at most 50 % of that baseline, on a fixture in tests and on the live install for one week after release. The target is a goal, not a gate: digests are dropped regardless (the owner's decision); missing the target opens a follow-up target to cut the built-ins' spend (caps, prompt size, cadence). *(Agent's call on the 50 %.)*

## Contracts touched (inventory)

TRACKS-01..07 (source changes from digests to raw windows; the guarantees stay), IDEA-01/02/05 (floors and provenance re-keyed from digest topics to messages), CATCHUP-01..04 (moves into an automation), BACKFILL-02 (digest half removed), knowledge-search KB source list, automations AUTO-* (new `blocks`, `folder`, `key` fields on `output.inbox` and removal of a living output by key; new `return` and `approval` triggers; `concurrency: 1` required for living outputs and the raw window; capability `digests:read` removed), inbox-pulse INBOX-02/05/09 (the detector keeps its guarantees; its output moves from the Messages filter to the Waiting for me built-in, ask #952). The AUTO-* changes are approved (ask #961). Each other change the owner has not explicitly approved is filed as its own ask before the sub-project's review.

## Sub-projects (order)

- **A. Blocks and the Look step** — block schema (Go validation, Swift renderer in DesignKit) incl. the list row `ref`, `output.inbox` `blocks`/`key`, living artifacts, their upsert and their removal by key, dry-run preview pane in the editor, the Look step's warning when a look adds an `llm()` step.
- **B. Folders and the Inbox menu** — folder config (migration, CLI with compare-and-set, Desktop), root and Needs approval (the `needs-approval` recipe, the `approval` trigger, the native card fallback), `folder` on outputs, ⋯ management, + New artifact, replacing the five filters and moving the existing Inbox content, the Waiting for me built-in, native row actions for a `ref`, the Inbox header's ? and the Learned Rules / Assistant Profile entries.
- **C. Raw window primitive; built-ins off digests** — the primitive (scope, cursor, caps, fence), Track my threads / Idea finder / Morning brief moved, spend baseline and measurement.
- **D. People and Catch Up as built-ins** — new entries, the `return` trigger, artifacts, meeting prep re-pointed (People artifacts, raw-window fallback), tabs removed.
- **E. Drop digests** — release N: every Go and Swift reader removed, pipelines, rollups, tab, tools and the `digests:read` capability, CLI (`digest`/`trends`/`decisions`), the "without Jira" detector, the brief's channel section, the KB digest-topic source, memory `digest_compare`, the backfill digest chunk, features, readiness, onboarding entries, guide pages, inventory; release N+1: the migration dropping the tables.
- **F. Phone renders blocks** — with #1170.

A and B can run in parallel; C before D and E; E last on the Mac side. Every promise in this spec is owned by one of A–F: the built-ins table names its sub-project, and the lists above name the rest.

## Decisions

- Remove digests entirely; People becomes a preinstalled automation with a menu entry — conversation (2026-10-31).
- Automations are the owner's tool for making artifacts; the Inbox is where artifacts are viewed — conversation (2026-10-31).
- The automation has a flow for designing the artifact, plus management of the artifact menu — conversation (2026-10-31).
- The look is built from ready-made native blocks, no free HTML — ask #871.
- The look is designed in words in a chat with a live preview — ask #871.
- The Inbox menu is a config of folders; folders are created from automations; many automations may write into one folder — ask #947.
- The root folder is the general Inbox where everything lands unless a nested folder is named — ask #947.
- Approvals live in a built-in folder Needs approval — ask #947.
- Catch Up moves into the Inbox as a built-in; Workload/Blockers/Project Map/Releases/Statistics undecided, out of scope — ask #947.
- Filters Day / Messages / Tracks / Ideas / Automations replaced by folders with the content mapping above — ask #952.
- The attention detector (Messages) becomes the built-in automation Waiting for me in the root — ask #952.
- The Morning brief's "what happened in your channels" section is removed with the digests — ask #952.
- Removed without replacement: the "discussed without a Jira ticket" detector, the `digest`/`trends`/`decisions` CLI, digest topics in knowledge search and `get_digest`/`list_digests`, digest history (no export) — ask #952.
- Waiting for me is one living artifact listing everything that waits — ask #959.
- Automation contract changes (AUTO-*): `blocks`/`folder`/`key` on `output.inbox`, removal of a living output by key, list row `ref` with native actions, built-in `return` and `approval` triggers, `concurrency: 1` for living outputs and the raw window, `digests:read` removed — ask #961.
- Needs approval as the built-in recipe `needs-approval` with the `approval` trigger and Desktop-added actions; `concurrency: 1` for living outputs and raw-window readers; the spend target is a goal, not a gate; feed vs living lifecycles, no version history; living upsert and read-state rule; folder writes through the CLI with compare-and-set; folder creation without its own approval; deleting a folder moves its contents up; script emits blocks directly; v1 block set; raw window scope, cursor, caps and 7-day skip; meeting prep fallback; `return` trigger for Catch Up; two-release table drop; 50 % spend target; approval card removed after the decision and native fallback while the recipe is off; list row `ref` with Desktop-added native row actions; Learned Rules / Assistant Profile in the root's ⋯ and the ? in the Inbox header; native row actions = today's card actions per kind, a failed row write keeps the row with its error; failed actions stay in Needs approval with Retry / Dismiss; Waiting for me on the `sync` trigger; a folder's count = open rows for `ref` lists — decided by the agent.
