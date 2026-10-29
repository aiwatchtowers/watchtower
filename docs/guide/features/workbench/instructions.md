# Your instructions

Your instructions are standing directions you write once ("answer me in English", "test only what you touched") and every agent in a workbench, and the AI chat, follows. They work the same for Claude Code and Codex.

## Why use it

You type the same directions into every new session. A workbench can hold them for you, and can also give the agent one procedure for taking any target: read it first, ask when it is unclear, say what "done" means.

## How it works
<!-- learn
id: instructions-session
title: Give every agent standing directions
text: Write directions once in **Settings → Profile → Instructions** and every new session's brief carries them.
area: development
level: next
kind: feature
since: 0.24.0
action: hotkey:settings
-->

There are two fields, each with a global text and an addition per workbench, plus a third text for chats only (**Only in chats**, see [In your chats](#in-your-chats)):

- **Session instructions** (**For chats and agents** in Settings) are placed in the brief of every new session, and reach every chat too. The agent sees the global text, then the workbench's own text.
- **Target procedure** reaches the agent each time it sets a target to In progress, in the answer to that update. It also arrives when it takes a target that is already In progress again.

Each text holds up to 1,000 characters. A change reaches new sessions only: a running or resumed session keeps the instructions it started with. The target procedure is read at the moment of use, so it applies from the next target even in a running session.

The texts are stored in Watchtower, never in your folder, and are not part of the repository. The folder's `workflow.md` is different: it is the team's committed rules, see [Methodology](methodology.md).

### In your chats
<!-- learn
id: instructions-in-chats
title: Your instructions reach every chat
text: The text in **For chats and agents** reaches every AI chat too; **Only in chats** is for chats alone.
area: assistant
level: next
kind: feature
since: 0.25.0
action: nav:chat
-->
<!-- learn
id: instructions-remember
title: Start a chat message with remember:
text: Type `remember:` and a direction in a chat, and it is kept for all your chats from the next one on.
area: assistant
level: next
kind: tip
since: 0.25.0
action: nav:chat
-->

The same standing directions work in Chats. The **session instructions** text reaches every chat as well as every workbench session, and a separate **Only in chats** text reaches chats only. Texts you wrote for one workbench, and the target procedure, never go into a chat. The setup assistants don't use them.

To keep a direction while you chat, start a message with `remember:`, `remember this:` or `запомни:`. The rest of the message is added to **Only in chats** word for word, and the chat shows **Remembered for all chats** with **Undo** and **Open in Settings**. If the text is full, nothing is added and the chat says so. In a target's or track's chat with Memory's **Chats source** on, the same message is also saved as a [Memory](../memory.md) fact. A change reaches the next conversation; the current one already has your message.

### Suggestions

The [agent coach](../agent-coach.md) reads what you typed in your recent sessions, from both agents, and in your chats. When you gave the same standing direction in at least three sessions, it suggests adding it to your instructions. Nothing changes until you accept it. You see the newest suggestion on Home as **Coach suggests**, and all of them in a workbench's **Analytics**, under **Proposed edits**. Suggestions from before the coach took over once moved there: the newest became coach suggestions, and the others stop showing. A suggestion that moved is accepted or declined in the coach only. A suggestion you dismissed earlier is never suggested again.

## Using it

1. Open **Settings → Profile → Instructions**.
2. Type in **For chats and agents** (the session instructions), **Only in chats** or **Target procedure** and press **Save**. Lines added from chats are listed under **Added from chats**, each with **Open chat**.
3. To add to one workbench only, open its **…** menu, choose **Agent Settings…** and use **Your instructions — this workbench**.
4. Press **Preview what the agent gets…** to see the exact text for an agent and for a chat.
5. Under the fields a line says suggestions come from the coach. Open a workbench's **Analytics** to accept, edit or decline them; Home shows the newest one as **Coach suggests**, with **Accept**, **Decline** and **Open in Analytics**.

## When it's empty or wrong

- **A new session ignores a change.** The session began before you saved. Start a new one.
- **A suggestion's destination.** The card names it. Chats only: **Only in chats**. Chats and sessions together: **For chats and agents**.
- **No suggestions.** The coach runs about once a week and needs the direction in three sessions. The daemon must be running.
- **`watchtower instructions suggestion add` says "moved to the coach".** That suggestion is now a coach suggestion. Use `watchtower coach proposals`, then `coach accept` or `coach decline`.
- **A suggestion for one workbench.** When all its sessions were in one workbench, **Accept** writes that workbench's text.

## Related

- [Methodology](methodology.md): the folder's rules file and the ask guard.
- [Sessions](sessions.md): starting and resuming sessions.
- [Workbench](README.md)

For developers: [docs/features/agent-instructions.md](../../../features/agent-instructions.md)
