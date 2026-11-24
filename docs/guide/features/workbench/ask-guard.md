# The ask guard

The ask guard makes sure a workbench agent's question reaches you as an ask instead of scrolling past in its terminal. It is on by default in every workbench session; how asks are answered is on [Asks](asks.md).

## Why use it

A question an agent writes as plain text in the terminal is easy to miss, and the agent waits for an answer you may never see. The guard sends such a question back to the agent to file as an ask, so it waits in **Waiting for you** with every other one.

## How it works
<!-- learn
id: asks-ask-guard
title: Never miss a question in the terminal
text: A question the agent types as plain text is sent back to it to file as an ask, so it lands in your list.
area: development
level: power
kind: tip
since: 0.24.0
-->

By default (ask guard **strict**, finish check **on**), Claude Code's own question dialog is turned off in a workbench session. A check at the end of every agent turn sends any question written as plain text back to the agent to file as an ask. The finish check sends back a turn that reports the work done without marking the session **Finished**, and lets the agent finish only the whole target it was started for, its changes checked against the reviewer's AI overview; what it leaves comes to you as one ask.

One short question may stay in the terminal while you are in that session. If you don't answer it, Watchtower files it for you as a Quick ask marked **From chat · N min**. It becomes a regular ask when it does not fit a Quick ask (four options, or an option label over 40 characters), and so does a request recorded under **soft**. Its title is the question, the agent's context below it; a yes/no question gets Yes and No buttons. It is filed:

- after 10 minutes unanswered;
- after you have been away from the session for 90 seconds;
- at once, if you were already away when the agent asked.

A half-typed reply in Claude Code's input holds the question back for up to 30 minutes. If you answer in the terminal, nothing is filed.

## Using it

The methodology can change this; see [Methodology](methodology.md) and **Agent Settings…**. With **soft**, Claude Code's question dialog works while you are in the session, and plain-text questions are recorded instead of bounced back. With **off**, nothing is checked. The finish check can be switched off on its own.

## When it's empty or wrong

- **A question is still in the terminal.** One short question may stay there while you are in the session. It is filed after 10 minutes unanswered or 90 seconds away; a half-typed reply in Claude Code's input holds it back for up to 30 minutes.
- **Plain-text questions are not bounced back.** The guard is **soft** or **off** for this workbench; see **Agent Settings…** and [Methodology](methodology.md).

## Related

- [Asks](asks.md), [Sessions](sessions.md), [Methodology](methodology.md)

For developers: [docs/features/workbench.md](../../../features/workbench.md)
