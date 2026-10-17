# iPhone: permission prompts and interrupts

The Watchtower iPhone app can answer a Claude Code session's permission prompt and interrupt a working agent, so a session waiting on you does not wait until you are back at the Mac. It is for anyone who already linked a phone (see [iPhone](iphone.md)).

## Why use it

An agent stops at a permission prompt while you are away from your desk. The phone shows what it wants to run, and **Allow once** lets it carry on.

## How it works

Both need a grant on the Mac. **Answer permission prompts from this phone** is its own switch with its own **Allow…** on the Mac's phone row; **Interrupt** rides on **Type into sessions from this phone**. See [Let the phone do more](iphone.md#let-the-phone-do-more).

## Using it

### Answer a permission prompt

A Claude Code session at a permission prompt shows a card with the tool and what it will run, plus **Allow once** and **Deny**. **Allow once** approves that one call, never a rule (a shell command asks first). Nothing is typed into the session.

Two kinds of prompt offer only **Deny** on the phone, so you answer them on the Mac to allow:

- one too long to show in full, which says **Shortened — answer on the Mac to allow**;
- a file edit that changes Claude Code's, an agent's, git or shell settings (a `.claude`, `.codex` or `.agents` folder, `.git/hooks`, `.git/config`, `.watchtower/workflow.md`, or a file such as `.zshrc`, `.bash_profile`, `.mcp.json`, `.envrc` or `.gitconfig`), which says **Changes Watchtower or shell settings — answer on the Mac to allow**.

The prompt stays open on the Mac too, and the first answer wins. If you already answered on the Mac, the phone's answer usually comes back **Answered on the Mac**. Once the Mac takes a phone answer, the card says **Sent to the session**.

If you allowed a long-running command on the Mac, the phone keeps showing the prompt until the command ends. Answering it then does nothing; to stop the command, use the Mac.

Prompts show in **Now** under **Waiting for you** and in the Workbench badge, with no push alert. Codex sessions keep **Needs approval on the Mac**.

### Interrupt a working agent

**Interrupt**, next to **Stop** in a session's menu, sends the agent an Esc. It needs **Type into sessions from this phone** and shows only while a Claude Code session is **Working** with no prompt open. One that reaches the Mac over two minutes late is dropped.

## When it's empty or wrong

- **Only Deny is offered.** The prompt is too long to show, or the edit changes Watchtower or shell settings; answer it on the Mac to allow.
- **Answered on the Mac.** Someone answered on the Mac first; the first answer wins.
- **No Interrupt in the menu.** Turn on **Type into sessions from this phone** and get the Mac's **Allow…**; it shows only while a Claude Code session is **Working** with no prompt open.

Phone not syncing? See [The iPhone is not syncing](../troubleshooting/iphone-not-syncing.md).

## Related

- [iPhone](iphone.md)
- [Sessions](workbench/sessions.md)

For developers: [docs/features/mobile-companion.md](../../features/mobile-companion.md)
