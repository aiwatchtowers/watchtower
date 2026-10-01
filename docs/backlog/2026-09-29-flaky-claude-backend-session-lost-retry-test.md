---
type: bug
title: TestClaudeBackend_SessionLostFromResultErrorsRetriesWithReplay is flaky on CI
status: open
priority: med
tags: [test, flaky, chat, ci]
context: seen failing on CI for PR #16 and PR #23 (neither touches internal/chat); passes locally
created: 2026-09-29
---

`internal/chat`'s `TestClaudeBackend_SessionLostFromResultErrorsRetriesWithReplay`
fails intermittently on CI with `claude_backend_test.go:513: no text_delta event
within 10s`, on branches that never touch `internal/chat`. Locally it passes
(`go test ./internal/chat -run TestClaudeBackend_SessionLost -count=3`).

Likely a fixed 10 s wall-clock wait on a fake `claude` stub that spawns a child
process and a replayed session under a loaded CI runner. Worth checking:
- whether the test waits on an event it could instead synchronize on (a channel
  or a stub-side "ready" line) rather than a timeout;
- whether the retry-with-replay path adds a second stub spawn whose startup
  cost is what blows the budget;
- that the stub's process group is reaped on the timeout path (house rule).

A red Go Test on an unrelated PR costs a full CI re-run each time.
