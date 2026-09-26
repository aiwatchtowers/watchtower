---
type: chore
title: "Low-priority findings bundle — test coverage (Go)"
status: open
priority: low
tags: [go-test-coverage, review-2026-09-26, bundle]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track test coverage (Go)
created: 2026-09-26
---

7 low-priority findings from the test coverage (Go) track, bundled so the backlog
stays readable. Split any item into its own file when it gets picked up.

## IMAP/Outlook and CalDAV credential stores write secrets non-atomically and keep a pre-existing wider file mode; zero unit tests

- type: bug · confidence: med · tags: [auth, secrets, test-coverage, imap, caldav]
- where: internal/imap/credentials.go:47-56, internal/caldav/credentials.go:47-56, cmd/sync.go:1092-1096

`CredentialStore.Save` in both packages is `os.WriteFile(path, data, 0o600)`. That truncates in place, so a crash mid-write leaves an empty or partial file holding the only Outlook refresh token and forces a re-login. It also does not reset the mode of a file that already exists with wider permissions. `internal/externalmcp.SecretStore.Save` documents and fixes both problems (tmp + O_EXCL 0600 + fsync + rename), and its comment explains why this matters for a just-rotated OAuth token. That is exactly the Outlook path in `outlookAuthenticator`. Neither package has a test for its store (Load/Save/Delete/Exists are 0% in internal/). The CalDAV store is exercised only indirectly via `cmd/caldav_test.go`, the IMAP store not at all. Suggested fix: reuse the externalmcp atomic-save helper (or `slack.TokenStore`'s shape) and add round-trip plus 0600-mode tests.

## Inventory cites a guard test that no longer exists and describes the opposite behavior

- type: chore · confidence: high · tags: [test-coverage, inventory, agent-actions, docs-drift]
- where: docs/inventory/agent-actions.md:15, internal/mcp/actions_test.go:98

AGENT-01's "Test guards" line lists `TestChatMode_SkipsReadToolWithoutPanicking`, described as "the registry adapter mounts only write tools onto the chat-mode server — a read-access tool is skipped". No test by that name exists. The current test, `TestChatMode_MountsReadToolViaRegistry`, pins the opposite: read tools are mounted through the registry and return data. A reviewer checking AGENT-01's guards against the doc would look for a guarantee that no longer holds. Suggested fix: update the inventory line to name the current test and the current behavior (a doc-only edit; the contract itself is unchanged). A repo-wide scan found no other live contract citing a missing Go test. The remaining misses are historical/retired entries, and the tracks.md "Tracked gap" entries are already declared as open.

## Memory extraction: cancellation between batches (the "N windows left" path) is never exercised

- type: chore · confidence: high · tags: [test-coverage, watermark, memory, MEM-04, concurrency]
- where: internal/memory/pipeline.go:592-596, internal/memory/pipeline.go:637 (remainingWindows 0%), internal/memory/gmail_extract.go:271

`remainingWindows` is 0% even inside the 332-second memory suite. It is called only from the `ctx.Err() != nil` early-break in the extraction batch loop, for both Slack and Gmail. So no test cancels a run between two committed batches and checks that the watermark sits exactly at the last committed batch (MEM-04) and that the remaining windows are re-extracted with no duplicate episodes. Daemon shutdown mid-cycle is the common real trigger (see the 2026-09-25 shutdown-hang incident). The existing interruption tests cover an AI failure in the last batch and cancellation in rewrite/reconcile, not this loop. Suggested fix: a fake generator that cancels ctx after batch 1, then assertions on the watermark and on a re-run.

## Four daemon sync phases: per-account isolation untested and failures invisible in pipeline_runs

- type: chore · confidence: high · tags: [test-coverage, daemon, observability, silent-failure]
- where: internal/daemon/daemon.go:570-626 (phaseCalendarSync/CalDAV/Gmail/Imap 16.7% each)

Only the no-syncer early exit is covered. No test injects two syncers where the first errors and checks that the second still runs, which is the fan-out rule each doc comment states. Unlike `phaseSlackSync` (wrapped in `trackedPipelineRun("slack-sync")` since 2026-08-19) and Jira, these four phases write no `pipeline_runs` row, so a Gmail or IMAP account failing every cycle shows only in `watchtower.log`, never in Pipeline Progress. Suggested fix: fake-syncer fan-out tests. It is also worth considering tracked runs for these phases (owner call: extra rows per cycle).

## Timing-based daemon loop tests (sleep 100 ms, deadline 500 ms)

- type: chore · confidence: med · tags: [test-coverage, flaky, daemon]
- where: internal/daemon/daemon_test.go:209-221, internal/daemon/daemon_test.go:1188-1196, internal/daemon/daemon_test.go:250

The wake and trigger tests start `d.Run` with a 500 ms context, send the signal from a goroutine after `time.Sleep(100 ms)`, and require at least 2 syncs. The initial sync (a real SQLite orchestrator plus the heartbeat write) plus the wake-triggered sync must both finish inside 500 ms. On a loaded CI runner, or under `-race` (which the repo notes is already very slow for daemon/cmd), that budget is thin, and the test fails as a count mismatch rather than a timeout. Suggested fix: signal once the first sync is observed (a channel from the fake orchestrator) and use a generous deadline, the same deadline-not-spin fix PR #108 applied to the Swift wait helpers.

## Runtime-B client entry points untested; its HTTP client has no timeout

- type: chore · confidence: med · tags: [test-coverage, agentloop, ollama]
- where: internal/agentloop/client.go:55-93 (NewClient/Query/QuerySync 0%), internal/agentloop/client.go:62

The loop tests drive `run` directly, so the public `ai.Provider` surface that `cmd/generator.go:143` actually builds (default base URL, trailing-slash trim, streaming channel close order, error delivery on `errCh`) is never executed. `NewClient` uses `&http.Client{}` with no `Timeout`, unlike every other HTTP client in the repo (30 s is the house norm), so a hung Ollama/LM Studio server stalls the chat until the caller cancels ctx. Suggested fix: one `Query` test against an httptest server that asserts the chunk order and channel closure, and a bounded client or ResponseHeaderTimeout.

## Inbox watermark "never moves backwards" clamp is never exercised

- type: chore · confidence: high · tags: [test-coverage, watermark, inbox, INBOX-09]
- where: internal/inbox/pipeline.go:319-322

In `advanceWatermark`, the block `if ts < lastTS { ts = lastTS }` has a count of 0 across all suites, and so does its error-log branch. Removing the clamp would let a clock step backwards (NTP correction, VM resume) rewind `inbox_last_processed_ts` and re-detect an already-processed window. Dedup would mostly absorb that, but the code comment promises the invariant and no test backs it. Suggested fix: a two-line unit test that calls `advanceWatermark(ts=older, lastTS=newer)` and asserts the stored value.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
