# Company Content Outside the Database, Stage A — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the company content that sits outside `watchtower.db` only by accident: content in logs, prompt temp files, the Claude CLI's session store, Swift → CLI temp files, UI caches and sidecars. None of it needs the database key (#603 Stage 2).

**Architecture:** Each item is handled one of two ways. Either Watchtower **stops writing it**: logs carry ids and counts, prompts travel over an inherited pipe or stdin, and every Claude call passes `--no-session-persistence` and replays chat history from the database. Or the item **moves into `watchtower.db`**: the automation draft cache, the recording sidecars, the queued embedded-chat draft, and the slice-asset keys, which move into `hubstate.db`. A canary guard test (FILES-01) keeps synced text out of the log writer. The sealed-file primitive, the memory vault move and the one-time step for existing files are Stages B and C, not this plan.

**Tech Stack:** Go 1.26 (cobra, goose, SQLCipher `database/sql`), SwiftUI + GRDB (WatchtowerCore / WatchtowerDesktop), the `claude` and `codex` CLIs.

**Spec:** `docs/superpowers/specs/2026-10-25-files-outside-db-design.md` (approved 2026-10-25, ask #571, recommended answers Q1–Q4; contract changes: chat drops `--resume`, new FILES-01; MEM-02's inversion and FILES-02 belong to Stage B). Stage A = the spec's §4 row **A**, plus the §2 decisions it names.

## Global Constraints

- The log rule (spec §2 G3): log lines carry ids, counts, durations, phase and error class. They never carry names or text. Names become ids (`channel=<acct>:<id>`, `user=<acct>:<id>`, `event=<id>`). A parse error logs `claude.DescribeOutput` (byte count + shape + sha256). CLI stderr and HTTP bodies stay whole only in `logredact.Full(err)` where the owner reads an error; `Error()`, and so every log line, shows them as a fingerprint (bytes, shape, sha256) — see the spec §2 G3 row (amended in the tasks 1–5 review).
- Nothing new on argv (CHAT-04 stands): prompts go over an inherited pipe or stdin. A 0600 file is the fallback only, and only where Step 0 of Task 6 shows that a CLI refuses a pipe.
- Every `claude -p` Watchtower spawns passes `--no-session-persistence` and never `--resume`. Codex keeps `--ephemeral`.
- A chat whose provider process is new replays its history from the database (`chat.ReplayFromDB` in Go, `EmbeddedChatReplay` in Swift). The first respawned turn costs one replay; that cost is accepted (spec §2 G11).
- New tables written only by Swift (`pending_transcripts`, `chat_queued_drafts`) get their schema from a Go goose migration. Go never reads or writes them, as with `chat_artifact_comments`.
- CHAT-01 holds: an owner message queued but not yet sent survives a quit (it now lives in the database).
- Workchat attachments and target images stay plaintext (Q3 (a): the agent reads them by path), at mode 0600.
- Public repo: tests use canary strings and neutral samples (`acme`, `example.com`). No real ids.
- Inner loop only per task: `go test ./internal/<pkg>` (`-run` to narrow) and `make lint-diff`. Swift tasks also run `make test-swift FILTER=…` and `make lint-swift`, because lint-diff is Go-only. **Swift tasks run one lane at a time.** The full gate runs once, in Task 19.

## Review Focus

1. **The CLI cannot read a pipe** (a claude/codex version that `stat`s the prompt path or reads it twice). Expected: the call still gets its system prompt through the 0600 fallback, which is deleted after the child's first stream event, and the turn does not silently run without a prompt. Task 6 has a test where a stub child reads the fd twice and still gets the prompt; it checks the prompt-file contract only.
2. **The chat child dies mid-conversation** (crash, OOM, Stop past the grace period). Expected: the next turn goes to a fresh child carrying the replayed history, never to a blank session. Before this change `--resume` covered that case. Task 8 tests it.
3. **A recording starts while the database is unavailable** (it is still opening, or the write fails). Expected: recording goes on, the failure is logged, and the recording is listed as recovered at the next launch from the audio file alone. The audio is never dropped. Task 14 tests it.
4. **Legacy files from the previous version** (`automation-drafts/*.jsonl`, `rec_*.meta|txt|json`, `embeddedChat.queuedDraft.*`, `.desc`). Expected: each is imported once and then deleted, so no pending retry, draft or asset is lost by the upgrade. Each owning task has an import test.
5. **A synced name or text reaches the log through a wrapped error** (`fmt.Errorf("…%s…", title)` logged by a caller). Expected: the FILES-01 canary fails. Tasks 2–4 seed canaries into the fields that get wrapped and assert on the whole log stream, not just on the call sites that were changed.

---

### Task 1: Log redaction helpers and the canary harness

**Depends on:** none

**Files:**
- Create: `internal/logredact/logredact.go`, `internal/logredact/logredact_test.go`
- Create: `internal/logcanary/logcanary.go` (helper for tests in other packages; imports `testing`, never imported by non-test code)

**Interfaces:**
- Produces: `func logredact.Excerpt(s string) string`: replaces every `"…"`, `'…'` and `` `…` `` run with `"…"`, collapses whitespace, and cuts to 120 runes (adding `…` when cut). `const logredact.ExcerptRunes = 120`.
- Produces: `func logredact.Body(b []byte) string` = `claude.DescribeOutput(b)` (re-exported, so callers need no `internal/claude` import).
- Produces: `func logcanary.Text(field string) string` returns `"zqcanary-" + field + "-7f3a"`; `const logcanary.Marker = "zqcanary-"`.
- Produces: `func logcanary.Capture(t *testing.T) *Sink` routes the std `log` package output into the sink for the test and restores it in `t.Cleanup`. `func (s *Sink) Logger() *log.Logger` writes into the same sink. `func (s *Sink) AssertClean(t *testing.T)` fails and names every line that contains `Marker`.

- [ ] **Step 1: Failing tests** in `internal/logredact/logredact_test.go`. `TestExcerpt_ScrubsQuotedText`: `Excerpt(`error: channel "secret-plan" not found`)` == `error: channel "…" not found`. `TestExcerpt_Caps`: a 500-rune input → 120 runes plus `…`. `TestExcerpt_KeepsShortPlain`: `"HTTP 429"` unchanged.
- [ ] **Step 2: Run** `go test ./internal/logredact` → FAIL (undefined).
- [ ] **Step 3: Implement** both packages. For `logcanary`, add a self-test `TestSink_AssertCleanFlagsMarker` in `internal/logcanary/logcanary_test.go`, which uses a fake `testing.TB` recorder to check that a line with `logcanary.Text("x")` is reported.
- [ ] **Step 4: Run** `go test ./internal/logredact ./internal/logcanary` → PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `feat(log): redaction helpers and the FILES-01 canary harness`.

### Task 2: Slack sync and meeting logs carry ids, not names

**Depends on:** Task 1

**Files:**
- Modify: `internal/sync/orchestrator.go` (≈873, 923: users and channels), every other `Printf` in `internal/sync/` that prints `Name`, `RealName`, a channel name or message text
- Modify: `internal/meeting/pipeline.go` (≈173, 259: titles)
- Test: `internal/sync/files01_test.go`, `internal/meeting/files01_test.go`

**Interfaces:**
- Consumes: `logcanary.Capture`, `logcanary.Text` (Task 1).

- [ ] **Step 1: Failing guard tests.** `TestFILES01_SyncNeverLogsNames` runs the orchestrator's metadata and message phases against the package's existing fake Slack client. The fake has users named `logcanary.Text("user.name")` and `logcanary.Text("user.real_name")`, channels named `logcanary.Text("channel.name")`, and message text `logcanary.Text("message.text")`. The test then calls `sink.AssertClean(t)`. `TestFILES01_MeetingNeverLogsTitles` does the same for the meeting pipeline: an event titled `logcanary.Text("event.title")` and transcript text `logcanary.Text("transcript")`, then a fake generator that returns unparseable output containing `logcanary.Text("llm.output")`.
- [ ] **Step 2: Run** `go test ./internal/sync ./internal/meeting -run FILES01` → FAIL with the leaking lines listed.
- [ ] **Step 3: Rewrite the lines.** User lines become `user %d/%d: %s:%s%s` (account id and user id). Channel lines become `channel %d/%d: %s:%s [%s] %d members`. Meeting lines name `event=<id>`. Raw output goes through `logredact.Body`. Also sweep with `grep -n 'Printf.*\(Name\|Title\|Text\|Subject\)' internal/sync internal/meeting`.
- [ ] **Step 4: Run** `go test ./internal/sync ./internal/meeting` → PASS (existing log-text assertions updated to the id form); `make lint-diff`.
- [ ] **Step 5: Commit** `fix(log): Slack sync and meeting logs name ids, not people or titles (FILES-01)`.

### Task 3: Pipeline logs drop AI and source text

**Depends on:** Task 1

**Files:**
- Modify: `internal/tracks/pipeline.go` (≈921, 1029), `internal/targets/extractor.go` (≈260, 314), the parse-error logs in `internal/digest/`, `internal/briefing/` and the guide pipeline (find them with `grep -rn 'Printf.*\(%s\|%q\).*\(output\|raw\|resp\|text\)' internal/{digest,tracks,targets,briefing,guide}`)
- Test: `internal/{digest,tracks,targets,briefing}/files01_test.go` (and `internal/guide/` if that package logs)

**Interfaces:**
- Consumes: `logredact.Body`, `logcanary` (Task 1).

- [ ] **Step 1: Failing guard tests.** In each package, `TestFILES01_<Pkg>NeverLogsContent` seeds the package's existing test DB fixture with `logcanary.Text("<table>.<column>")` in every text column the pipeline reads (messages, track text, target text, digest topics). It uses the package's fake generator twice: once returning valid output that contains a canary, and once returning invalid output with a canary at its start. It runs the pipeline and calls `AssertClean`.
- [ ] **Step 2: Run** `go test ./internal/digest ./internal/tracks ./internal/targets ./internal/briefing -run FILES01` → FAIL.
- [ ] **Step 3: Rewrite.** Track and target lines name ids (`track=%d`, `target=%d`) and drop the 80-char text. Every raw-output echo becomes `logredact.Body(out)`. The content stays only where it is already stored (`pipeline_runs.error_msg` keeps today's `DescribeOutput` form, unchanged).
- [ ] **Step 4: Run** each package's `go test` → PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `fix(log): pipelines log ids and output fingerprints, never AI or source text (FILES-01)`.

### Task 4: CLI stderr and HTTP bodies stay on the stored error

**Depends on:** Task 1

**Files:**
- Modify: `internal/ai/client.go` (stderr and result-envelope logging), `internal/digest/generator.go` (≈293–320), `internal/codex/model_errors.go` (≈111), `internal/jira/client.go` (≈349, 453), `internal/ollama/client.go` (≈185, 285)
- Test: `internal/ai/files01_test.go`, `internal/jira/files01_test.go`, `internal/ollama/files01_test.go`, `internal/codex/files01_test.go`, `internal/digest/files01_test.go` (extend the Task 3 file only if Task 3 has merged; otherwise add `TestFILES01_GeneratorStderr` in a new `generator_files01_test.go`)

**Interfaces:**
- Consumes: `logredact.Excerpt`, `logcanary` (Task 1).
- Produces: no new API. The returned `error` still carries the full stderr or body (callers store it in `pipeline_runs.error`, account status text). Only the `log` line changes.

- [ ] **Step 1: Failing guard tests.** A stub `claude`/`codex` child (the packages' existing stub pattern, with the process group reaped in `t.Cleanup`) exits 1 with `logcanary.Text("stderr")` inside a quoted string in its stderr. An `httptest` server returns 500 with body `{"errorMessages":["` + `logcanary.Text("jira.body")` + `"]}` (Jira) or a canary body (Ollama). Each test asserts `AssertClean`, and asserts that the returned error **does** contain the canary (it is stored, not dropped).
- [ ] **Step 2: Run** `go test ./internal/ai ./internal/jira ./internal/ollama ./internal/codex ./internal/digest -run FILES01` → FAIL.
- [ ] **Step 3: Implement.** Every log line that printed a body or stderr prints `logredact.Excerpt(string(b))` instead. A whole body is never logged.
- [ ] **Step 4: Run** the five packages' `go test` → PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `fix(log): CLI stderr and HTTP bodies stay on the stored error, the log gets a scrubbed excerpt (FILES-01)`.

### Task 5: `daemon.log` holds only pre-logger lines; `sessions.log` rotates

**Depends on:** none

**Files:**
- Modify: `cmd/logfile.go` (`rotatingFile` gains an `onOpen func(*os.File)` hook, called after the first open and after each rotation), `cmd/sync.go` (the detached child, after `newSyncLogWriter`, calls `redirectStderr`)
- Create: `cmd/stderr_redirect_unix.go`: `func redirectStderr(f *os.File) error` = `unix.Dup2(int(f.Fd()), 2)`
- Modify: `internal/sessions/log.go`: rotate to `sessions.log.1` once the file is past `MaxLogSize = 20 << 20` before an append
- Test: `cmd/logfile_test.go`, `internal/sessions/log_test.go`

**Interfaces:**
- Produces: `func newRotatingFileWithHook(path string, maxSize int64, onOpen func(*os.File)) (*rotatingFile, error)`. `newSyncLogWriter` keeps its signature; the detached path passes the hook.

- [ ] **Step 1: Failing tests.** `TestRotatingFile_OnOpenFollowsRotation`: a 64-byte cap and a hook that records the file names it receives. After the writes cross the cap twice, the hook has seen the live `watchtower.log` three times (at open and after each of the two rotations), never `.1`. `TestSessionLog_Rotates`: set `MaxLogSize` to 100 for the test, write 30 events; `sessions.log.1` exists and `sessions.log` is under 100 bytes plus one line. Update `TestLogWriterFor`'s message: a detached child's stderr is now `watchtower.log`, not `daemon.log`.
- [ ] **Step 2: Run** `go test ./cmd -run 'RotatingFile|LogWriterFor' && go test ./internal/sessions` → FAIL.
- [ ] **Step 3: Implement.** The detached child's env must not set `GOTRACEBACK` (the default `single` prints the stack). Add an assertion on the child's env in the existing detach test.
- [ ] **Step 4: Run** the same commands → PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `fix(log): the daemon's stderr follows watchtower.log's rotation; sessions.log rotates at 20 MiB`.

### Task 6: System prompts and MCP configs over an inherited pipe

**Depends on:** none

**Files:**
- Create: `internal/fsutil/prompt_pipe.go`, `internal/fsutil/prompt_pipe_test.go`
- Modify: `internal/ai/client.go` (`buildArgs` ≈384–410, `writeMCPConfigTempFile`), `internal/digest/generator.go` (≈240), `internal/codex/instructions.go` (`promptArgs`), `internal/chat/claude_backend.go` (`Start` ≈328–336, `spawnLocked`: each spawn gets fresh pipes)
- Test: `internal/ai/client_test.go`, `internal/digest/generator_test.go`, `internal/codex/instructions_test.go`, `internal/chat/claude_backend_test.go` (`TestChat04_ClaudeArgvCarriesNoContent` keeps every assertion and adds: no file with a `wt-` prefix exists in `os.TempDir()` while the child runs)
- Extra packages to run: `./cmd` (`ai session`, `ai query` wiring)

**Interfaces:**
- Produces: `type fsutil.FDPayload struct{ Path string; File *os.File }`, where `Path` is `/dev/fd/N` in the child.
- Produces: `func fsutil.AttachPayloads(cmd *exec.Cmd, contents ...string) ([]FDPayload, func(), error)`. For each content it makes an `os.Pipe`, appends the read end to `cmd.ExtraFiles` (fd = 3 + index of the payload among the existing `ExtraFiles`), and starts a goroutine that writes the content and closes the write end. The cleanup closes the parent's ends and is called after `cmd.Start` and on any error. A content over the pipe buffer is fine, because the writer goroutine blocks until the child reads.
- Produces (only when Step 0 fails for a CLI): `func fsutil.WritePrivateTempOnce(pattern, content string) (path string, removeAfterRead func(), err error)`. The caller calls `removeAfterRead` at the child's first stdout line.

- [ ] **Step 0: Probe the pinned CLIs.** Run `claude -p --no-session-persistence --system-prompt-file /dev/fd/3 3< <(printf 'Reply with the single word PIPE-OK') <<< hi` and the codex twin `codex exec --ephemeral -c 'model_instructions_file="/dev/fd/3"' - 3< <(printf 'Reply with PIPE-OK') <<< hi`, on the versions the app pins (`claude --version`, `codex --version`). Also probe the warm chat path: `--input-format stream-json` with `--mcp-config /dev/fd/4`. Record the result in the task's commit message. If a CLI answers PIPE-OK, use the pipe for it. If it does not, that CLI uses `WritePrivateTempOnce` (spec §2 G7 fallback), and the plan's other steps are unchanged.
- [ ] **Step 1: Failing tests.** `TestAttachPayloads_ChildReadsEachFD`: run `/bin/sh -c 'cat /dev/fd/3; cat /dev/fd/4'` with two payloads, one of them 1 MiB (bigger than a pipe buffer); stdout equals both, in order, and no file was created in `t.TempDir()` (set as `TMPDIR`). `TestBuildArgs_PromptViaFD` (ai): the args contain `--system-prompt-file /dev/fd/3` and no path under `os.TempDir()`. Do the same for digest, codex (`model_instructions_file="/dev/fd/3"`) and the chat backend (prompt and MCP config, re-attached on every respawn: assert that a second spawn after a child exit still reads the prompt). Add `TestAttachPayloads_SecondReadFallback`, only if Step 0 needed the fallback: a stub that reads the path twice gets the content both times through the file, and the file is gone after the first stdout line.
- [ ] **Step 2: Run** `go test ./internal/fsutil ./internal/ai ./internal/digest ./internal/codex ./internal/chat` → FAIL.
- [ ] **Step 3: Implement.** `buildArgs` and `promptArgs` stop returning a temp path; they return the payloads that the caller attaches before `Start`. The `--mcp-config` secret path does the same. Inline JSON with no secret stays as it is today.
- [ ] **Step 4: Run** the same packages plus `go test ./cmd -run 'AISession|AIQuery'` → PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `feat(ai): system prompts and secret MCP configs reach the CLI over an inherited pipe (G7, G8)`.

### Task 7: Temp sweeps at every process start; extract spool sweep

**Depends on:** Task 6

**Files:**
- Modify: `internal/fsutil/private_temp.go`: `var StaleTempPrefixes = []string{"wt-system-prompt-", "wt-chat-prompt-", "wt-chat-mcp-", "wt-mcp-"}` (not `wt-chat-turn-` or `wt-mcp-status-`: they hold ids and live for a whole session); `func SweepStaleTemp(olderThan time.Duration, now time.Time) (int, error)` over all of them
- Modify: `cmd/root.go`: `PersistentPreRunE` starts `go sweepStaleTemp()` (best effort, never blocks a hook; errors are dropped silently except under `--verbose`); `internal/daemon/daemon.go` `sweepStaleSystemPrompts` → `SweepStaleTemp`, and it also sweeps `<ws>/tmp/extract` entries older than 10 min
- Test: `internal/fsutil/private_temp_test.go`, `internal/daemon/daemon_test.go`

**Interfaces:**
- Produces: `func fsutil.SweepStaleTemp(olderThan time.Duration, now time.Time) (int, error)`; `func fsutil.SweepStaleDir(dir string, olderThan time.Duration, now time.Time) (int, error)`.

- [ ] **Step 1: Failing tests.** `TestSweepStaleTemp_AllPrefixes`: with `TMPDIR` = `t.TempDir()`, create one 11-minute-old file per prefix, one fresh file, and an old `wt-chat-turn-x.txt`; only the four old prefixed files are removed. `TestDaemonStart_SweepsExtractSpool`: an old file in `<ws>/tmp/extract` is gone after startup and a fresh one remains.
- [ ] **Step 2: Run** `go test ./internal/fsutil ./internal/daemon -run 'Sweep'` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS; `go test ./cmd -run Root`; `make lint-diff`.
- [ ] **Step 5: Commit** `feat(fsutil): sweep every wt-* prompt leftover at process start, and the extract spool at daemon start (G8, G9)`.

### Task 8: No Claude session store; the chat replays on every new child

**Depends on:** Task 6 (same `buildArgs` / `claudeArgs` lines)

**Files:**
- Modify: `internal/ai/client.go` (`buildArgs` always appends `--no-session-persistence` and drops the `--resume` branch; the `sessionID` parameter is ignored and documented as such), `cmd/ai.go` (`--session-id` → `MarkHidden`, no-op), `cmd/ai_session.go` (`--resume` → `MarkHidden`, no-op; `ResumeSessionID` no longer set)
- Modify: `internal/chat/claude_backend.go`: `claudeArgs` always has `--no-session-persistence`, never `--resume`; remove `resume`/`resumeLocked`/`rejectedResume` and the resume-rejected retry. Every spawn after the first, and a first spawn whose conversation has history before the turn, marks the session fresh, so `attemptTurn` prefixes the turn with `opts.Replay(turnID)`.
- Test: `internal/chat/claude_backend_test.go`, `internal/ai/client_test.go`
- Extra packages to run: `./cmd` (ai session/query), `./internal/codex` (untouched; confirm `--ephemeral` stays)

**Interfaces:**
- Produces: `chat.ClaudeOptions.ResumeSessionID` is removed. `chat.ClaudeOptions.Replay` is now required when the conversation has history (`Start` returns an error if it is nil and history exists).

- [ ] **Step 1: Failing tests.** Replace `TestChat04_ClaudeArgsOnResume` with `TestChat04_ClaudeArgsNeverResume`. This guard change is approved (ask #571, spec "Contracts that change"); its "nothing on argv" assertions stay. The new test asserts that on every spawn, including after a child exit, the args contain `--no-session-persistence` and no `--resume`. `TestClaudeBackend_RespawnReplays`: the stub child answers turn 1 and then exits; turn 2's first stdin user line starts with the replay header (`replayHeader` in `internal/chat/replay.go`) and contains turn 1's text. `TestClient_NoSessionPersistence` (ai): `buildArgs` with `sessionID="abc"` contains `--no-session-persistence` and not `abc`.
- [ ] **Step 2: Run** `go test ./internal/chat ./internal/ai` → FAIL.
- [ ] **Step 3: Implement.** Delete the tests that pin resume-only behaviour (resume rejection, `--resume` respawn), each named in the commit message. `TestChat03_*` stay unchanged.
- [ ] **Step 4: Run** `go test ./internal/chat ./internal/ai ./internal/codex ./cmd -run 'AI|Chat'` → PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `feat(chat): no Claude session store; a new chat child replays from the database (G11, CHAT-04 amended)`.

### Task 9: CLI reads Desktop text from stdin

**Depends on:** none

**Files:**
- Modify: `cmd/text_file_flag.go` (`textFlagValue`: `--text-file -` reads `cmd.InOrStdin()`; the signature gains `in io.Reader`), and its callers in `cmd/tracks.go`, `cmd/targets.go`, `cmd/meeting.go`
- Modify: `cmd/meeting_transcript.go`: `transcript save --stdin` reads one JSON object `{"transcript": string, "segments": [...]|null, "speakers": [...]|null}`, validated exactly as the `--*-file` flags are today; `--stdin` is mutually exclusive with `--transcript-file`
- Modify: `cmd/dictate.go`: `--transcript-file -` reads stdin
- Modify: `cmd/automations_edit.go`: `validate -` reads stdin and takes `--slug` (required with `-`, in place of `recipeSlugOf(path)`); `save --file -` reads stdin. Add `automations.ReadRecipe(r io.Reader) (data []byte, contentHash string, err error)` beside `ReadRecipeFile`, with the same size cap
- Test: `cmd/text_file_flag_test.go`, `cmd/meeting_transcript_test.go`, `cmd/dictate_test.go`, `cmd/automations_edit_test.go`, `internal/automations/recipe_read_test.go`

**Interfaces:**
- Produces (the Swift side relies on these): `--text-file -`; `meeting-prep transcript save --stdin` with the JSON keys above; `dictate clean --transcript-file -`; `automations validate - --slug <slug> [--against N|--workbench N] --json`; `automations save --file - --path P …`.

- [ ] **Step 1: Failing tests.** `TestTextFlagValue_Stdin`. `TestTranscriptSave_Stdin`: the row has the same `segments_json` and `speakers_json` as the file-flag run of the same payload. `TestTranscriptSave_StdinAndFileRefused`. `TestDictateClean_StdinTranscript`. `TestAutomationsValidate_Stdin`: same JSON as the file run of the same text with `--slug` = the file's base name. `TestAutomationsValidate_StdinNeedsSlug`. `TestAutomationsSave_StdinFile`. `TestReadRecipe_SizeCap`.
- [ ] **Step 2: Run** `go test ./cmd -run 'TextFlagValue|TranscriptSave|DictateClean|AutomationsValidate|AutomationsSave' && go test ./internal/automations -run ReadRecipe` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `feat(cli): Desktop text and recipes over stdin (S6, S7)`.

### Task 10: Migration — draft cache, pending transcripts, queued drafts

**Depends on:** none

**Files:**
- Create: `internal/db/migrations/00154_files_outside_db.sql` (use the next free number when implementing; it was 00154 when this plan was written)
- Modify: `internal/db/schema.sql`, `internal/db/db_test.go` (`TestAllTablesExist`), golden + `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift` (regenerated)
- Create: `internal/db/automation_draft_cache.go`, `internal/db/automation_draft_cache_test.go`

**Interfaces:**
- Produces (schema, per the `add-migration` skill, no CHECK changes):
  - `automation_draft_cache(conversation_id INTEGER NOT NULL, seq INTEGER NOT NULL, entry_json TEXT NOT NULL, at TEXT NOT NULL, PRIMARY KEY (conversation_id, seq))`
  - `pending_transcripts(recording TEXT PRIMARY KEY, event_id TEXT, title TEXT, transcript TEXT, meta_json TEXT, started_at REAL NOT NULL, transcribed_at REAL)`: `recording` is the audio file's base name (`rec_<ts>.caf`); `transcript`/`meta_json` are NULL until transcription succeeds; a row present = not saved yet (it replaces "sidecar present"). Swift-only writer.
  - `chat_queued_drafts(surface_key TEXT PRIMARY KEY, text TEXT NOT NULL, at REAL NOT NULL)`: `surface_key` = `EmbeddedChatKey.description`. Swift-only writer.
- Produces: `func (db *DB) AppendDraftCache(conversationID int64, entryJSON string, at time.Time, keep int) error`, one transaction that inserts `seq = max+1` and deletes all but the newest `keep`. `func (db *DB) DraftCache(conversationID int64) ([]string, error)` returns entries oldest first. `func (db *DB) DeleteDraftCache(conversationID int64) error`.

- [ ] **Step 1: Failing tests.** `TestAppendDraftCache_KeepsNewestFive` (seven appends with keep 5 → five entries, the last two appends at the end), `TestDeleteDraftCache`, plus the three table names in `TestAllTablesExist`.
- [ ] **Step 2: Run** `go test ./internal/db -run 'DraftCache|AllTablesExist'` → FAIL.
- [ ] **Step 3: Implement** the migration (with a real Down: drop the three tables), `schema.sql` comments naming the Swift-only writers, and the helpers.
- [ ] **Step 4: Regenerate** `go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`, then `go test ./internal/db -run 'TestMigrationIdempotent|TestAllTablesExist|TestSchemaGolden|TestDesktopTestSchema|DraftCache'` → PASS.
- [ ] **Step 5: Commit** `feat(db): draft cache, pending transcripts and queued drafts tables (migration 00154)`.

### Task 11: The automation draft cache writes the database

**Depends on:** Task 10

**Files:**
- Modify: `internal/automations/authoring/draftcache.go`: `cacheDraft` → `d.DB.AppendDraftCache(…, draftCacheKeep)`; `appendDraftCache`, the file path and `DraftCachePath` are removed; `DraftCacheDir` stays only for the import
- Create: `internal/automations/authoring/draftcache_import.go`: `func ImportLegacyDraftCache(d *db.DB, workspaceDir string) (int, error)` reads each `automation-drafts/<id>.jsonl`, appends its lines in order, removes the file, and removes the directory once it is empty. A file that does not parse is kept and logged by name only.
- Modify: `internal/daemon/daemon.go`: call it once at startup, best effort
- Test: `internal/automations/authoring/draftcache_test.go`, `draftcache_import_test.go`

**Interfaces:**
- Consumes: `AppendDraftCache`, `DraftCache` (Task 10). The `DraftCacheEntry` JSON keys are unchanged (the Desktop decodes them in Task 12).

- [ ] **Step 1: Failing tests.** `TestCacheDraft_WritesRows`: after a draft on the `automation_editor` surface, `DraftCache(conv)` has one entry whose `recipe_text` matches, and no `automation-drafts` directory exists. `TestImportLegacyDraftCache`: two files are imported in order and removed; an unparseable file stays.
- [ ] **Step 2: Run** `go test ./internal/automations/authoring` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `go test ./internal/automations/authoring ./internal/daemon` → PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `feat(automations): the editor's draft cache lives in the database (G2)`.

### Task 12 (Swift): The Draft panel reads the database

**Depends on:** Task 11

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Automations/AutomationDraftPanelModel.swift` (reads `automation_draft_cache` through GRDB in place of the jsonl; same decode of `DraftCacheEntry`), `AutomationEditorCenter.swift` (`draftCacheDir` → a `DatabasePool` reader), `AutomationsViewModel.swift` (`removeDraftCache` → `DELETE FROM automation_draft_cache WHERE conversation_id = ?` through the Desktop writer)
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/AutomationDraftCacheQueries.swift`
- Test: `WatchtowerDesktop/Tests/Core/AutomationDraftPanelModelTests.swift` (existing tests move from files to rows)

**Interfaces:**
- Produces: `enum AutomationDraftCacheQueries { static func entries(_ db: Database, conversationID: Int64) throws -> [String]; static func delete(_ db: Database, conversationID: Int64) throws }`.

- [ ] **Step 1: Failing tests.** `testPanelShowsNewestRowEntry` and `testDiscardDeletesRows` against `TestDatabase`.
- [ ] **Step 2: Run** `make test-swift FILTER='AutomationDraftPanelModelTests|AutomationsViewModelTests'` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the same filter → PASS; `make lint-swift`.
- [ ] **Step 5: Commit** `feat(desktop): the automation Draft panel reads the database (G2)`.

### Task 13 (Swift): Text to the CLI over stdin; `CLITextFile` removed; launch temp sweep

**Depends on:** Task 9

**Files:**
- Modify: `WatchtowerCore/Services/MeetingRecapService.swift`, `MeetingTopicsExtractService.swift`, `TrackComposeService.swift`, `Services/TargetExtractService.swift`, `Automations/AutomationsCLI.swift` (`trackInstruction`, `validate`, `save`): `runner.run(args: […, "--text-file", "-"], stdin: Data(text.utf8))`
- Modify: `TranscriptSaveService.swift`: one `--stdin` JSON payload with the keys from Task 9 (segments and speakers encoded with the existing `TranscriptSegments`/`SpeakerEmbeddings` encoders)
- Modify: `DictationCleanService.swift`: `--transcript-file -`
- Modify: `AutomationEditorCenter.swift`: `withTempRecipe` is removed; `validate`/`save` take the text and the slug
- Delete: `WatchtowerCore/Services/CLITextFile.swift`
- Create: `WatchtowerCore/Services/StaleTempSweep.swift`: `enum StaleTempSweep { static let prefixes = ["watchtower-text-", "watchtower-transcript-", "watchtower-segments-", "watchtower-speakers-", "dictation-", "watchtower-automation-"]; static func run(in dir: URL, olderThan: TimeInterval = 600, now: Date) -> Int }`, called once from app launch (`AppState` init path, off the main actor)
- Test: `Tests/Core/CLIStdinArgsTests.swift`, `Tests/Core/StaleTempSweepTests.swift`, existing `TranscriptSaveServiceTests`, `DictationCleanServiceTests`

**Interfaces:**
- Consumes: Task 9's flags. `CLIRunnerProtocol.run(args:stdin:)` already exists.

- [ ] **Step 1: Failing tests.** With a recording runner, each service passes `-` and sends the text on stdin, and no file with any of the prefixes appears in the temp directory. `TranscriptSaveService` sends JSON whose `segments` decode back to the input. `StaleTempSweepTests`: old prefixed files and directories are removed; fresh ones stay.
- [ ] **Step 2: Run** `make test-swift FILTER='CLIStdinArgsTests|StaleTempSweepTests|TranscriptSaveServiceTests|DictationCleanServiceTests|AutomationEditorCenterTests'` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the same filter → PASS; `make lint-swift`.
- [ ] **Step 5: Commit** `feat(desktop): text and recipes reach the CLI over stdin; no temp files (S6, S7)`.

### Task 14 (Swift): Recording sidecars become a `pending_transcripts` row

**Depends on:** Task 10, Task 13

**Files:**
- Create: `WatchtowerCore/Database/Queries/PendingTranscriptQueries.swift`, `WatchtowerCore/Services/PendingTranscriptStore.swift` (protocol + GRDB implementation over the Desktop writer)
- Modify: `Services/MeetingRecorderCenter.swift`: `writeMetaSidecar`/`removeMetaSidecar`/`persistTranscript`/`loadPersistedTranscript`/`removePersistedTranscript` and the recovery listing (≈1642–1800) go through `PendingTranscriptStore`; `restorePendingOnLaunch` lists recoverable recordings from the rows, plus any audio file without a row that is younger than the orphan sweep (Review Focus 3); the init gains `pendingStore: @escaping () -> PendingTranscriptStore?` (nil until the database opens)
- Create: `WatchtowerCore/Services/LegacyRecordingSidecarImport.swift`: `static func importAll(in dir: URL, into store: PendingTranscriptStore) -> Int`. For each `rec_*.meta` / `.txt` / `.json`, it upserts the row and removes the files; an unreadable sidecar is kept and logged by file name. It runs once, at the first `restorePendingOnLaunch` after the database opens.
- Test: `Tests/MeetingRecorderCenterTests.swift` (sidecar tests rewritten to rows), `Tests/Core/LegacyRecordingSidecarImportTests.swift`, `Tests/Core/PendingTranscriptQueriesTests.swift`

**Interfaces:**
- Produces: `protocol PendingTranscriptStore { func begin(recording: String, eventID: String?, title: String?, at: Date) throws; func saveTranscript(recording: String, text: String, metaJSON: String, at: Date) throws; func pending() throws -> [PendingTranscript]; func remove(recording: String) throws }`; `struct PendingTranscript { recording, eventID, title, transcript, metaJSON, startedAt, transcribedAt }`. `metaJSON` is the existing `PersistedTranscriptMeta` encoding.

- [ ] **Step 1: Failing tests.** `testStartWritesRowNotMetaFile`: after start, no `.meta` file exists and a row has the title. `testTranscriptRowIsTheRetrySource`: a failed save, then a retry that saves from the row without calling the engine factory. `testSuccessfulSaveRemovesRow`. `testStartWithoutDatabaseStillRecords`: `pendingStore` returns nil; recording starts, the failure is logged, and after relaunch with a store the audio is listed as recovered. `LegacyRecordingSidecarImportTests`: `.meta` + `.txt` + `.json` → one row with all fields, files gone; a corrupt `.json` keeps its files.
- [ ] **Step 2: Run** `make test-swift FILTER='MeetingRecorderCenterTests|LegacyRecordingSidecarImportTests|PendingTranscriptQueriesTests'` → FAIL.
- [ ] **Step 3: Implement.** No `.txt`, `.json` or `.meta` file is written anywhere (check with `grep -n 'appendingPathExtension("meta")\|"txt"\|"json"' Services/MeetingRecorderCenter.swift`).
- [ ] **Step 4: Run** the same filter → PASS; `make lint-swift`.
- [ ] **Step 5: Commit** `feat(desktop): recording retry state and titles live in the database, not sidecars (S3, S4)`.

### Task 15 (Swift): The queued embedded-chat draft lives in the database

**Depends on:** Task 10

**Files:**
- Modify: `Services/EmbeddedChatWiring.swift`: `UserDefaultsDraftMirror` → `DatabaseDraftMirror(pool: PoolBox)`. It keeps an in-memory map (synchronous `restore`, plus anything queued before the database opens) and writes through to `chat_queued_drafts` once the pool is set. When the pool is set it imports every `embeddedChat.queuedDraft.*` default into the table and removes the key.
- Create: `WatchtowerCore/Database/Queries/QueuedDraftQueries.swift`
- Test: `Tests/EmbeddedDraftMirrorTests.swift`, `Tests/Core/QueuedDraftQueriesTests.swift`

**Interfaces:**
- Consumes: `EmbeddedDraftMirror` (unchanged protocol).
- Produces: `enum QueuedDraftQueries { static func save(_ db: Database, key: String, text: String, at: Date) throws; static func clear(_ db: Database, key: String) throws; static func text(_ db: Database, key: String) throws -> String? }`.

- [ ] **Step 1: Failing tests.** `testQueuedDraftSurvivesRelaunch` (a fresh mirror over the same pool restores the text; CHAT-01). `testQueuedBeforePoolIsFlushed`. `testLegacyDefaultsImportedAndRemoved`. `testClearRemovesRow`.
- [ ] **Step 2: Run** `make test-swift FILTER='EmbeddedDraftMirrorTests|QueuedDraftQueriesTests'` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS, plus `make test-swift FILTER=EmbeddedChatEngine` (CHAT-01 behaviour unchanged); `make lint-swift`.
- [ ] **Step 5: Commit** `feat(desktop): the queued chat draft lives in the database (S15, CHAT-01 kept)`.

### Task 16 (Swift): Chats stop resuming Claude sessions

**Depends on:** Task 8

**Files:**
- Modify: `Services/Chat/ChatSessionClient.swift` (no `--resume`; `resumeSessionID` removed from `ChatSessionConfig`), `Services/Chat/ChatSessionPool.swift`, `ViewModels/ChatViewModel.swift` (`sessionConfig` passes no resume; `adoptInitialContinuity` gets nil, so a new session replays whenever there is history)
- Modify: `WatchtowerCore/Services/Chat/ChatCommand.swift` (`ChatContinuity.initialLeaf` removed; its callers use nil)
- Modify: `WatchtowerCore/Services/Chat/Embedded/ChatSurfaceSpec.swift` (`resumesSession` → always `false`, then remove the property and its branches in `EmbeddedChatEngine.swift`; the engine no longer saves or loads the session id)
- Modify: `WatchtowerCore/Services/WatchtowerAIService.swift` (`buildArgs` drops `--session-id`)
- Test: `Tests/ChatSessionClientTests.swift` (`testChat04SessionArgvNeverCarriesContent` adds: no `--resume`), `Tests/ChatViewModelTests.swift` (`testChat01PartialTextSurvivesProcessDeathAndTheNextTurnResumes` now asserts that the next turn carries a replay; this guard change is approved in ask #571), `Tests/Core/EmbeddedChatEngineTests.swift` (Claude turns carry `EmbeddedChatReplay.block`), `Tests/Core/WatchtowerAIServiceTests.swift`

- [ ] **Step 1: Failing tests** as listed.
- [ ] **Step 2: Run** `make test-swift FILTER='ChatSessionClientTests|ChatViewModelTests|EmbeddedChatEngineTests|WatchtowerAIServiceTests'` → FAIL.
- [ ] **Step 3: Implement.** The `chat_conversations.session_id` column stays and is no longer read (no migration).
- [ ] **Step 4: Run** the same filter → PASS; `make lint-swift`.
- [ ] **Step 5: Commit** `feat(desktop): chats replay from the database instead of resuming a Claude session (G11)`.

### Task 17 (Swift): Workbench notification snapshot without content

**Depends on:** none

**Files:**
- Modify: `WatchtowerCore/Services/WorkbenchNotificationPolicy.swift`: `Snapshot.persisted` replaces every text field (`projectName`, `Question.targetTitle`/`body`, `TargetState` title, `OpenAsk` title/question, `PendingAction` summary) with `ContentDigest.of(text)` = `"sha256:" + hex(SHA256(text))`. `decide` compares text through `ContentDigest.same(_:_:)` (a digest equals the raw text it hashes), and notices take their text from `current` only.
- Modify: `Services/WorkbenchNotificationCenter.swift`: no change in storage (UserDefaults keeps the content-free form). A legacy snapshot is re-saved in the persisted form at the next poll, which already happens.
- Test: `Tests/Core/WorkbenchNotificationPolicyTests.swift`

**Interfaces:**
- Produces: `enum ContentDigest { static func of(_ text: String) -> String; static func same(_ a: String, _ b: String) -> Bool }`.

- [ ] **Step 1: Failing tests.** `testPersistedSnapshotHoldsNoText`: encode `persisted` and assert that no fixture title or body appears in the JSON. `testDecideFromPersistedEqualsDecideFromRaw`: for each existing fixture pair, `decide(previous: a.persisted, current: b) == decide(previous: a, current: b)`.
- [ ] **Step 2: Run** `make test-swift FILTER=WorkbenchNotificationPolicyTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `make test-swift FILTER='WorkbenchNotificationPolicyTests|WorkbenchNotificationCenterTests'` → PASS; `make lint-swift`.
- [ ] **Step 5: Commit** `fix(desktop): the workbench notification snapshot stores digests, not titles (S16)`.

### Task 18 (Swift): Slice-asset keys move into `hubstate.db`; workchat attachments 0600 and gone at session end

**Depends on:** none

**Files:**
- Modify: `Services/MobileHub/HubSyncState.swift` (`createSchema`: `CREATE TABLE IF NOT EXISTS slice_assets (file_path TEXT PRIMARY KEY, descriptor BLOB NOT NULL)`; `func descriptor(forFile:) throws -> Data?`, `setDescriptor(_:forFile:)`, `removeDescriptor(forFile:)`, `removeDescriptors(under:)`)
- Modify: `Services/MobileHub/SliceAssetStore.swift`: the init takes `descriptors: SliceAssetDescriptorStoring` (implemented by `HubSyncState`); `stage` removes the old row, writes the sealed file, then the row (same crash order as today); `stagedDescriptor` reads the row; no `.desc` is ever written; `sweep`/`removeAll`/`close` remove rows with their files; at init, any `*.desc` file is imported into a row and deleted. The type's doc comment about "K_asset next to the file" is updated.
- Modify: `Services/MobileHub/MobileHubService.swift:117` (pass the hub state)
- Modify: `WatchtowerCore/Services/WorkchatAttachmentStore.swift`: `save` writes with `.posixPermissions: 0o600`, folder `0o700`; `sweep(keepingSessions:)` loses `olderThan` (a non-live session's folder is removed whatever its age); `ViewModels/WorkbenchesViewModel.swift` `onSessionExit` calls the sweep for that session; the launch call stays
- Test: `Tests/SliceAssetStoreTests.swift`, `Tests/HubSyncStateTests.swift`, `Tests/Core/WorkchatAttachmentStoreTests.swift`

**Interfaces:**
- Produces: `protocol SliceAssetDescriptorStoring: Sendable { func descriptor(forFile path: String) throws -> Data?; func setDescriptor(_ data: Data, forFile path: String) throws; func removeDescriptor(forFile path: String) throws; func removeDescriptors(under directory: String) throws }`.

- [ ] **Step 1: Failing tests.** `testStageWritesNoDescFile`. `testDescriptorSurvivesRestartFromRow`. `testLegacyDescImportedAndDeleted`. `testCrashBetweenFileAndRowReadsNotStaged`. `testCloseRemovesRows`. `testWorkchatFileIs0600`. `testSweepRemovesEndedSessionAtOnce`: a one-minute-old file of a session that is no longer live is removed.
- [ ] **Step 2: Run** `make test-swift FILTER='SliceAssetStoreTests|HubSyncStateTests|WorkchatAttachmentStoreTests'` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the same filter plus `SlicePublisherTests` → PASS; `make lint-swift`.
- [ ] **Step 5: Commit** `feat(mobile-hub): slice-asset keys live in hubstate.db; workchat attachments 0600 and removed at session end (S12, S9)`.

### Task 19: Inventory, feature notes, guide, CLAUDE.md, gate

**Depends on:** Tasks 1–18

**Files:**
- Create: `docs/inventory/files.md`: **FILES-01** (Enforced): logs carry no synced names or text, guarded by the `TestFILES01_*` tests in sync, meeting, digest, tracks, targets, briefing, ai, jira, ollama and codex. **FILES-02** (Planned, Stage B): the sealed-file format and key derivation.
- Modify: `docs/inventory/README.md` (Files row with the code paths: `internal/logredact/`, `internal/logcanary/`, `internal/fsutil/prompt_pipe.go`, the FILES-01 test files); `docs/inventory/chat.md`: a CHAT-04 entry for 2026-10-25, ask #571. Prompts travel over an inherited pipe and no CLI session store exists. `TestChat04_ClaudeArgsOnResume` is replaced by `TestChat04_ClaudeArgsNeverResume`, and the "nothing on argv" assertions are unchanged. Plus a CHAT-01 note that the queued draft is now in the database and `testChat01…NextTurnResumes` now asserts a replay.
- Create: `docs/features/files-outside-db.md`: Stage A as shipped (the log rule, the pipe handoff and its fallback, the sweep prefixes, `--no-session-persistence`, the three tables and their writers, the legacy imports, FILES-01), with Stages B and C pointing at the spec.
- Modify: `docs/features/chat-redesign.md` (no `--resume`, replay on every new child), `docs/features/meeting-transcriber.md` (`pending_transcripts` replaces sidecars), `docs/features/mobile-companion.md` (`slice_assets` in `hubstate.db`), `docs/features/automations.md` (draft cache in the database)
- Modify: `CLAUDE.md`: one Feature Notes line for `files-outside-db.md` in the house style
- Modify: `docs/guide/concepts/privacy.md`: a section "What Watchtower keeps outside its database", following `docs/guide/WRITING.md`. It covers logs without content, no AI session files, recordings and attachments still as files until encryption ships, and workbench pastes deleted when the session ends. The page stays under 8 KB.

- [ ] **Step 1: Write the docs.**
- [ ] **Step 2: Run** `go test ./docs/guide/ ./internal/kb/ ./internal/chat/`. If a guide heading changed, regenerate with `go test ./internal/chat -run TestBuildSystemPrompt_Golden -update`.
- [ ] **Step 3: Full gate:** `bash scripts/dev-health.sh`, then `make test`, `make test-swift`, `make lint-all` → all pass.
- [ ] **Step 4: Commit** `docs: #604 stage A — FILES-01, feature note, guide`.

## Not in this plan (spec §4 Stages B and C)

The sealed-file primitive and FILES-02. Sealing recordings (S1, S2) and chat attachments (S8). Keying `hubstate.db` (S11). The memory vault in the database (G1, S10; MEM-02 inverted, MEM-03 over `memory_commits`). Tokens and credentials into the encrypted database (Q4). Deleting target images at archive (G10). The one-time step §3, which also deletes the pre-redaction `watchtower.log*`/`daemon.log*` copies. The transfer changes (§5).
