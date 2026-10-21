# Automations in the panel, and an Inbox you can read — design

**Date:** 2026-10-21 · **Board:** under #405 (Automations) · **Status:** draft for the owner's review

Decided with the owner in asks #466–#470, #472, #473. Mockups: `.superpowers/brainstorm/19386-1792552495/content/automations-kit-v5.html`. They are local and not committed; the screens are described below.

Scope: **A** — the Automations screen; **B** — the Inbox and card actions. **C** (reaction commands and tracks rewritten as preinstalled recipes) is a separate design that comes after this one. Until C lands, the Reactions and Tracks segments stay as they are (§A6).

## Why

The owner's five complaints, in their words:

1. There are pop-ups everywhere. Everything should be done in place, in the right panel.
2. Creating an automation should land in a chat to work in.
3. Automations are saved off, and it isn't obvious that they need turning on.
4. The first step should be an explicit choice of what the automation is for (Personal or a workbench). Today the owner builds in Personal and then moves it.
5. "Put it in my Inbox" is the most common ask, and what lands there is unreadable. The screenshot showed full permission dumps of "Save automation …" proposals stacked one after another, plus plain-text automation cards with only Done/Dismiss.

## Goals

- No sheet anywhere in the Automations flow: New, template, edit, save and confirm all happen in the right panel.
- The first thing after **+** is choosing what the automation is for, then how to start. From a workbench, the first choice is skipped.
- The chat is the default way to create and to edit.
- **Save and Turn On** is the main action. A saved automation is on unless the owner picks **Save Turned Off**.
- The Inbox reads like mail: a list on the left, one card in full on the right with rendered markdown, and buttons on it.
- Card buttons are general, not built for issue triage. A recipe or an agent defines its own buttons from four fixed kinds: **Link**, **Chat**, **Agent**, **Reply**. Every card also has Open source / Discuss in Chat / Hand to Agent / Done / Dismiss.

## Non-goals and anti-goals

