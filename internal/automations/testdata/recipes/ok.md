---
name: New mail summary
trigger:
  schedule: "0 9 * * 1-5"
permissions:
  - gmail:read@work
  - llm:light
outputs: [inbox]
---
Summarises new mail from the work account every weekday morning.

```js
const mail = tool("list_emails", { account: "work" });
output.inbox({ title: "Mail", body: llm("Summarise", mail) });
```

Shown on the card below the script.
