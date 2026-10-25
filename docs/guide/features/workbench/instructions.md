# Your instructions

Your instructions are standing directions you write once ("answer me in English", "test only what you touched") and every agent in a workbench follows. They work the same for Claude Code and Codex.

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

There are two fields, each with a global text and an addition per workbench:

- **Session instructions** are placed in the brief of every new session. The agent sees the global text, then the workbench's own text.
- **Target procedure** reaches the agent each time it sets a target to In progress, in the answer to that update. It also arrives when it takes a target that is already In progress again.

Each text holds up to 1,000 characters. A change reaches new sessions only: a running or resumed session keeps the instructions it started with. The target procedure is read at the moment of use, so it applies from the next target even in a running session.

The texts are stored in Watchtower, never in your folder, and are not part of the repository. The folder's `workflow.md` is different: it is the team's committed rules, see [Methodology](methodology.md).

### In your chats
<!-- learn
id: instructions-in-chats
title: Your instructions reach every chat
text: The text in **For chats and agents** reaches every AI chat too;**Only in chats** is for chats alone.
area: assistant
level: next
kind: feature
since: next
action: nav:chat
-->
<!-- learn
id: instructions-remember
title: Start a chat message with remember:
text: Type `remember:` and a direction in a chat, and it is kept for all your chats from the next one on.
area: assistant
level: next
kind: tip
since: next
action: nav:chat
-->

The same standing directions work in the AI chat. The **session instructions** text reaches every chat as well as every workbench session, and a separate **Only in chats** text reaches chats only. Texts you wrote for one workbench, and the target procedure, never go into a chat. The setup assistants don't use them.

To keep a direction while you chat, start a message with `remember:`, `remember this:` or `запомни:`. The rest of the message is added to **Only in chats** word for word, and the chat shows **Remembered for all chats** with **Undo** and **Open in Settings**. If the text is full, nothing is added and the chat says so. A change reaches the next conversation; the current one already has your message.

### Suggestions
<!-- learn
id: instructions-suggestions
title: Turn what you repeat into instructions
text: When you give the same direction in three sessions or chats, Watchtower offers it; press **Add** to keep it.
area: development
level: power
kind: tip
since: next
-->

Once a day Watchtower reads what you typed in your recent sessions, from both agents, and in your chats. When you gave the same standing direction in at least three sessions of the last 14 days and your texts don't hold it yet, it offers it as a suggestion. Nothing changes until you press **Add**, and once you dismiss a suggestion, that suggestion never comes back.

## Using it

1. Open **Settings → Profile → Instructions**.
2. Type in **For chats and agents** (the session instructions), **Only in chats** or **Target procedure** and press **Save**. Lines added from chats are listed under **Added from chats**, each with **Open chat**.
3. To add to one workbench only, open its **…** menu, choose **Agent Settings…** and use **Your instructions — this workbench**.
4. Press **Preview what the agent gets…** to see the exact text for an agent and for a chat.
5. When **You keep saying this** shows suggestions, press **Add** to append a line to the field, or **Dismiss**. While the field has an edit you have not saved, its **Add** is off: save or revert your edit first. Home shows the newest suggestion for a week as a card with the same buttons.

## When it's empty or wrong

- **A new session ignores a change.** The session began before you saved. Start a new one.
- **Add says "adding this line would go over the 1000-character limit — shorten the text first".** The field plus the new line would pass 1,000 characters. Shorten the field's text, press **Save**, then press **Add** again.
- **A suggestion's destination.** Chats only: **Only in chats**. Chats and sessions together: **For chats and agents**.
- **No suggestions.** The direction has to appear in three sessions within 14 days, and the daemon must be running. The check is skipped when your Claude plan limit is close.
- **A suggestion for one workbench.** When all its sessions were in one workbench, **Add** writes that workbench's text.

## Related

- [Methodology](methodology.md): the folder's rules file and the ask guard.
- [Sessions](sessions.md): starting and resuming sessions.
- [Workbench](README.md)

For developers: [docs/features/agent-instructions.md](../../../features/agent-instructions.md)