- **No moving an automation between Personal and a workbench** (ask #469). Choosing explicitly at the start replaces moving.
- **No weakening of "what was confirmed is exactly what runs"** (AUTO-06). The owner's press on a screen that shows every hashed field is still the only thing that confirms. A button on an Inbox card never widens what a recipe may do.
- **Anti-goal:** a card action vocabulary shaped around today's issue-triage case. The owner was explicit that customers will invent their own uses.
- **Anti-goal:** a screen that looks foreign to the app. Build it from the Desktop kit (`docs/design/desktop-style-guide.md`), with English UI, a **+** icon button instead of "New", one prominent action per screen, and soft fills with no row dividers.

## A — The Automations screen

### A1. Layout

The screen is a `PanelSplit`: the list on the left and the detail panel on the right. The detail panel shows one of these, all in place:

- the "new" flow (A2);
- a template (A3);
- the chat editor with its draft (A4);
- an automation's card (A5).

The list header is the title "Automations", then a **+** icon button (`.kitIcon`), then Search.

Rows are grouped by section: Personal, then each workbench, each with a count. A row shows:

- the name;
- an on/off dot;
- one line under the name: when it runs, or "Off · …";
- a chip when it needs attention (Needs confirmation, Paused, Can't read) or is a draft.

An unsaved draft sits in the list as a row named after the draft (or "New automation"), with a "Draft" chip, so the owner can leave it and come back. The editor draft cache in `<workspace>/automation-drafts/` already keeps it.

These are removed:

- the **Templates** header button;
- the "+ New" text button;
- `NewAutomationSheet`, `AutomationTemplateGalleryView` (as a sheet), `AutomationConfirmSheet`, `AutomationSaveSheet`, `AutomationChangeInWordsSheet`;
- the edit form as a sheet.

A sheet may remain only where the style guide allows one, for a short blocking flow. Delete's confirmation stays a confirmation dialog.

### A2. + → "What is it for?" and "How do you want to start?"

One panel with two choices, and **Continue**.

**What is it for?** Tiles:

- **Personal**: "Your mail, Slack, calendar and trackers. Results go to your Inbox and briefing."
- One tile per workbench: "Its board, agent sessions and shell in <folder>."

The caption says this decides what it can see and where its recipe lives, and that it can't be moved later.

When **+** is reached from a workbench (the ⚡ menu's New Automation…), this choice is already made and is not shown.

**How do you want to start?**

- **Describe it in words**, the default selection.
- The templates whose `scope` matches the first choice (`internal/automations/templates/index.json`). For example, Personal shows New mail summary, Jira state report and Team performance report; a workbench shows PR review rounds and Release and deploy buttons.
- Once C lands, "Watch for something" (a track) joins this list. That belongs to C.

### A3. A template in the panel

Picking a template shows, in the panel:

- its description;
- its parameters as inline fields (`params`: label plus example as the placeholder);
- its notes;
- the same When / Sends / It may / Each run boxes as the draft column.

Two actions:

- **Save and Turn On**, the primary. It installs the template into the chosen scope, confirms the `approval_hash` that was shown, and enables it.
- **Adjust in Chat**. It opens A4 with the template's recipe (parameters filled in) as the starting draft. Nothing is installed until Save there.

**What the owner sees is the text that gets confirmed** *(my call)*:
- The boxes come from `validate` of the template's text with the parameters filled in, in the chosen scope. The Desktop renders the text the way `install-template` would, or `install-template` gains a `--render` that prints it.
- Save and Turn On then installs, and confirms only if the installed copy's `approval_hash` equals the one shown. Otherwise it stops at "Needs confirmation" with the fresh boxes.
- `install-template` itself stays unconfirmed and disabled, so `TestInstallTemplate_InstalledUnconfirmedAndDisabled` keeps holding. Confirm and enable are two further owner calls.

If the confirm or the enable fails after the install succeeded, the panel says so and leaves the installed copy in the list with its chip (Needs confirmation or Off). It does not roll back the install. This is my call; the install already rolls back its own failures.

### A4. The chat editor with its live draft

- **Left:** the embedded editor chat (the existing `automation_editor` surface and `EmbeddedChatView`). It opens focused, with the scope shown as a chip in the panel header.
- **Right:** the draft column, today's Draft panel restyled:
  - When;
  - It may (permissions, with "New since you confirmed" marks on an edit);
  - Sends (outputs);
  - Each run (budget);
  - Missed and Concurrency;
  - the dry-run line;
  - **Show recipe**, which expands in place in the column (no popover). An edit shows the diff here.

**Footer:**

- the hint "Saving confirms exactly what's listed above and turns it on";
- **Save and Turn On**, the primary. On an edit of an automation that is already on, it reads **Save and Confirm**;
- **Save Turned Off**, secondary.

**How a save works now.** Today, Save… asks the model to propose `save_automation`, and an Approve card under the chat reply is what saves. The new buttons save directly from the Desktop, the way the edit form already does. They use the bytes of the draft column, `save --confirm-hash <the approval_hash validate returned for those bytes> --expect-content-hash <the file's hash when the draft started>`, then `enable` when it is a Save and Turn On.

This is the third Desktop caller AUTO-06 already allows ("the Desktop confirms only what it showed"). The column must therefore show every hashed field: script, permissions, outputs, scope, trigger, missed, budget and concurrency. The script is shown through Show recipe. The column also shows the field changes since the confirmed text (D26).

The assistant may still propose `save_automation` in the main chat; that path is unchanged. In the editor chat the skill should stop proposing it and tell the owner to press Save. The skill change belongs to the builder.

**Where the hash comes from** *(my call)*:
- After any change to the draft bytes — a chat turn, a form field, a script edit — the panel runs `automations validate` on the current bytes, debounced about 500 ms after typing stops. It uses `--against <id>` for an edit.
- The returned `approval_hash` and `changes` fill the column.
- While a validate is in flight, or the bytes changed since the last one, both Save buttons are disabled with "Checking…". The hash saved is always the hash of the bytes saved.
- A brand-new recipe has no confirmed text: every line in It may is shown as new, and there is no changes block.

The header carries a `KitSegmentedPicker`: **Chat | Form | Script**.
- **Form** is today's `AutomationFormView` content, inline in the panel instead of a sheet.
- **Script** is the Monaco recipe editor, inline.
- All three edit the same draft, and the same footer saves it.

### A5. An existing automation's card

This is today's `AutomationCardView` in the panel.

**Header:** name, then a scope chip and an On/Off chip, then **Run Now**, **Edit** and **⋯**. ⋯ holds Turn Off / Turn On, Dry Run and Delete…

**Edit** switches the panel to A4 on the Chat segment. "Change in words" is gone, because Edit is that now.

**"Needs your confirmation".** The orange banner stays, but its **Review…** opens A4 with the draft column showing what changed, instead of a sheet. The footer then reads **Confirm and Turn On** (or **Confirm** when already on).

Quick run (⌃⌘R, the tray) on a row that is unconfirmed or off keeps its rule of running nothing (AUTO-06, D27). It opens this card instead of the confirm sheet.

### A6. Reactions and Tracks until C

The **Automations / Reactions / Tracks** picker stays until C replaces both with recipes. The owner decided in ask #472 that they become real preinstalled automations, which needs its own design.

So that A does not ship a half-merged list, A keeps the segments, and the segments only move into the new layout. This is my call. The v5 mockup shows the merged list that C will deliver.

"New reaction automation" becomes the A2 flow, with Personal preselected and Describe it in words started with a first chat message that asks for a `slack.reaction_added` trigger. It no longer has its own button.

The unsaved-draft rows of A1 come from the editor draft cache (`<workspace>/automation-drafts/`). They are listed at the top of their scope, newest first.

### A7. Saved means on

Templates installed from A3 and drafts saved from A4 are on unless **Save Turned Off** is pressed.

Recipes that appear by other means are still indexed unconfirmed and off (AUTO-06, unchanged): a git pull, a hand edit, an agent writing a file. Their row shows the Needs confirmation chip, and the card's banner leads to A4. That is the only remaining way for an automation to be off without the owner turning it off.

## B — The Inbox

### B1. Layout

The Inbox Actions tab becomes a `PanelSplit`: list on the left, reading pane on the right. The Learned and Profile segments stay.

**List sections, in order:**

1. **Needs your decision**: agent proposals.
2. **Today**: automation cards and due reminders, newest first.
3. **Earlier**: the same, older than today.

My call: reminders sit inside Today/Earlier by due time. The alternative was a Reminders section after Earlier. The builder may pick either; the owner did not decide this.

**A row shows:**

- an unread dot;
- the title, one line;
- a chip for high priority;
- the source line, e.g. "<automation name> · 10:00" or "Assistant proposal · 10:12";
- a one-line plain-text preview of the body.

The reaction cheat-sheet "?" stays in the list header.

**The reading pane shows:**

- the source line, "ϟ <automation> · run #<n> · <time>", which opens the run;
- the title;
- the body rendered as markdown, with the chat's renderer and its link rules: http(s) and `watchtower-nav://` only;
- the card's own buttons (B2);
- the common row: Open source, Discuss in Chat, Hand to Agent…, then Done and Dismiss trailing.

Opening a card marks it read.

*(My call.)* Read, Done and Dismiss become three separate states:

- **Read:** `read_at` is set when the card is opened. The unread dot and the Inbox badge count `read_at IS NULL`.
- **Done:** writes the new `done_at` and hides the card.
- **Dismiss:** writes `dismissed_at` and hides the card.

Today Done writes only `read_at`. The migration therefore backfills `done_at = read_at` for existing rows, so old cards the owner already marked Done do not reappear. Hidden cards are gone from the list. A "show done" view is not in scope.

**A proposal in the reading pane** is a short readable card. For `save_automation`, that is the name, the scope, when it runs, and one line of what it may do. It has **Open Draft**, which jumps to A4 with that draft loaded, and Reject.

Other proposal kinds, such as Slack send, keep `AgentActionCardView` in the pane, where it has room to read.

### B2. Card actions — four kinds

`output.inbox({title, body, priority?, link?, actions?})`.

`link` (optional) is the card's source. It drives **Open source** in the common row, which is hidden when there is no link.

`actions` (optional, up to 4) are drawn as the card's own button row. The first one is primary unless it sets `primary: false`.

Each action is `{label, <one kind>}`:

| Kind | Shape | What a press does |
|---|---|---|
| Link | `open: "<url>"` | Opens the URL: http(s), or `watchtower-nav://` for an app screen. Other schemes are refused at write time. |
| Chat | `chat: "<first message>"` | Opens AI Chat with the card attached as context and this first message in the composer, not sent. |
| Agent | `agent: {task: "<text>", workbench?: <id or name>}` | Creates a target with this task and starts a session in the workbench. A personal recipe without `workbench` asks which workbench with a small anchored picker. |
| Reply | `reply: "<value>", data?: {…}` | The automation gets the choice and carries on (B3). |

`label` is at most 40 characters, `chat`/`task` at most 4 KB, and `data` at most 8 KB of JSON. These are my numbers; the builder may tune them in the same spirit.

**The common row's Discuss in Chat and Hand to Agent** are the Chat and Agent kinds with a default text built from the card's title and body.

**Every press is an owner gesture in the app.**
- Link, Chat and Agent only navigate or prepare. Chat sends nothing, and Agent starts a session that runs on its own surface's rules.
- Reply runs the recipe under its confirmed manifest, so the button value only steers code the owner already confirmed.

The rule that nothing on a card can grant a permission holds by construction.

### B3. Reply — how the automation carries on

Inbox outputs are buffered until a run succeeds (AUTO-04). So the run that made the card has ended by the time the owner presses a button, and Reply cannot resume that run.

A press therefore **queues a new run** of the same automation. Reply is not a second trigger: a recipe has exactly one trigger (`parseTrigger`), and a scheduled triage recipe must still be able to have buttons. *(My call, from the builder check.)*

**How it is declared.** Reply is a manifest capability, `inbox:reply`, listed in `permissions` next to `outputs: [inbox]`.
- It is part of the `approval_hash` like every manifest entry.
- The owner sees "Reacts to its own Inbox buttons" in It may when confirming.
- The parser refuses a `reply` action from a recipe that lacks the capability.

**How the run is queued.** A press does not go through the event bus; it is queued directly, the way Run Now and button presses are.
- The bus's content-free rule (`TestBus_EventsCarryNoContent`) does not apply. The bus is untouched, and the payload is the recipe's own text, not external content.
- A press never merges with another run. One press is one run.

**What the script receives.** The trigger object is `{kind: "reply", reply: {output_id, action, value, data, card: {title, link}}}`. The `data` is read back from the stored output, never taken from the Desktop. Pseudocode, with the builder pinning the exact field names against today's `trigger.events[]` shape:

```js
if (trigger.kind === "reply" && trigger.reply.value === "backlog") {
  tool("update_linear_issue", …)
}
```

Its normal trigger keeps firing as before.

**Rules:**

- **One press, one run.** The card keeps a record of the press (B4). A second press of the same card is refused and shows "Sent — run #N". A press is accepted only while the card is neither done nor dismissed.
- **The recipe must still be runnable.** If it is unconfirmed or off at press time, the button is disabled with "Needs confirmation" or "Off", and clicking it opens A5.
- **Cards from an older version keep their buttons.** The run uses the currently confirmed text (AUTO-06), and an unknown `value` is the recipe's business. *(My call: disabling every pending card on each edit would punish the common "tweak the recipe" loop.)* A workbench recipe whose folder is gone fails its run like any other run.
- **Reachable from both scopes.** Personal and workbench recipes both get Reply. This gives personal automations a way to interact; `ask()` is workbench-only today.
- **Queued like any trigger.** AUTO-09 still holds: a trigger only queues. Budgets apply per run.
- **The pressing path.** The Desktop calls a new CLI verb, `watchtower automations reply --output <id> --action <index>`. The CLI writes the press and queues the run in one transaction, then wakes the daemon. It refuses under AI-agent markers (AGENT-07), because only the owner presses buttons.

### B4. Storage (for the builder)

- **`automation_outputs`** gains:
  - `link TEXT NOT NULL DEFAULT ''`;
  - `actions_json TEXT NOT NULL DEFAULT '[]'`;
  - `done_at TEXT`.
- **The press record:** either a small `automation_output_presses` table (`output_id` unique, `action_index`, `run_id`, `pressed_at`) or two columns on the output. This is the builder's choice; unique on output gives "one press per card".
- **Migration and mirrors:** a new goose migration, mirrored into `schema.sql`, the snapshot and the Swift test schema, per CLAUDE.md.
- **The manifest** gains the `inbox:reply` capability. The run's trigger kind gains `reply`, recorded on `automation_runs` as for button runs.
- **Re-validation.** `link` and `open` URLs are validated at write time, and again at press time by the Desktop's existing link rules.

**Contract changes that need the owner's approval:**

- **STRIP-02.** The Desktop still writes only the owner columns, `read_at`, `dismissed_at` and the new `done_at`. A Reply press goes through the CLI, not a Desktop write. The Observable text gains `done_at` and the press path.
- **STRIP-01.** Gains "a proposal opens in the reading pane".
- **AUTO-06.** Gains:
  - the draft column as the confirming screen;
  - A3's install-confirm-enable;
  - "a saved draft is enabled unless the owner picks Save Turned Off".

  The guard tests are not relaxed: `TestInstallTemplate_InstalledUnconfirmedAndDisabled` stays true for the CLI verb itself, and the Desktop does confirm plus enable as two further owner gestures.
- **AUTO-09.** Gains the Reply press as a trigger that only queues.

## Constraints

- **Desktop kit only.** `PanelSplit`, `.kitPrimary` once per screen, `.kitSecondary`/`.kitQuiet`, `KitSegmentedPicker`, `.card()`, `.kitRow`, `SectionHeader`, `Chip`, tokens and no literals. Lint rules apply.
- **Design shots.** Every new panel gets light and dark shots in `DesignShotCatalog` and goes to the owner as a review ask before merge.
- **User guide.** The pages for Automations and the Inbox change in the same PR (`docs/guide/WRITING.md`).
- **Feature notes.** `docs/features/automations.md` gets the new authoring and the Reply trigger. The SDK reference and the `create-automation` skill learn `link`/`actions` and `inbox.reply`.
- **Templates.** Template recipes that put cards in the Inbox may gain buttons. New mail summary is the obvious one: Open source per mailbox, Chat "Draft replies". That is optional, the builder's call.

## Left to the builder

- Phasing. My suggestion is A first, then B; A has no data change. Within B, the Go side (`output.inbox` fields, the migration, `inbox.reply`, the CLI `reply`) can go in parallel with the reading pane.
- Exact copy, widths, how the draft column's Show recipe expands, and keyboard handling. Arrow keys in the Inbox list are expected, as in mail.
- How "Hand to Agent" picks a workbench for personal cards (a menu anchored to the button is fine).
- Whether the main chat's `save_automation` card gets an "Open Draft" link too.

## Open for C (not this design)

Reaction commands and custom tracks become preinstalled recipes. This needs:

- an inventory of what the engines guarantee: REACT-01..05, REMIND-01/02, the tracks contracts;
- reaction latency versus one event flush per sync cycle;
- "preinstalled" (system) recipes, which do not exist today;
- a migration path for existing tracks and reaction settings.

It gets its own brainstorm and design.
