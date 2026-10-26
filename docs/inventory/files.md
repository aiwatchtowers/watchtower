# Behavior Inventory — Files outside the database

> Each item below is a **behavioral contract** that must be preserved.
> Modifying or weakening the protecting test requires explicit approval
> from @Vadym.
>
> AI assistant: when adding a log line, an error that wraps a CLI's stderr
> or an HTTP body, or any file Watchtower writes outside its database, read
> this file first. Any proposed change that would break a guard test or
> remove a contract must be raised as a question before touching code.

**Module:** `internal/logredact/`, `internal/logcanary/`, `internal/fsutil/prompt_pipe.go`, `internal/fsutil/private_temp.go`, the `files01_test.go` files listed below
**Last full audit:** 2026-10-25

## FILES-01 — logs carry no synced names or text

**Status:** Enforced

**Observable:** `watchtower.log`, `daemon.log` and `sessions.log` name what they are about by id (`channel=<acct>:<id>`, `user=<acct>:<id>`, `event=<id>`, target and track ids), with counts, durations, phase and error class. They never carry a channel, person or meeting name, message or mail text, AI output or a prompt. AI output that fails to parse is logged as a fingerprint: byte count, shape and sha256. A CLI's stderr or result envelope and an HTTP error body ride a two-view error (`logredact.Errorf` with `logredact.Text` arguments): `Error()` — what every log line, `%v`, wrapper and progress line sees — shows that text only as a fingerprint, and `logredact.Full(err)` gives the whole text only where the owner reads an error (`pipeline_runs.error`, account status text, history backfill `last_error`, chat error events, `--progress-json` errors, the CLI's final stderr outside the detached daemon) and to the classifiers that match a provider's words.

**Test guards:**
- Guard: `internal/sync/files01_test.go::TestFILES01_SyncNeverLogsNames`, `internal/meeting/files01_test.go::TestFILES01_MeetingNeverLogsTitles`, `internal/digest/files01_test.go::TestFILES01_DigestNeverLogsContent`, `internal/digest/generator_files01_test.go::TestFILES01_GeneratorStderr`, `TestFILES01_TransportFailureSeesFullText`, `internal/tracks/files01_test.go::TestFILES01_TracksNeverLogsContent`, `internal/targets/files01_test.go::TestFILES01_TargetsNeverLogsContent`, `internal/briefing/files01_test.go::TestFILES01_BriefingNeverLogsContent`, `internal/guide/files01_test.go::TestFILES01_PeopleNeverLogsContent`, `internal/ai/files01_test.go::TestFILES01_ClaudeStderrStaysOnTheError`, `internal/codex/files01_test.go::TestFILES01_CodexStderrStaysOnTheError`, `internal/jira/files01_test.go::TestFILES01_JiraBodyStaysOnTheError`, `internal/ollama/files01_test.go::TestFILES01_OllamaBodyStaysOnTheError`
- Supporting: `internal/logredact/` and `internal/logcanary/` unit tests (the canary harness puts a canary in every synced field and fails when one reaches the log writer)

**Why locked:** Log files are plain text outside the database: once the database is encrypted (#603), they would be the readable copy of the company's correspondence, and support asks people to send them. A name or a sentence in one log line is enough to leak. Ids and fingerprints keep the logs useful for debugging without that.

**Locked since:** 2026-10-25

## FILES-02 — the sealed-file format and its key

**Status:** Planned (Stage B of `docs/superpowers/specs/2026-10-25-files-outside-db-design.md`)

**Observable:** Files that must stay files (recordings, chat attachments) are sealed with a key derived from the database key; the format and the key derivation are fixed once shipped. Not implemented yet: no guard test exists.

## Changelog

- 2026-10-25: file created with FILES-01 (Enforced) and FILES-02 (Planned), introduced by board #604 Stage A (owner approval in asks #571 and #577).
