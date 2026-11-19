# iPhone: permission prompts and interrupts

The Watchtower iPhone app can answer a Claude Code session's permission prompt and interrupt a working agent, so a session waiting on you does not wait until you are back at the Mac. It is for anyone who already linked a phone (see [iPhone](iphone.md)).

## Why use it

An agent stops at a permission prompt while you are away from your desk. The phone shows what it wants to run, and **Allow once** lets it carry on.

## How it works

Both need a grant on the Mac. **Answer permission prompts from this phone** is its own switch with its own **Allow…** on the Mac's phone row; **Interrupt** rides on **Type into sessions from this phone**. See [Let the phone do more](iphone.md#let-the-phone-do-more).

The same **Answer permission prompts** grant covers the phone's Inbox gestures that act for you: **Approve**, **Retry** and **Dismiss** on an approval, **Make a Task**, and a card's buttons. **Reply** needs typing instead. **Done**, **Snooze**, **Hide** and plan items need no grant.

## Using it

### Answer a permission prompt
<!-- learn
id: iphone-allow-once
title: Approve a permission prompt
text: When a Claude Code session asks permission, tap **Allow once** or **Deny** on its card on the phone.
area: iphone
level: next
kind: feature
since: 0.24.0
-->

A Claude Code session at a permission prompt shows a card with the tool and what it will run, plus **Allow once** and **Deny**; until the phone may answer, the card shows the request without them and says under it how to turn answering on. **Allow once** approves that one call, never a rule (a shell command asks first). Nothing is typed into the session.

Two kinds of prompt offer only **Deny** on the phone, so you answer them on your tower to allow:

- one too long to show in full, which says **Shortened — answer on your tower to allow**;
- a file edit that changes Claude Code's, an agent's, git or shell settings (a `.claude`, `.codex` or `.agents` folder, `.git/hooks`, `.git/config`, `.watchtower/workflow.md`, or a file such as `.zshrc`, `.bash_profile`, `.mcp.json`, `.envrc` or `.gitconfig`), which says **Changes Watchtower or shell settings — answer on your tower to allow**.

The prompt stays open on the Mac too, and the first answer wins. If you already answered on the Mac, the phone's answer usually comes back **Answered on your tower**. Once the Mac takes a phone answer, the card says **Sent to the session**.

If you allowed a long-running command on the Mac, the phone keeps showing the prompt until the command ends. Answering it then does nothing; to stop the command, use the Mac.

Prompts show in **Now** under **Waiting for you** and in the Workbench badge, with no push alert. Codex sessions keep **Needs approval on the tower**: answer them there. Codex prompts and **Interrupt** are not taken from the phone. If a prompt answer reaches the Mac, it replies **Codex sessions can't answer this permission from the phone yet. Answer it on your tower.**; an Interrupt gets **Codex sessions can't be interrupted from the phone yet. Stop it on your tower.**

### Interrupt a working agent
<!-- learn
id: iphone-interrupt
title: Interrupt an agent from the phone
text: Choose **Interrupt** next to **Stop** in a session's menu to send the working agent an Esc.
area: iphone
level: power
kind: feature
since: 0.24.0
-->

**Interrupt**, next to **Stop** in a session's menu, sends the agent an Esc. It needs **Type into sessions from this phone** and shows only while a Claude Code session is **Working** with no prompt open. One that reaches the Mac over two minutes late is dropped.

## When it's empty or wrong

- **Only Deny is offered.** The prompt is too long to show, or the edit changes Watchtower or shell settings; answer it on your tower to allow.
- **Answered on your tower.** Someone answered on the Mac first; the first answer wins.
- **"Too late — answer on your tower"** after Allow once or Deny: the prompt waited too long or its session stopped.
- **"Allow answering permission prompts on the Mac: Watchtower → Settings → Mobile → Allow…"** on a prompt card. Click **Allow…** on the phone's permission-prompts line on the Mac.
- **No Interrupt in the menu.** Turn on **Type into sessions from this phone** and get the Mac's **Allow…**; it shows only while a Claude Code session is **Working** with no prompt open.

Phone not syncing? See [The iPhone is not syncing](../troubleshooting/iphone-not-syncing.md).

## Related

- [iPhone](iphone.md)
- [Sessions](workbench/sessions.md)

For developers: [docs/features/mobile-companion.md](../../features/mobile-companion.md)
