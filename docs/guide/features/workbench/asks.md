# Asks

An ask is how the agent in a workbench session gets something from you: a review, a check to try by hand, or a decision. It is for anyone who lets an agent run unattended and wants to be pulled in only when needed.

## Why use it

A question typed into a terminal is easy to miss and blocks the agent until you see it. An ask is filed on the board instead. The agent keeps working on what doesn't depend on your answer, and every open ask from every session waits in one list.

## How it works

The agent files an ask through a Watchtower tool. There are three kinds, and two levels.

| Kind | What you do |
|---|---|
| **Review** | Read a spec, plan or design the agent wrote. Comment in the margin, then **Request changes** or **Approve**. |
| **Check** | Try something by hand. Mark each step **✓ Works**, **✕ Doesn't work** (say what happened) or **– Didn't check**. |
| **Question** | Pick an option per question, or write your own. |

**Full** asks open in a drawer next to the session's terminal. A **Quick** ask is one question with two or three short options; it never opens the drawer by itself. It shows as buttons on a banner over the terminal. Reviews and checks are always Full.

### How the answer reaches the agent

Your answer is saved first. Then one line is typed into that session's terminal and sent, for example "Ask #12 answered (review: approved) — read it with get_ask 12 using the watchtower-workbench skill." If the agent is still working, Claude Code queues the line for its next turn.

Watchtower is careful not to talk over you:

- If a permission prompt is waiting, nothing is typed into it. The line **Answer saved — it goes to Claude once the permission prompt is resolved** shows, and the answer follows afterwards. **Dismiss** cancels the sending and gives the answer to the agent in the session's next brief.
- If Claude Code's input already holds unsent text, the answer is typed but not sent: **Answer typed into the terminal — press Return to send**.
- If the session is not running, nothing is typed. The agent reads the answer when the session starts again.
- If the agent withdrew the ask or replaced it with a newer round while you answered, nothing is sent and your draft is kept (**Discard draft** drops it).

### The ask guard

By default (ask guard **strict**, finish check **on**), Claude Code's own question dialog is turned off in a workbench session. A check at the end of every agent turn sends any question written as plain text back to the agent to file as an ask. The finish check reminds an agent that says its work is done to mark the session **Finished** with a short summary.

The methodology can change this; see [Methodology](methodology.md) and **Agent Settings…**. With **soft**, Claude Code's question dialog works while you are in the session, and plain-text questions are recorded instead of bounced back. With **off**, nothing is checked. The finish check can be switched off on its own.

One short question may stay in the terminal while you are in that session. If you don't answer it, Watchtower files it for you as a Quick ask marked **From chat · N min**. It becomes a regular ask when it does not fit a Quick ask (four options, or an option label over 40 characters), and so does a request recorded under **soft**. It is filed:

- after 10 minutes unanswered;
- after you have been away from the session for 90 seconds;
- at once, if you were already away when the agent asked.

While a half-typed reply sits in Claude Code's input, the question waits, for at most 30 minutes from the question. If you answer in the terminal, nothing is filed.

## Using it

### Find your asks

Open asks wait, oldest first, in **Waiting for you (N)** at the top of the sessions panel. Each row shows the kind, the title, the ask number (`#145`), what to do next (**Review doc**, **Answer 2 questions**, **Run 3 checks**), the session and its age. Each session row shows its open count, and **▸ N closed** lists its past asks. Asks filed from your own terminal app are grouped as **Outside the app**.

When the agent writes `ask #145` in the terminal, that text is a link. Hover it for a card, click it to open the drawer.

### Answer an ask

1. Open the ask. A new Full ask opens by itself next to its session's terminal once that session is on screen, without taking your keyboard. **k of N** in the header moves to the next one.
2. Read the summary and the points the agent wants you to look at. On a later round, **Show diff** compares the versions.
3. Fill in the answer. Every ask has an optional **Note for the agent**.
4. Press the main button at the bottom: **Answer**, **Send** or **Approve**. The line above it says what is still missing, for example "Answer every question".

**Later** (or ×) closes the drawer and keeps everything you entered. It stays closed until the agent files another Full ask, and a banner over the terminal says **Agent asks: #N …** with **Open**.

### Answer a Quick ask

Click one of the option buttons on the banner. The option the agent recommends comes first and is highlighted. **Reply…** swaps the buttons for a one-line field (at most 500 characters), and **Details** opens the ask in the drawer.

### Use the keyboard

Press **⌃⌘A** (Navigate › **Show Waiting for You**) anywhere in the workbench window to put the keyboard on the oldest ask. It is the only key that takes the keyboard from the terminal. After that:

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
- **A closed ask says "withdrawn by the agent" or "replaced by #N".** The agent withdrew it or filed a newer round. It opens read-only.
- **Unsent answers on quit.** Drafts survive switching sessions, workbenches and tabs. Quitting Watchtower with unsent answers asks first.

## Related

- [Sessions](sessions.md), [Workbench overview](README.md)

For developers: [docs/features/workbench.md](../../../features/workbench.md)
