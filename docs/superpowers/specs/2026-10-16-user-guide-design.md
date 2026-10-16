# User guide — design

Board #429. Owner decisions from asks #203–#206 (2026-10-16).

## Why

People don't use Watchtower well, for three reasons (owner, ask #203):

1. **They don't know a feature exists.**
2. **They don't see why a feature is worth using.** They know the tab is there but not when it helps them.
3. **A tab is empty or something doesn't work, and they can't tell why.** Most of the app fills itself in the background, on schedules, from sources that have to be connected. From the outside that looks random.

`docs/app-guide.md` doesn't fix any of this. It is a 254 KB tab-by-tab reference, some lines run to 15,000 characters, and it never says *why* a feature exists. It also misses whole features: Claude plan limits, agent analytics, the diff reviewer and history backfill.

The new guide has two kinds of reader:

- **a person reading on GitHub**;
- **the in-app help agent**, which does not exist yet (board #426). It will search the guide and quote it.

## Goals

- Every user-facing feature has a page saying what it is, why you would use it, how it works underneath, how to use it, and what to do when it's empty or wrong.
- One page lets a person (or the agent) see everything Watchtower can do, one line per feature.
- "Why is this empty / not working" is answerable for every tab and every common failure, starting from what the user sees.
- A new user has one guided route through the first week.
- The guide replaces `docs/app-guide.md`. Afterwards there is one source of truth for user docs.

## Non-goals

- The chat's built-in `appGuide` prompt (`internal/chat/prompt_sections.go`). It belongs to #426, which will decide how the assistant uses this guide.
- In-app Help menu, `?` buttons and the help agent itself (#426).
- Developer docs. `docs/features/*.md`, `docs/inventory/` and the specs stay as they are.
- Translations. The guide is English, like every repo doc.
- A docs website or generator. These are plain Markdown files read on GitHub.

## Anti-goals

These would make the guide a failure even if every feature were covered:

- **Walls of text.** Owner, ask #206: keep it short, "nobody needs a wall of text". Long pages, long paragraphs and an intro that repeats the title are failures.
- **A UI tour.** The guide does not describe what the screen already shows ("the list shows briefings by date"). It explains what the screen doesn't make obvious.
- **Wrong facts.** A confident page that disagrees with the app is worse than no page. `app-guide.md` has drifted in places, so nothing moves across without being checked.
- **Pages that only make sense in order.** Readers and the agent land on one page, often on one section, from a search.

## Decisions

### Layout: one page per feature, symptom pages, a first-week tour (owner, ask #206, option C)

```
docs/guide/
  README.md                 catalogue: every page, one line each, grouped
  WRITING.md                rules for authors (this design's writing rules)
  start/
    first-week.md           the tour
    setup.md                onboarding, goals, Run Setup Again
  concepts/                 cross-cutting "how it works" pages
  features/                 one page per feature (Workbench gets a folder)
  troubleshooting/
    README.md               symptom index: "what you see" → page
    <symptom>.md            one page per common failure
  reference/                settings, keyboard shortcuts, CLI, glossary
```

**Concepts** (my call on the set; the builder may merge or split):

- *How Watchtower works*: the local database, the background sync and its cycle, the pipelines, and a "what runs when" table covering every scheduled output.
- *Sources and accounts*: Slack, Google, IMAP/Outlook, CalDAV/ICS, Jira, Linear, Confluence; multi-account; owner identity and why it matters.
- *History backfill.*
- *Turning features on and off*, with readiness.
- *AI providers, models and cost*, with Usage and Claude plan limits.
- *Privacy*: what stays on the Mac, what goes to the AI provider, what goes to iCloud.

**Features** (my call on how to split them):

- Home
- Catch Up
- Briefings
- Day Plan
- Inbox, with attention detection, reaction commands, reminders and approvals
- Ideas & Decisions
- Targets, with next step and target brief chat
- Tracks
- Digests
- People
- Statistics
- Calendar & meeting prep
- Meeting recording & transcripts, with voices
- Voice dictation
- Mail
- Jira & Linear: Boards, Workload, Blockers, Project Map, Releases
- Search & knowledge, with Confluence
- AI Chat, with artifacts, sending to Slack and editing Confluence
- Quick Connections
- Memory
- Automations
- Workbench, as a folder with an overview page and sub-pages for:
  - board & targets
  - sessions
  - asks
  - code viewer & navigation
  - worktrees & cleanup
  - diff review
  - methodology
  - Codex
- Agent analytics
- iPhone companion
- Menu bar, updates & app lifecycle
- Claude Code / MCP integration

**Troubleshooting pages** come from real failure modes, not guesses. The builder picks them from:

- the empty-state copy (`EmptyStateCopyTable` and the `FeatureReadiness` states);
- error strings the app shows;
- `docs/backlog/`;
- GitHub issues #274–#292.

Expected ones include:

- a tab is empty;
- sync stuck or slow;
- no briefing or day plan today;
- Claude/Codex CLI not found or not signed in;
- an account needs attention or was revoked;
- calendar events missing;
- recording or transcript problems;
- a workbench session or ask not reaching the agent;
- the iPhone not syncing;
- hitting plan limits or high cost.

### Writing rules

They go into `docs/guide/WRITING.md` so future PRs follow them. They come from the practices agreed in ask #206.

1. **Every page is page one.** A page makes sense without its neighbours: one line of context, then a link instead of "see above".
2. **Every section stands alone.** The agent splits text at headings. Headings say what the section answers ("Why the briefing skips a day"), the first sentence carries the answer, and nothing says "as mentioned".
3. **One kind of text per section** (Diátaxis):
   - *why / how it works* explains;
   - *using it* gives steps;
   - reference is lists and tables;
   - troubleshooting is symptom → fix.

   Explanation does not leak into steps.
4. **Troubleshooting shape:**
   - the symptom in the user's words, including exact UI or error text;
   - the cause, in one or two sentences;
   - the fix, as ordered steps;
   - how to check it worked;
   - what to do if it didn't.

   Titles are the symptom ("Briefings tab is empty"), not the feature.
5. **Short** (Carroll's minimalism and the owner's rule):
   - start from the reader's task;
   - one real scenario rather than a list of capabilities;
   - paragraphs of three sentences or fewer;
   - a feature page fits in roughly two screens (about 8 KB of Markdown);
   - a page that grows past that is split, as Workbench is.
6. **Only what the screen doesn't say.** Don't describe what the UI already shows. Keep:
   - what the UI hides: schedules, preconditions, where the data comes from, what a button really does;
   - the exact names people search for: buttons, menu items, error text and shortcuts, in **bold** as the app spells them.
7. **True to the code.** Every schedule, condition, default, UI string and shortcut is checked against the code (Swift views and copy, Go schedules and defaults) before it goes in. When the code and `app-guide.md` disagree, the code wins.
8. **Voice:**
   - second person, present tense, plain words;
   - lively without being jokey;
   - "the assistant" is the only name for the AI persona (review-rules, the assistant & chat contracts).
9. **Public repo hygiene** (CLAUDE.md): no real names, ids, domains or paths; use `acme` / `example.com`.

### Page template for a feature

```
# <Feature>
<lede: what it is and who it's for, 2–3 sentences>

## Why use it            one short real scenario
## How it works          where the data comes from, when it updates, what it needs
                         (feature switch, source, identity) — a small table is fine
## Using it              task headings ("Rebuild a recap with a correction"),
                         then compact reference lists
## When it's empty or wrong   short symptom → fix items; links to troubleshooting/
## Related               links to neighbouring features
For developers: docs/features/<x>.md      (one line, when such a file exists)
```

Sections that would be empty are dropped. Every feature page keeps the first four in this order, so the agent always knows where to look.

### The catalogue (`docs/guide/README.md`)

It does two jobs:

- **For people,** it is the "everything Watchtower can do" page. It is grouped the way the sidebar is: FOCUS, EXECUTION, INSIGHTS, TOOLS, plus Workbench and Automations. Each entry is one line saying what the feature does for you, with a link.
- **For the agent,** it is the map, like `llms.txt`: every page in the guide appears exactly once with a one-line summary.

It starts with three links: the first-week tour, troubleshooting, and how Watchtower works.

### `app-guide.md` dissolves into the guide (owner, ask #204)

- Every section of `app-guide.md` is mapped to its new page or pages.
- Each fact in it is either moved (checked against the code and tightened) or deliberately dropped as obvious from the UI or stale.
- **Dissolving means nothing a reader needs is lost. It does not mean every sentence survives.** The 91 KB Workbench section and the 31 KB Calendar section are expected to shrink a lot. *(My reading of "dissolve" combined with "keep it short".)*
- `docs/app-guide.md` is deleted at the end, not left as a stub.
- Features `app-guide.md` lacks are written from `docs/features/*.md` and the code: plan limits, agent analytics, the diff reviewer, history backfill, and Linear's state.

### Keeping it current

- `CLAUDE.md` gets a "User guide" note: a user-facing change updates its page in `docs/guide/` in the same PR, following `docs/guide/WRITING.md`.
- `docs/review/review-rules.md`'s mention of `docs/app-guide.md` and `.claude/team/tech-writer.md` are repointed to the guide.
- The `docs/inventory/` entries that mention `app-guide.md` are dated history and stay as written.
- The root `README.md` links to `docs/guide/README.md`.

### Calls made after the builder check (mine, for the owner to check)

- **Only what ships on `main`.** Unshipped plan phases are not mentioned: Linear's Desktop consumers, Automations P4 and P5 part 2, first-run "Try this", diff reviewer Plans 2–3. A page is updated when its feature ships. No roadmap, no "coming soon".
- **Code beats `docs/features/`.** When they disagree, the guide follows the code and the builder notes the disagreement on the board. Pages carry no "verified at" stamps.
- **Known bugs a user can hit** (from `docs/backlog/` and the repo's GitHub issues #274–#292, read with `gh`) go into troubleshooting with their workaround. They come out when the bug is fixed.
- **One tour route.** Each stop says what it needs ("needs a calendar") and how to skip it, so the tour doesn't branch by goal.
- **Pages land incrementally** while `app-guide.md` still exists. The plan keeps a coverage ledger listing every `app-guide.md` section, its new page, and anything dropped and why. The last task checks the ledger, then deletes the file.
- **Checks before merge:**
  - every relative link resolves;
  - every guide page appears exactly once in the catalogue;
  - no feature page goes over about 8 KB without a reason;
  - leak-check.

  These are one-off script runs in the plan, not a committed tool. Each page also gets an accuracy review against the code, which is the main review for a docs PR.
- **Headings are anchors.** #426's agent and other pages link to them, so they stay stable. `WRITING.md` says this, and limits depth to `##` and `###`.

## Constraints

- English, plain GitHub Markdown. Relative links must resolve on GitHub. Mermaid only where a picture explains a mechanism, such as the sync cycle; no images.
- Public repo: the leak-check rules apply.
- Accuracy needs reading code across Go and Swift. The plan should give each task its feature's code paths and `docs/features/` file.

## Left to the builder

- The exact concept, troubleshooting and Workbench sub-page sets, guided by the lists above and by real failure modes.
- File names (kebab-case), and how to order tasks and PRs.
- The first-week tour's route. It should touch every feature group once, in the order a new user meets them: setup → first sync → Home → morning briefing / Catch Up → targets and Inbox → meetings → Workbench → automations.
