# Automations — business spec

**For:** the owner. One page. The tech spec is `2026-10-14-automations-design.md`; each phase gets its own plan
under `docs/superpowers/plans/` (`2026-10-14-automations-p1.md` … `-p6.md`).

## The problem

- Recurring work over Watchtower data — "summarise new mail into my inbox", "a Jira state report every Monday",
  "a team performance report", "go through the open PRs with me twice a day" — today needs the owner to open a
  chat and ask again each time. Nothing runs on its own, on a schedule, or when something changes.
- In a workbench, repeatable procedures (release, deploy to test or stage) live in the owner's head or a README;
  there is no button that runs the procedure the same way every time, with the owner in the loop where it matters.
- The assistant can already propose writes (Agent Actions), but only inside a conversation. There is no way to
  say "do this every morning" and trust it to stay inside what you allowed.

## What you will see and do

**An automation is one Markdown file** (a recipe): a short header that says when it runs, what it may touch, how
how many tokens it may spend and where it reports; a plain description; and one JavaScript script. The script reaches the
world only through Watchtower: read your synced data, call the assistant (`llm`, `agent`), use the assistant's
tools, ask you a question, keep a small memory between runs, and write its results to your inbox, the briefing, a
report, a target or Slack. In a workbench it can also open a visible agent session and run the exact commands you
listed (e.g. `make release`).

**Creating one.** In the main chat you describe it in words ("every weekday at 9, summarise new work mail into my
inbox"). The assistant drafts the recipe, tries it on your real data (writes are only shown, never made) and
puts a card in the chat: trigger, permissions, outputs, budget and what the trial run produced. **Save** is your
approval. You can also start from the **template gallery**, seeded with your five examples: new mail → inbox
summary; workbench PR review rounds with you twice a day; a Jira state report; a team performance report;
workbench Release / Deploy to test / Deploy to stage buttons.

**The Automations tab.** A list (name, trigger, next run, last result, tokens spent this week). An automation's card shows
the recipe, its run history (each run opens into its steps: every call, what it returned, how many tokens it spent, how long
it took), and **Run now**, **Dry run** and **Enable**. Editing: a form for the trigger, permissions, budget, auto
grants and on/off; the script in the code editor you already know from the workbench; or **change it in words**
in a small chat attached to the automation, which shows the diff before you save.

**When it runs.** On a schedule, from a button, or when new data arrives (new mail, a Jira issue changed, new
Slack messages, calendar or Confluence changes). If the Mac was asleep or off at the scheduled time, it runs once
when the Mac is back (or skips, if you chose so). Each run has its own token and time limit. A run that hits a limit stops and says so.

**Writes stay yours.** Anything that changes the world (create a target, a Jira issue, a Slack message) is a
proposal card in your Inbox, labelled with the automation and the run number, and needs your Approve — exactly as
in the chat. The script keeps going after proposing, or, if it asked to, waits for your decision. For a specific
automation and tool you can grant **auto** (from the Desktop only): then that write happens without a click,
appears in your Inbox as a done fact, and is logged in the run. Auto is tied to the exact script, permissions, schedule and
budget: any such edit — yours or the assistant's — pauses it until you confirm again.

**Safety.** The header's permissions are the only thing an automation may do; anything else is refused and shown
in the run. Widening permissions on save shows you the difference to confirm. A recipe that appears or changes
outside Watchtower (e.g. pulled from git into a workbench) does not run until you confirm it. Changing an
automation's schedule or budget also waits for your confirmation (ask #294). The script never
sees a password or token.

**In a workbench.** Recipes live in the repository under `.watchtower/automations/` and are shared with the code.
Button automations appear in the workbench header (Release, Deploy to stage). An automation that opens a session
opens a normal, visible session you can watch and answer; if the app is closed, the run waits for it.

## Decisions already made (asks #259–#267, 2026-10-14)

- Name **Automations**; command `watchtower automations`; for managers and developers alike from the first release.
- Recipe = Markdown file with a JavaScript script in an embedded sandbox; the assistant (`agent()`) is one tool of
  the script, not its heart.
- Writes go through the existing approval flow; only you approve (unchanged).
- **Auto for external writes (ask #265):** allowed per (automation, tool), granted by you in the Desktop only,
  bound to the recipe's content, dropped by any edit. This changes the existing rule "external writes never run
  without approval" (AGENT-03) — the exact new wording is in the tech spec §14.2.
- Storage (ask #266): personal recipes are files in Watchtower's data folder; workbench recipes in the repo, under
  `.watchtower/automations/` (renamed from the `.watchtower/actions/` in the ask, to match the feature name). The
  database keeps only the index, schedules, grants and run history.
- Authoring (asks #259, #266): chat + skill, Save = approve; form, code editor and "change in words" for edits.
- All six phases ship in the first release (ask #267), on one shared branch; main only with your approval.

## Decided after review

Approved in ask #269; the tech spec's open questions were answered in ask #270 and are pinned in its §20
(budgets are in tokens, not dollars; email is read from the local synced store; results may appear in the Inbox;
the automation's own chat may save; the feature is on by default).

## Out of scope (v1)

Reaction commands stay as they are (not migrated). No automation marketplace or sharing beyond a workbench repo.
No network, files or packages for the script — only the SDK. No external MCP writes (Quick Connections stay
read-only). No runs on another machine or in the cloud; nothing runs while the Mac is off. No mobile editing of
automations.

## How we know it's done

- Each of the five gallery templates installs, dry-runs on real data and runs on its trigger; the PR review and
  release buttons work from the workbench header with a visible session.
- A run that exceeds its budget or time stops with that status; a failed run changes nothing in the
  automation's memory; a Mac asleep through two scheduled times produces exactly one catch-up run.
- An edit to a recipe with auto stops auto until you confirm; a recipe changed in git does not run until you confirm.
- Every call of every run is visible in the history with its token spend, and the week's token spend per automation is shown.
