---
name: "Mail: \"triage\" # weekly \\ done — ok"
trigger:
  schedule: "30 8 * * 1-5"
missed: "skip"
concurrency: 2
permissions:
  - "gmail:read@work"
  - "llm:light"
outputs:
  - "inbox"
  - "report"
budget:
  tokens: 120000
  minutes: 10
pause_timeout_hours: 24
---
