# Asks

An ask brings you a review, a manual check or a decision from a workbench agent. You can let it work unattended and answer when needed.

## Why use it

A question typed into a terminal is easy to miss and blocks the agent until you see it. An ask is filed on the board instead. The agent keeps working on what doesn't depend on your answer, and every open ask from every session waits in one list.

## How it works

The agent files an ask through a Watchtower tool. There are three kinds, and two levels.

| Kind | What you do |
|---|---|
| **Review** | Read a spec, plan or design the agent wrote. Comment in the margin, then **Request changes** or **Approve**. A spec or plan also gets an independent reviewer, and the agent may settle its findings before the ask reaches you, so the ask can appear later than it was filed: see [Reviewing a spec or plan](spec-review.md). |
| **Check** | Try something by hand. Mark each step **✓ Works**, **✕ Doesn't work** (say what happened) or **– Didn't check**. |
| **Question** | Pick an option per question, or write your own. |

**Full** asks open in a drawer next to the session's terminal. A **Quick** ask is one question with two or three short options; it never opens the drawer by itself. It shows as buttons on a banner over the terminal. Reviews and checks are always Full.

Review links open text in **Files**, PNG/JPEG/GIF/WebP in your image app, and web pages in your browser. Local links must name an existing file inside the ask session’s folder.

### How the answer reaches the agent

Your answer is saved first. Then one line is typed into that session's terminal and sent, for example "Ask #12 answered (review: approved) — read it with get_ask 12 using the watchtower-workbench skill." If the agent is still working, Claude Code queues the line for its next turn.

Watchtower is careful not to talk over you:

- If a permission prompt is waiting, nothing is typed into it. The line **Answer saved — it goes to Claude once the permission prompt is resolved** shows, and the answer follows afterwards. **Dismiss** cancels the sending and gives the answer to the agent in the session's next brief.
- If Claude Code's input already holds unsent text, the answer is typed but not sent: **Answer typed into the terminal — press Return to send**.
- If the session is not running, nothing is typed. The agent reads the answer when the session starts again.
- If the agent withdrew the ask or replaced it with a newer round while you answered, nothing is sent and your draft is kept (**Discard draft** drops it).

### Asks from an automation

A workbench automation can ask you something too: a yes/no check or a question. It joins **Waiting for you** labelled "⚙ <automation> · run #N" where an agent's ask names its session, and you answer it the same way. Your answer goes back to the automation, never into a terminal: **Answer saved — the automation goes on with it**. Answered ones are under "⚙ Automations · ▸ N closed".

### The ask guard

A question an agent writes as plain text in the terminal is sent back to it to file as an ask, so it lands in **Waiting for you**. How the guard works and how to change it: [The ask guard](ask-guard.md).

## Using it

### Find your asks
<!-- learn
id: asks-waiting-for-you
title: Answer what the agent asks
text: Open asks from every session wait in **Waiting for you** at the top of the sessions panel.
area: development
level: basics
kind: feature
since: 0.24.0
action: nav:projects
-->
<!-- learn
id: asks-closed-list
title: Look back at closed asks
text: Click **▸ N closed** on a session to read its past asks by day, with your answers.
area: development
level: next
kind: tip
since: 0.28.0
action: nav:projects
-->

Open asks wait, oldest first, in **Waiting for you (N)** at the top of the sessions panel. Each row shows the kind, title, number (`#145`), next step (**Review doc**, **Answer 2 questions**, **Run 3 checks**), session and age. Each session row shows its open count; **▸ N closed** lists its past asks by day with status and your answer, searchable from 10; one opens read-only, Esc goes back. Asks from your own terminal app are grouped as **Outside the app**.

`ask #145` in the terminal is a link: hover it for a card, click it for the drawer.

### Answer an ask

1. Open the ask. A new Full ask opens by itself next to its session's terminal once that session is on screen, without taking your keyboard. **k of N** in the header moves to the next one.
2. Read the summary and the points the agent wants you to look at. On a later round, **Show diff** compares the versions.
3. Fill in the answer. Every ask has an optional **Note for the agent**.
4. Press the main button at the bottom: **Answer**, **Send** or **Approve**. The line above it says what is still missing, for example "Answer every question".

**Later** (or ×) closes the drawer and keeps everything you entered. It stays closed until the agent files another Full ask, and a banner over the terminal says **Agent asks: #N …** with **Open**.

### Ask the assistant what a question means
<!-- learn
id: asks-not-clear
title: Have a question explained
text: Click **Not clear?** under an ask's question and the assistant explains it in plain words.
area: development
level: next
kind: feature
since: next
action: nav:projects
-->

Click **Not clear?** under a question or a check, open or closed, and the drawer becomes a chat whose first message explains the ask in plain words: what is being decided and what each option changes for you. Ask more there, then **Back to question** (or Esc, unless the composer holds text) brings back your picks and notes as you left them.

The assistant reads the ask and, on Claude or Codex, the workbench folder; it never changes anything and never answers for you. The chat is kept per ask, so opening it again continues it. It runs on your provider's strong model, only when you click, and is on the Mac only.

### Answer a Quick ask
<!-- learn
id: asks-quick-answer
title: Answer a Quick ask in one click
text: A short question shows as buttons over the terminal; click one, or **Reply…** to write your own.
area: development
level: next
kind: tip
since: 0.24.0
action: nav:projects
-->

Click one of the option buttons on the banner. The option the agent recommends comes first and is highlighted. **Reply…** swaps the buttons for a one-line field (at most 500 characters), and **Details** opens the ask in the drawer.

### Use the keyboard
<!-- learn
id: asks-keyboard
title: Go to the oldest ask with ⌃⌘A
text: Press ⌃⌘A in the workbench window, then J and K to move between asks and Return to open one.
area: development
level: next
kind: shortcut
since: 0.24.0
action: hotkey:waiting-for-you
-->

Press **⌃⌘A** (Workbench › **Show Waiting for You**) anywhere in the workbench window to put the keyboard on the oldest ask. It is the only key that takes the keyboard from the terminal. After that:

- **J** / **K** move between asks. **Return** opens one.
- **1**–**3** answer a Quick ask with that button.
- In the drawer, **Tab** moves over the questions and steps, **1**–**9** pick an option or mark a check step, and **N** / **P** step through a review's margin comments.
- **⌘Return** presses the main button. **⌘⇧Return** presses **Request changes** on a review.

The single keys act only while nothing else has the keyboard. Letters work by key position, so they work on any layout.

### Get notified

Watchtower notifies you when an agent files an ask (**Agent asks: <title>**). Several at once in one workbench arrive as one **Waiting for you (N)** notice. Clicking a single ask's notice opens that ask next to its session.

## When it's empty or wrong

- **The drawer did not open.** The pane may be too narrow for it beside the terminal; use **Open** on the banner. Or you closed it with **Later**; it stays closed until the next Full ask.
- **The answer did not reach the agent.** Look for the highlighted line over the terminal: it says whether it is waiting for a permission prompt, typed but not sent, or copied to the clipboard because the terminal could not take it. Follow what it says.
- **Withdrawn or Replaced.** The agent withdrew the ask or filed a newer round. It moves to **▸ N closed**.
- **Unsent answers on quit.** Drafts survive switching sessions, workbenches and tabs. Quitting Watchtower with unsent answers asks first.

Answer not reaching the agent? See [A Workbench session or ask is stuck](../../troubleshooting/workbench-session-or-ask-stuck.md).

## Related

- [Sessions](sessions.md), [The ask guard](ask-guard.md), [Workbench overview](README.md)

For developers: [docs/features/workbench.md](../../../features/workbench.md)
