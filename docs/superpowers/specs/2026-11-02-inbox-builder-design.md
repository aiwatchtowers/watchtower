# Inbox builder — automations make artifacts, the Inbox shows them (umbrella design)

**Board:** #1400 (umbrella). **Status:** product design for owner review; each sub-project below gets its own spec (with DesignShotCatalog mockups for every state) and plan before code.

## Intent

The owner does not open the Inbox today. It is a list of what the pipelines produced — briefs, tracks, ideas, digests — shaped by us, not by the owner. Meanwhile the most expensive background pipeline, Slack Digests, produces summaries nobody reads directly: on the owner's live install no digest has been written since mid-July and nobody noticed.

The new model:

- **Automations are the owner's tool for making artifacts.** The owner tells the agent what to collect and how it should look; the automation runs on its trigger and produces an artifact.
- **The Inbox is where the owner looks at artifacts.** It has a menu of folders the owner configures. Automations write into folders; one folder may receive the output of many automations.
- **Built-in features become preinstalled automations** with their own default look: Morning brief, Track my threads, Idea finder, People, Catch Up. Their separate screens go away.
- **Digests are removed entirely.** Each automation reads raw source data itself.

Success: the Inbox is the screen the owner opens first because it holds exactly the artifacts they built; the Digests tab, the digest pipelines and their tables are gone; the background AI spend that digests cost is gone with them.

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

## Anti-goals

- An Inbox that again fills with things the owner did not ask for. Nothing appears in the Inbox that is not the output of an automation the owner has (built-in ones included) or an approval that waits on them.
- A design flow that needs the owner to know the block names or the recipe syntax.
- Built-in automations that are special screens in disguise: a built-in artifact uses the same blocks, folders and menu as one the owner made.
- Replacing one expensive shared pipeline with five expensive private ones: removing digests must lower background AI spend, not move it.

## The model

### Folders (the Inbox menu)

