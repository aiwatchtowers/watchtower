---
name: When I react with an emoji
trigger:
  event: {type: slack.reaction_added, where: {emoji: "<EMOJI>"}}
permissions:
  - slack:read@*
outputs: [inbox]
budget: {tokens: 20000}
---
When you react to a Slack message with the emoji named in the trigger, puts a
card with that message and its link in your Inbox. Change the emoji in
`where`, or add what the card should say, to make it your own.

The trigger names one emoji short name (for example `eyes`, written without
the colons). To watch another emoji, install the template again with it.

```js
const seen = {};
for (const e of trigger.events || []) {
  // The event carries ids only: read the message back by channel and ts.
  const key = e.channel_id + "/" + e.message_ts;
  if (seen[key]) continue;
  seen[key] = true;
  const found = tool("list_messages", { channel: e.channel_id, limit: 200 });
  const list = Array.isArray(found) ? found : (found && found.messages) || [];
  const m = list.find((x) => x.ts === e.message_ts);
  if (!m) continue; // not synced yet, or older than the last 200 messages
  const text = m.text || "";
  output.inbox({
    title: "Reacted with :" + e.emoji + ": in " + (m.channel || "Slack"),
    body: (m.sender ? m.sender + ": " : "") + (text.length > 600 ? text.slice(0, 600) + "…" : text),
    link: m.permalink || undefined,
  });
}
```
