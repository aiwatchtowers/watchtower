# Buttons on automation cards

An automation can leave a card in the [Inbox](inbox.md) with buttons of its own: open a page, talk it over in Chat, hand it to a coding agent, make a task, or send a reply that runs the recipe again. This page is for anyone who writes or confirms such a recipe.

## Why use it

A recipe that watches your Jira board leaves a card, "PAY-12 has been blocked for 3 days". Beside it sit **Open PAY-12** and **Nudge the owner**. You press the second one and the recipe runs once more, this time to draft that nudge. The card is the place where you decide; the button is the next step.

## How it works
<!-- learn
id: buttons-card-actions
title: Put buttons on automation cards
text: Give `output.inbox` up to four `actions` to open a page, start a chat or hand the card to an agent.
area: automations
level: power
kind: feature
since: 0.24.0
action: nav:automations
-->

A card is written by `output.inbox({title, body, priority?, link?, actions?})` (or with `blocks` instead of `body`, see [How an automation's card looks](automations-card-look.md)); `priority` is `"high"`, `"medium"` or `"low"`, and any other value throws a validation error (the run fails unless the script catches it). `actions` holds up to four buttons, each with a `label` of at most 40 characters and exactly one kind:

| Kind | Key | A press does |
|---|---|---|
| Link | `open: "<url>"` | Opens the page. Only `http`, `https` and `watchtower-nav://` links work. |
| Chat | `chat: "<first message>"` | Opens a new chat in **Chats** with the card attached and the message in the composer. Nothing is sent. |
| Agent | `agent: {task, workbench?}` | Adds a target to the workbench and starts a session on it. |
| Reply | `reply: "<value>", data?: {…}` | Queues one run of the same recipe. |
| Task | `target: {title, intent?, parent?}` | Proposes a new task; nothing is created until you approve it. |

The first button is the prominent one. Set `primary: false` on the first one to make it plain; `primary` is refused anywhere else and can't be `true`. `chat` and `task` take up to 4 KB, a reply `value` up to 100 characters and `data` up to 8 KB of JSON.

A `chat` message and an Agent `task` are instructions: the chat or the agent does what they say. Write them as fixed text in the recipe, never built from an email, a Slack message or `llm()` output. Put such material in the card's `body`; it reaches the agent fenced as data. Hover over an Agent button to read its workbench and task before you press.

A button never grants a permission. Link, Chat and Agent only navigate or prepare. A Task press only proposes. A Reply runs the recipe you confirmed, under the permissions you confirmed. Links are checked when the recipe writes the card and again when you press.

Under the recipe's own buttons every card has a common row:

- **Open source** (only when the card has a link).
- **Discuss in Chat** attaches the card and names it by title in the first message.
- **Hand to Agent…** works in the button's `workbench`, or the recipe's own workbench, or asks you to pick. The card is fenced as data in the task, so the agent doesn't take its words as instructions.
- **Done** and **Dismiss**.

### Replying to a card
<!-- learn
id: buttons-reply
title: Answer a card to run it again
text: A **Reply** button runs the recipe once more with your choice, such as drafting a nudge; it needs `inbox:reply`.
area: automations
level: power
kind: feature
since: 0.24.0
action: nav:inbox
-->

A Reply press runs the recipe once with `trigger.kind === "reply"` and `trigger.reply = {output_id, action, value, data, card: {title, link}}`. The `data` is read back from the stored card, not from the screen. One press is one run; it is never merged with another run. A card takes one press, and the button then reads **Sent — run #N**.

A recipe needs the permission `inbox:reply` to write a Reply button. The confirming screen lists it as **Reacts to its own Inbox buttons**, and it is part of what you confirm.

### Making a task from a card
<!-- learn
id: buttons-make-task
title: Turn a card into a task
text: A Task button on an automation's card proposes a task; approve it in the Inbox and it lands on your list.
area: automations
level: next
kind: feature
since: next
action: nav:inbox
-->

A Task button proposes `create_target` with its `title` (up to 200 characters) and `intent` (up to 1000), and waits for your **Approve** on its approval card in the Inbox, like any other proposal. It is never approved for you, whatever you trusted elsewhere. With `parent`, the task goes under that personal task, which must still be open when you press and when you approve. A recipe needs `target` in its outputs to write a Task button.

The button shows where its proposal is:

| Button | Means |
|---|---|
| The label with a checklist icon | Not pressed yet, or the last proposal was rejected or dismissed, or its task deleted. |
| **Waiting for approval** | A click opens the approval card; it never proposes twice. |
| **Creating task…** | You approved it and the task is being made. |
| **Task created** | A click opens the task. |
| **Didn't finish** with **Try again** | Making the task stopped part-way. **Try again** finishes the same proposal and never makes a second task. |
| **Couldn't create the task: …** with **Try again** | The task wasn't made, for example because its parent is closed. |

A living card that changes the button's task shows a fresh button; an identical button keeps its state.

## Using it

A recipe with a Reply button:

```
output.inbox({
  title: "PAY-12 is blocked",
  body: "No change for 3 days.",
  link: "https://example.com/browse/PAY-12",
  actions: [
    {label: "Nudge the owner", reply: "nudge", data: {issue: "PAY-12"}},
    {label: "Open PAY-12", open: "https://example.com/browse/PAY-12"}
  ]
})
```

Its permissions include `inbox:reply` and its outputs include `inbox`. In the script, check `trigger.kind === "reply"` first and branch on `trigger.reply.value`.

1. Open the card in the Inbox's **Automations** filter.
2. Press **Nudge the owner**. The button changes to **Sent — run #N**.
3. Follow the run from the card's source line or from the automation's **History**.

## When it's empty or wrong

- **A Reply button is dimmed with "Needs confirmation".** The recipe isn't confirmed (or changed since you confirmed it). Open the automation, review and confirm it; the button works again.
- **Dimmed with "Off".** The automation is turned off. Turn it on from its card.
- **"Recipe can't be read".** The file has a parse error; fix it in the editor.
- **Dimmed with "Recipe removed".** The automation's file is gone, so its Reply buttons can't send. Done or Dismiss the card.
- **`output.inbox` fails with PermissionDenied.** A Reply button needs `inbox:reply` in the recipe's permissions.
- **A link does nothing.** Only `http`, `https` and `watchtower-nav://` links open. `output.inbox` refuses any other when the card is written.
- **"Couldn't propose the task: …".** The proposal was refused, for example `parent_id: task #N is closed`. The button stays pressable.
- **`output.inbox` fails with "a target action needs outputs: [target]".** Add `target` to the recipe's outputs.
- **Hand to Agent… asks which workbench.** The recipe names none, or the name matches none or two. Pick one.

## Related

[Inbox](inbox.md), [Automations](automations.md), [How an automation's card looks](automations-card-look.md), [Confirmation, budgets and writes](automations-safety.md)

For developers: [docs/features/automations.md](../../features/automations.md)
