---
type: bug
title: "Token files for rotating refresh tokens are rewritten in place, with no cross-process coordination"
status: open
priority: med
tags: [auth, tokens, atomicity, concurrency, jira, outlook, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track bugs (Go sync/daemon/integrations)
created: 2026-09-26
---

**Where:** internal/jira/auth.go:104-114, internal/jira/client.go:117-167, internal/imap/credentials.go:47-55, cmd/sync.go:1078-1100, internal/gmail/auth.go:97-106, internal/calendar/auth.go:111, internal/slack/token_store.go:50, internal/caldav/credentials.go:55
**Confidence:** med

Every provider token store saves with `os.WriteFile(path, data, 0o600)`, which truncates and rewrites the file in place. `externalmcp.SecretStore` already does temp+rename properly. This matters most where the refresh token rotates on every refresh:
- Atlassian: Jira, on every access-token expiry.
- Microsoft: the Outlook `RefreshFunc` refreshes on every IMAP cycle, roughly every 15 minutes, and saves the new refresh token each time. A failed save is only logged.

Two failure modes follow:
1. A crash or power loss mid-write leaves a truncated JSON file. The account then needs a re-login.
2. The daemon and a concurrently running CLI (`jira boards --account` from the Desktop refresh, `jira create`/action apply) share `jira_token_<id>.json` behind only an in-process mutex. Both can load the same expired token and refresh with the same refresh token. The loser can get `invalid_grant`, which maps to `ErrAuthRevoked`, and the daemon then stamps the account `revoked` even though a valid token sits on disk. A reader that catches the file mid-truncate gets "parsing token".

`os.WriteFile` also does not tighten the mode of an existing file. Fix: temp+rename (the SecretStore helper) for all stores, plus a flock around load→refresh→save.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