- The Inbox menu is a tree of **folders** kept as configuration (rows the Desktop and the CLI edit; not recipe files).
- The **root folder** is the Inbox itself: the general feed that every artifact lands in unless its automation names another folder (ask #947). It is always first and cannot be deleted or moved.
- **Needs approval** is a built-in folder pinned under the root (ask #947). It shows proposals, Slack sends and reminders with the existing approve/reject/edit actions; its look is fixed (not designed in blocks).
- Owner folders: title, icon, parent, position, hidden. Folders nest; drag to reorder and re-parent. A folder has an unread count.
- A folder holds the artifacts of every automation that writes into it; many automations may write into one folder (ask #947). A folder has no look of its own — each artifact keeps the look its automation gave it.
- Folders are created from the menu (**+ New folder**) and from the automation editor: when the owner says "put this into a Release folder", the agent proposes the folder and saving the automation creates it (shown in the save sheet). *(Agent's call: no separate approval step for creating a folder.)*
- Deleting a folder moves its artifacts and the automations pointing at it to the parent folder; nothing is deleted with it. *(Agent's call.)*

### Artifacts

- An artifact is one automation output: a title, a priority, a link, actions and a **block tree**.
- Two lifecycles, chosen per automation *(agent's call)*:
  - **feed** — every run adds new artifacts (Morning brief: one per day);
  - **living** — the automation keeps one artifact (or one per key, e.g. per person) and each run replaces it in place (Track my threads, People). The owner sees "updated 10 min ago", not a pile of copies.
- Read / Done / Dismiss keep their current meaning (`automation_outputs.read_at`/`dismissed_at`); a living artifact becomes unread again only when its content changed.

### Blocks (v1 set, agent's call — refined in sub-project A)

heading · text (markdown) · list (rows: title, subtitle, badge, tone by condition, row actions) · table · person (photo, name, role, lines) · metric row · link · actions (open, reply, chat, agent, create target — the existing `output.inbox` action kinds). Colours only through `Tone`; no row separators; rendered by DesignKit components on the Mac and later the same JSON on the phone. The block JSON is versioned and validated in Go (unknown block → the run's output is refused with a readable error, the same way a bad `output.inbox` is today).

### Designing the look

- The automation editor gets a **Look** step beside **What it collects** and **When it runs**. Same editor chat (`automation_editor` surface); the agent edits the part of the recipe that builds the blocks.
- The preview pane renders the blocks of a **dry run** on real data (dry runs already write nothing). After each turn that changed the look, the preview re-renders. **Save look** saves the recipe as any edit does (approval hash, confirmation sheet).
- The script emits blocks directly (`output.inbox({title, blocks, folder?, key?})`); there is no separate template language. *(Agent's call: one source of truth in the recipe; the preview is a dry run, not a second renderer.)*

### Managing from the Inbox

Each artifact's header and each folder entry carry **⋯**: Run now, Edit what it collects…, Edit the look…, Schedule…, Rename / icon (folder), Move to folder ▸, Turn off, Run history, Delete…. **+ New artifact…** in the menu opens the editor chat at "what should it collect". These are the existing automation verbs; the Inbox calls them, it does not duplicate them.

## Built-ins

| Built-in | Becomes | Default folder | Lifecycle |
|---|---|---|---|
| Morning brief | unchanged automation, blocks instead of markdown | root | feed |
| Track my threads | reads raw windows, not digests | root | living |
| Idea finder | reads raw windows, not digests | root | feed |
| People | new built-in automation; replaces the People Cards pipeline and the People tab | People | living, one per person |
| Catch Up | new built-in automation, triggered on return from absence; replaces the Catch Up tab | root | feed |
| Reactions | unchanged (writes no artifact) | — | — |

The Inbox filters Day / Messages / Tracks / Ideas / Automations are replaced by folders. Attention detection (the Messages filter, `inbox_items`) is not an automation today; see Open questions.

## Removing digests

Removed: the Slack Digests and Stream Digests features and their daemon phases, daily/weekly rollups, `digests`/`digest_topics`/`stream_digests` (and dependent views/indexes) by migration, the Digests tab, `get_digest`/`list_digests` and the `digests:read` capability, the `digest`/`trends`/`decisions` CLI, `needsDigests` readiness and the onboarding/feature-manager entries. Each consumer:

| Consumer | After |
|---|---|
| Track my threads, Idea finder (Slack), People | read a **raw window** primitive (below) |
| Idea finder (mail, Jira) | reads raw mail/Jira windows instead of stream digests |
| Morning brief | reads tracks, targets, calendar, approvals and a raw window of the owner's channels; loses the "what happened in channels" digest roll-up |
| Catch Up | reads raw windows for the absence period itself |
| Meeting prep | person context from the People artifacts instead of digest `situations` |
| Knowledge search | the digest-topic source is dropped (raw messages, mail and Jira are indexed already) |
| "Discussed without a Jira ticket" detector | removed (could return later as a template automation) |
| Memory `digest_compare` (dark) | removed |
| History backfill | no digest chunk; backfill only fills raw data |

**Raw window primitive.** One shared, non-AI step: "messages since my last run that concern the owner" — mentions, DMs, threads the owner is in, watched channels and the owner's chosen channels — with per-run caps. It is mechanical (no LLM), so five automations reading it cost five prompts over already-filtered text instead of one prompt over every channel. This is how the anti-goal on spend is met; sub-project C measures tokens before/after on a fixture.

## Contracts touched (inventory)

TRACKS-01..07 (source changes from digests to raw windows; the guarantees stay), IDEA-01/02/05 (floors and provenance re-keyed from digest topics to messages), CATCHUP-01..04 (moves into an automation), BACKFILL-02 (digest half removed), knowledge-search KB source list, automations AUTO-* (new `blocks`, `folder`, `key` fields on `output.inbox`; capability `digests:read` removed), inbox-pulse INBOX-02/05/09 (depends on the Messages decision). Each change the owner has not explicitly approved is filed as its own ask before the sub-project's review.

## Sub-projects (order)

- **A. Blocks and the Look step** — block schema (Go validation, Swift renderer in DesignKit), `output.inbox` `blocks`/`key`, living artifacts, dry-run preview pane in the editor.
- **B. Folders and the Inbox menu** — folder config (migration, CLI, Desktop), root and Needs approval, `folder` on outputs, ⋯ management, + New artifact, replacing the five filters.
- **C. Raw window primitive; built-ins off digests** — the primitive, Track my threads / Idea finder / Morning brief moved, token measurement.
- **D. People and Catch Up as built-ins** — new entries, artifacts, meeting prep re-pointed, tabs removed.
- **E. Drop digests** — pipelines, migration dropping the tables, tab, tools, CLI, features, readiness, guide pages, inventory.
- **F. Phone renders blocks** — with #1170.

A and B can run in parallel; C before D and E; E last on the Mac side.

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
- Feed vs living lifecycles; folder creation without its own approval; deleting a folder moves its contents up; script emits blocks directly; v1 block set; raw window primitive is mechanical — decided by the agent.

## Open questions (for the owner)

1. What becomes of attention detection (the Messages filter): a built-in automation writing into the root, a fixed built-in folder like Needs approval, or removed?
2. Does the Morning brief keep a "what happened in your channels" section (paid for from the raw window), or is it dropped with digests?
