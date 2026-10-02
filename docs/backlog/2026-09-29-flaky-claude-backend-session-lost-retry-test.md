---
type: bug
title: TestClaudeBackend_SessionLostFromResultErrorsRetriesWithReplay is flaky on CI
status: done
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

## Resolution (2026-10-01)

Not a slow runner: a real race in `claudeBackend`. The warm `--resume`
child reports the rejection (an error `result`) before the owner's turn
arrives. When it is still alive at that moment, `claimForSend` drains its
buffered events — the `session_lost` error included — and writes the turn;
the child then exits, and `exitOutcome` saw a child that had produced a
result (`gotResult`) and no stderr rejection, so it ended the turn as a
plain exit (`internal`) instead of the fresh retry. The test then waited
10 s for a `text_delta` that never came.

Fix: the recorded rejection (`lostMsg`) is now consulted for a live child
in `ensureProcLocked` (straight to the fresh retry) and in `exitOutcome`.
Made deterministic by `TestClaudeBackend_ResumeRejectedBeforeTheTurnOnALiveChildRetriesFresh`
(fake mode `lost_result_linger`), which failed with the exact CI message
before the fix. The sibling flake
`TestClaudeBackend_ResumeRejectedBeforeFirstTurnIsNotRespawned/lost_result`
had the exited-child twin: `rejectedResume` gave the reader only 500 ms to
reach the rejection line, so under load it respawned the doomed `--resume`.
It now waits up to `exitedOutputWait` (5 s, after the sweep, so it ends at
EOF; skipped when the result already settled it), `exitOutcome` does the
same, and the reader stores the rejection before marking the result. That
half is a timing fix: no test pins it (a 500 ms bound passes locally too).


## Follow-up (2026-10-02)

`.../lost_result` still flaked on CI (three spawns instead of two). The bigger
wait could not help: `rejectedResume` waits for the reader while holding
`b.mu`, and the reader took `b.mu` in `noteSessionID` for the rejection line's
`session_id` — so it blocked until the wait hit its 5 s bound, the rejection
was never seen, and the dead `--resume` was respawned. Reproduced every time
by delaying the reader of a resumed child by 300 ms. Fix: `noteSessionID`
records the id on the child (lock-free); `resumeLocked` promotes it under
`b.mu`. Pinned by `TestClaudeBackend_RejectedResumeSeenWhileHoldingTheLock`,
which failed (5 s, no rejection) before the fix.
