---
type: chore
title: "Weakest 15 Go packages by statement coverage (summary)"
status: open
priority: med
tags: [test-coverage, summary, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track test coverage (Go)
created: 2026-09-26
---

**Where:** internal/..., cmd/
**Confidence:** high

| package | stmts | own-tests % | cross-pkg % |
|---|---|---|---|
| internal/ui | 89 | 0.0 | 0.0 |
| internal/customtracks | 258 | 26.7 | 26.7 |
| cmd | — | 50.7 | — |
| internal/externalmcp | 48 | 52.1 | 52.1 |
| internal/db | 7069 | 66.6 | 79.0 |
| internal/jira | 2186 | 69.5 | 70.3 |
| internal/dayplan | 448 | 71.0 | 71.0 |
| internal/caldav | 254 | 72.4 | 72.4 |
| internal/agentloop | 111 | 73.0 | 73.0 |
| internal/tracks | 863 | 73.3 | 73.8 |
| internal/devpack | 120 | 74.2 | 74.2 |
| internal/ollama | 133 | 74.4 | 74.4 |
| internal/briefing | 453 | 75.3 | 75.5 |
| internal/imap | 357 | 75.9 | 75.9 |
| internal/targets | 523 | 77.6 | 77.6 |

Total internal/... cross-package coverage is 80.9%. The only package with no tests is `internal/ui` (CLI markdown/spinner, low risk). The raw percentages hide the real risk: `internal/db` looks weak at 66.6% on its own tests but is 79% once cross-package callers count. The dangerous gaps are the ones listed below: `customtracks`, the Jira board analyzer and field discovery, daemon wiring in `cmd/sync.go`, and the IMAP/CalDAV credential stores. `externalmcp` at 52% is not worrying: what it misses is `Delete`/`Exists` and error returns, and the atomic-save paths are tested.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
