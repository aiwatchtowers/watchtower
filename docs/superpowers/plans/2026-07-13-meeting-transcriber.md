# Meeting Transcriber Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Record a meeting from the Desktop calendar (mic + system audio, no BlackHole/ffmpeg), transcribe it locally with WhisperKit using snoop's windowed ru/uk/en language detection, store the transcript in SQLite, and generate the recap through the existing Meeting Recap pipeline.

**Architecture:** Swift owns capture + transcription (`MeetingRecorderCenter` on AppState, `TranscriptionEngine` protocol over WhisperKit, CoreAudio process tap for system audio). Go owns storage + AI + retention (`meeting_transcripts` table, `meeting-prep transcript` CLI subcommands reusing `Pipeline` recap machinery, daemon audio-cleanup phase, MCP tools).

**Tech Stack:** Go 1.25 (cobra, goose migrations, `modernc.org/sqlite`), Swift 5.10 / macOS 14+ (SwiftUI, GRDB 7, WhisperKit via SPM, AVAudioEngine + CoreAudio process taps).

**Spec:** `docs/superpowers/specs/2026-07-13-meeting-transcriber-design.md`

**Deliberate deviations from spec (approved rationale):**
- `save` does NOT stream `--progress-json`: the command is one insert + one AI call; there is nothing step-shaped to stream. The Swift Center models the `summarizing` phase itself (same as the existing `MeetingRecapService` flow).
- Command lives under the existing `meeting-prep` root: `watchtower meeting-prep transcript save|recap|list|show` (spec wrote `watchtower meeting transcript …`; the repo's command family root is `meeting-prep`).

## Global Constraints

- Go stays pure-Go: no cgo, no new Go dependencies.
- Swift: only new dependency is WhisperKit (SPM). No brew/Python/ffmpeg/BlackHole anywhere.
- System-audio capture gated on **macOS 14.4+** at runtime; app deployment target stays `.macOS(.v14)`.
- Windowed language detection defaults (from snoop, verbatim): window 20 s, overlap 1.0 s, langset `ru,uk,en`, confidence threshold 0.6, margin 0.2, first-window default `ru`.
- Audio retention default: `transcripts.audio_retention_days = 30`.
- AI stdin threshold: 32 KB (32 * 1024 bytes) of user message.
- Transcript rows must survive calendar event deletion (`ON DELETE SET NULL`), and audio files must survive every downstream failure.
- All Go schema changes via goose migration + mirror into `internal/db/schema.sql` + `TestAllTablesExist` + golden snapshot (`go test ./internal/db/ -run TestSchemaGolden -update`). Swift `Tests/Helpers/TestDatabase.swift` schema must be updated in the same task as the migration-consuming Swift code (known drift trap).
- Guard tests in `docs/inventory/` modules must not be touched. This feature adds new code paths only; do not modify existing recap behavior for the paste-text flow.
- Verification commands: `go test ./...`, `go vet ./...`, `go build ./...`; Swift: `cd WatchtowerDesktop && swift build 2>&1 | tail -5; echo "exit=$?"` style is FORBIDDEN — redirect to a log and check `$?` explicitly:
  `swift test > /tmp/swift-test.log 2>&1; echo "exit=$?"` then inspect the log.
- All commits on branch `feature/meeting-transcriber`. GitHub-facing text in English.

---

### Task 1: Go migration — `meeting_transcripts` table

**Files:**
- Create: `internal/db/migrations/00016_meeting_transcripts.sql`
- Modify: `internal/db/schema.sql` (append after the `meeting_recaps` block, ~line 1004)
- Modify: `internal/db/db_test.go` (`TestAllTablesExist`, line 92 — add table name)
- Regenerate: golden schema snapshot

**Interfaces:**
- Produces: table `meeting_transcripts` with columns `id, event_id, title, audio_path, duration_sec, lang_stats, transcript_text, summary_json, created_at, updated_at`; index `idx_meeting_transcripts_event`. All later Go/Swift tasks depend on these exact column names.

- [ ] **Step 1: Write the migration**

```sql
-- +goose Up
-- Meeting transcripts: locally-transcribed meeting audio (WhisperKit in the
-- Desktop app). One row per recording. event_id is NULL for ad-hoc recordings
-- and survives event deletion (SET NULL) — a transcript must outlive its
-- calendar event. audio_path is NULLed by the daemon retention phase once the
-- audio file is deleted; transcript_text is kept forever. summary_json holds
-- the recap for ad-hoc recordings only (event-linked recaps live in
-- meeting_recaps).
CREATE TABLE meeting_transcripts (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    event_id        TEXT REFERENCES calendar_events(id) ON DELETE SET NULL,
    title           TEXT NOT NULL,
    audio_path      TEXT,
    duration_sec    INTEGER NOT NULL DEFAULT 0,
    lang_stats      TEXT NOT NULL DEFAULT '',
    transcript_text TEXT NOT NULL,
    summary_json    TEXT,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
CREATE INDEX idx_meeting_transcripts_event ON meeting_transcripts(event_id);

-- +goose Down
DROP TABLE meeting_transcripts;
```

- [ ] **Step 2: Mirror into `internal/db/schema.sql`**

Append after the `meeting_recaps` CREATE TABLE block (use `CREATE TABLE IF NOT EXISTS` / `CREATE INDEX IF NOT EXISTS` to match the file's style, same comment header as the migration).

- [ ] **Step 3: Add `meeting_transcripts` to `TestAllTablesExist`** in `internal/db/db_test.go:92` (alphabetical/logical position next to `meeting_recaps`).

- [ ] **Step 4: Run db tests, regenerate golden**

Run: `go test ./internal/db/ -run 'TestAllTablesExist|TestSchemaGolden' -update > /tmp/db-test.log 2>&1; echo "exit=$?"`
Expected: exit=0 (first run of TestAllTablesExist without migration would fail — the migration makes it pass; `-update` refreshes the golden snapshot).
Then: `go test ./internal/db/ > /tmp/db-test2.log 2>&1; echo "exit=$?"` → exit=0.

- [ ] **Step 5: Commit**

```bash
git add internal/db/migrations/00016_meeting_transcripts.sql internal/db/schema.sql internal/db/db_test.go internal/db/testdata/
git commit -m "feat(db): add meeting_transcripts table (migration 00016)"
```

---

### Task 2: Go DB layer — `meeting_transcripts` queries

**Files:**
- Create: `internal/db/meeting_transcripts.go`
- Create: `internal/db/meeting_transcripts_test.go`

**Interfaces:**
- Consumes: table from Task 1.
- Produces (used by Tasks 5, 6, 7):

```go
type MeetingTranscript struct {
    ID             int64
    EventID        sql.NullString
    Title          string
    AudioPath      sql.NullString
    DurationSec    int
    LangStats      string
    TranscriptText string
    SummaryJSON    sql.NullString
    CreatedAt      string
    UpdatedAt      string
}
type MeetingTranscriptFilter struct {
    EventID  string // exact match; "" = no filter
    FromTime string // ISO8601 lower bound on created_at; "" = none
    ToTime   string // ISO8601 upper bound on created_at; "" = none
    Limit    int    // 0 = 50
}
func (db *DB) InsertMeetingTranscript(t MeetingTranscript) (int64, error)
func (db *DB) GetMeetingTranscript(id int64) (*MeetingTranscript, error) // (nil, nil) when missing
func (db *DB) ListMeetingTranscripts(f MeetingTranscriptFilter) ([]MeetingTranscript, error) // newest first
func (db *DB) SetMeetingTranscriptSummary(id int64, summaryJSON string) error // bumps updated_at
func (db *DB) ExpiredTranscriptAudio(cutoff string) ([]MeetingTranscript, error) // audio_path NOT NULL AND created_at < cutoff
func (db *DB) ClearMeetingTranscriptAudio(id int64) error // audio_path = NULL, bumps updated_at
```

- [ ] **Step 1: Write failing tests** in `internal/db/meeting_transcripts_test.go` — follow `meeting_recaps_test.go` style (open test DB via the package's existing test helper used there):

```go
func TestInsertAndGetMeetingTranscript(t *testing.T) {
    database := openTestDB(t) // same helper meeting_recaps_test.go uses
    id, err := database.InsertMeetingTranscript(db.MeetingTranscript{
        Title: "Weekly sync", DurationSec: 1800, LangStats: `{"ru":40,"en":5}`,
        TranscriptText: "hello world",
        AudioPath:      sql.NullString{String: "/tmp/rec.m4a", Valid: true},
    })
    // assert err nil, id > 0
    got, err := database.GetMeetingTranscript(id)
    // assert fields round-trip; EventID invalid (NULL); CreatedAt non-empty
}

func TestGetMeetingTranscriptMissing(t *testing.T) { /* GetMeetingTranscript(999) → (nil, nil) */ }

func TestListMeetingTranscriptsFilters(t *testing.T) {
    // insert calendar event "evt-1" (reuse the fixture insert used in meeting_recaps_test.go),
    // insert 2 transcripts: one with EventID evt-1, one ad-hoc.
    // ListMeetingTranscripts(Filter{EventID: "evt-1"}) → 1 row
    // ListMeetingTranscripts(Filter{}) → 2 rows, newest first
    // ListMeetingTranscripts(Filter{Limit: 1}) → 1 row
}

func TestSetMeetingTranscriptSummary(t *testing.T) { /* insert, set, refetch, SummaryJSON.Valid && == payload */ }

func TestTranscriptAudioRetention(t *testing.T) {
    // insert 2 rows; UPDATE one's created_at to '2020-01-01T00:00:00Z' via database.Exec
    // ExpiredTranscriptAudio("2025-01-01T00:00:00Z") → only the old one
    // ClearMeetingTranscriptAudio(oldID); refetch → AudioPath !Valid
    // ExpiredTranscriptAudio again → 0 rows (audio_path now NULL)
}

func TestTranscriptSurvivesEventDeletion(t *testing.T) {
    // insert event evt-1 + linked transcript; DELETE FROM calendar_events WHERE id='evt-1'
    // refetch transcript → still exists, EventID !Valid (SET NULL)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `go test ./internal/db/ -run MeetingTranscript > /tmp/t2.log 2>&1; echo "exit=$?"`
Expected: exit=1, "undefined: db.MeetingTranscript" style compile errors.

- [ ] **Step 3: Implement `internal/db/meeting_transcripts.go`** — clone the `meeting_recaps.go` idioms (`sql.ErrNoRows → (nil, nil)`, wrapped errors, `strftime` for updated_at). `ListMeetingTranscripts` builds WHERE clauses dynamically, `ORDER BY created_at DESC, id DESC`, default limit 50.

- [ ] **Step 4: Run tests to verify they pass**

Run: `go test ./internal/db/ > /tmp/t2b.log 2>&1; echo "exit=$?"` → exit=0.

- [ ] **Step 5: Commit** — `git commit -m "feat(db): meeting_transcripts CRUD + retention queries"`

---

### Task 3: Go — stdin path for large AI inputs (claude + codex)

**Files:**
- Modify: `internal/digest/generator.go` (`generateArgs` line 74, `Generate` line 175)
- Modify: `internal/codex/generator.go` (`Generate` line 36)
- Modify: `internal/digest/generator_test.go`, `internal/codex/generator_test.go` (or create arg-construction tests beside existing ones)

**Interfaces:**
- Consumes: nothing new.
- Produces: transparent behavior change in both `Generate` implementations — when `len(userMessage) > digest.StdinThreshold` the message travels via the subprocess's stdin instead of argv. Exported const `digest.StdinThreshold = 32 * 1024`. Task 4 relies on this to pass full transcripts as `userMessage`.

- [ ] **Step 1: Write failing tests** for the args builders:

```go
// internal/digest/generator_test.go
func TestGenerateArgsSmallMessageInline(t *testing.T) {
    args, stdin := generateArgs("m", "sys", "hello")
    // stdin == "" ; args contains "-p","hello" and "--system-prompt","sys"
}
func TestGenerateArgsLargeMessageViaStdin(t *testing.T) {
    big := strings.Repeat("x", StdinThreshold+1)
    args, stdin := generateArgs("m", "sys", big)
    // stdin == big
    // args contains bare "-p" NOT followed by the message (next token starts with "--")
    // args does NOT contain big anywhere
}
func TestGenerateArgsThresholdBoundary(t *testing.T) {
    exact := strings.Repeat("x", StdinThreshold)
    _, stdin := generateArgs("m", "sys", exact) // exactly threshold stays inline
    // stdin == ""
}
```

```go
// internal/codex/generator_test.go
func TestCodexArgsLargeMessageViaStdin(t *testing.T) {
    // extract codex arg construction into buildArgs(model, systemPrompt, userMessage) (args []string, stdin string)
    // small → last arg is the message, stdin ""
    // large → last arg is "-", stdin == message
}
```

- [ ] **Step 2: Run tests to verify they fail** — `go test ./internal/digest/ ./internal/codex/ -run 'GenerateArgs|CodexArgs' > /tmp/t3.log 2>&1; echo "exit=$?"` → exit=1 (signature mismatch).

- [ ] **Step 3: Implement.**

`internal/digest/generator.go`:

```go
// StdinThreshold is the user-message size above which generators pass the
// message via the subprocess's stdin instead of argv, to stay clear of
// ARG_MAX (hour-long meeting transcripts run to hundreds of KB).
const StdinThreshold = 32 * 1024

// generateArgs builds CLI args; when userMessage exceeds StdinThreshold it is
// returned as stdin content instead ("-p" with no value makes claude read the
// prompt from stdin). See validateModelArgs for --setting-sources rationale.
func generateArgs(model, systemPrompt, userMessage string) ([]string, string) {
    stdin := ""
    args := []string{"-p"}
    if len(userMessage) > StdinThreshold {
        stdin = userMessage
    } else {
        args = append(args, userMessage)
    }
    args = append(args,
        "--output-format", "json",
        "--model", model,
        "--no-session-persistence",
        "--tools", "",
        "--setting-sources", "project,local",
    )
    if systemPrompt != "" {
        args = append(args, "--system-prompt", systemPrompt)
    }
    return args, stdin
}
```

In `Generate` (line ~181): `args, stdin := generateArgs(model, systemPrompt, userMessage)`; after building `cmd`: `if stdin != "" { cmd.Stdin = strings.NewReader(stdin) }`. Update `validateModelArgs` call sites if the compiler complains (it has its own builder — untouched).

`internal/codex/generator.go`: extract the arg building (lines 44–56) into `buildArgs(model, systemPrompt, userMessage string) ([]string, string)`; large message → final positional arg `"-"` (codex `exec -` reads the prompt from stdin) and stdin content returned; wire `cmd.Stdin` identically.

- [ ] **Step 4: Run package tests** — `go test ./internal/digest/ ./internal/codex/ > /tmp/t3b.log 2>&1; echo "exit=$?"` → exit=0.

- [ ] **Step 5: Manual smoke check of the claude stdin contract** (the one assumption unit tests can't cover):

```bash
echo "Reply with the single word PONG" | claude -p --output-format json --no-session-persistence --tools "" --setting-sources project,local | head -c 400
```

Expected: JSON with `"result"` containing "PONG". If `-p` without a value misparses (swallows `--output-format`), fall back to `-p ""` + stdin and adjust `generateArgs` + tests accordingly — record which variant worked in the commit message.

- [ ] **Step 6: Commit** — `git commit -m "feat(ai): pass oversized user messages via stdin to claude/codex (ARG_MAX safety)"`

---

### Task 4: Go — `GenerateTranscriptRecap` pipeline method + prompt amendment

**Files:**
- Create: `internal/meeting/transcript_recap.go`
- Create: `internal/meeting/transcript_recap_test.go`
- Modify: `internal/prompts/defaults.go` (`defaultMeetingRecap` line 1036, `DefaultVersions` line 94)

**Interfaces:**
- Consumes: `Pipeline` (meeting/pipeline.go), `RecapResult` + `cleanJSON` + `trimNonEmpty` (recap.go), `digest.Usage`, Task 3's stdin path (implicit).
- Produces (used by Task 5):

```go
// eventID "" ⇒ ad-hoc recording (placeholder event metadata).
func (p *Pipeline) GenerateTranscriptRecap(ctx context.Context, eventID, transcript string) (*RecapResult, *digest.Usage, error)
```

- [ ] **Step 1: Amend the default prompt.** In `defaultMeetingRecap` change the opening line to:

```
You produce a structured recap of a meeting based on raw notes the user pasted, or on an automatic single-track audio transcript (speakers are not labeled; the transcript may mix ru/uk/en and contain recognition noise — ignore obvious mis-transcriptions).
```

Bump `DefaultVersions[MeetingRecap]` from 1 to 2 with comment `// v2: cover transcript-sourced recaps`. Check `internal/prompts/store.go` sync behavior: the store re-seeds a prompt row when the default version increases (read the sync function once and confirm; if a `prompt_history` row is written, that's expected).

- [ ] **Step 2: Write failing tests** in `internal/meeting/transcript_recap_test.go` (reuse the package's existing mock generator from recap tests — find it in `recap_test.go`; it records the last systemPrompt/userMessage and returns canned JSON):

```go
func TestGenerateTranscriptRecapAdHoc(t *testing.T) {
    // pipeline with mock generator returning {"summary":"s","key_decisions":["d"],"action_items":[],"open_questions":[]}
    res, usage, err := pipe.GenerateTranscriptRecap(ctx, "", "we agreed to ship v2 on friday")
    // err nil; res.Summary=="s"; usage non-nil
    // mock.lastUserMessage contains the transcript text
    // mock.lastSystemPrompt does NOT contain the transcript (it moved to userMessage)
    // mock.lastSystemPrompt contains "(ad-hoc recording)" for the title slot
}
func TestGenerateTranscriptRecapWithEvent(t *testing.T) {
    // insert calendar event; systemPrompt contains its title
}
func TestGenerateTranscriptRecapEmptyTranscript(t *testing.T) {
    _, _, err := pipe.GenerateTranscriptRecap(ctx, "", "   \n\t ")
    // err non-nil (degenerate input: whitespace-only must be an explicit error)
}
func TestGenerateTranscriptRecapBadAIJSON(t *testing.T) { /* mock returns "not json" → err non-nil */ }
```

- [ ] **Step 3: Run tests to verify they fail** — `go test ./internal/meeting/ -run TranscriptRecap > /tmp/t4.log 2>&1; echo "exit=$?"` → exit=1.

- [ ] **Step 4: Implement `internal/meeting/transcript_recap.go`:**

```go
package meeting

import (
    "context"
    "encoding/json"
    "fmt"
    "strings"

    "watchtower/internal/digest"
    "watchtower/internal/prompts"
)

// GenerateTranscriptRecap produces a RecapResult from a full meeting
// transcript. Unlike GenerateRecap, the transcript travels in the USER
// message (not the system prompt) so the generators' stdin path keeps
// hour-long transcripts clear of ARG_MAX. eventID may be "" for ad-hoc
// recordings. The pipeline does NOT persist — the CLI caller writes.
func (p *Pipeline) GenerateTranscriptRecap(ctx context.Context, eventID, transcript string) (*RecapResult, *digest.Usage, error) {
    trimmed := strings.TrimSpace(transcript)
    if trimmed == "" {
        return nil, nil, fmt.Errorf("transcript is empty")
    }

    title, startTime, endTime, attendees, description := "(ad-hoc recording)", "", "", "", ""
    topicsBlock, notesBlock := "(none)", "(none)"
    if eventID != "" && p.db != nil {
        if ev, err := p.db.GetCalendarEventByID(eventID); err == nil && ev != nil {
            title, startTime, endTime = ev.Title, ev.StartTime, ev.EndTime
            attendees, description = ev.Attendees, ev.Description
        }
        // meeting_notes context — same extraction as GenerateRecap
        if notes, err := p.db.GetMeetingNotesForEvent(eventID); err == nil {
            var qs, ns []string
            for _, n := range notes {
                line := "- " + strings.TrimSpace(n.Text)
                switch n.Type {
                case "question":
                    qs = append(qs, line)
                case "note":
                    ns = append(ns, line)
                }
            }
            if len(qs) > 0 { topicsBlock = strings.Join(qs, "\n") }
            if len(ns) > 0 { notesBlock = strings.Join(ns, "\n") }
        }
    }

    lang := ""
    if p.cfg != nil { lang = p.cfg.Digest.Language }

    tmpl := p.loadRecapPrompt()
    systemPrompt := fmt.Sprintf(tmpl,
        title, startTime, endTime, attendees, description,
        topicsBlock, notesBlock,
        "(the full meeting transcript is provided in the user message)",
        prompts.Directive(lang),
    )
    userMessage := "Below is the full single-track meeting transcript (speakers are not labeled). " +
        "Generate the recap JSON exactly per the system prompt.\n\n=== TRANSCRIPT ===\n" + trimmed

    aiResponse, usage, _, err := p.generator.Generate(ctx, systemPrompt, userMessage, "")
    if err != nil {
        return nil, nil, fmt.Errorf("AI generation: %w", err)
    }
    var raw RecapResult
    if err := json.Unmarshal([]byte(cleanJSON(aiResponse)), &raw); err != nil {
        return nil, nil, fmt.Errorf("parsing AI response: %w (raw: %.300s)", err, aiResponse)
    }
    raw.Summary = strings.TrimSpace(raw.Summary)
    raw.KeyDecisions = trimNonEmpty(raw.KeyDecisions)
    raw.ActionItems = trimNonEmpty(raw.ActionItems)
    raw.OpenQuestions = trimNonEmpty(raw.OpenQuestions)
    return &raw, usage, nil
}
```

- [ ] **Step 5: Run tests** — `go test ./internal/meeting/ ./internal/prompts/ > /tmp/t4b.log 2>&1; echo "exit=$?"` → exit=0.

- [ ] **Step 6: Commit** — `git commit -m "feat(meeting): GenerateTranscriptRecap — recap from audio transcript via user-message path"`

---

### Task 5: Go CLI — `meeting-prep transcript save|recap|list|show`

**Files:**
- Create: `cmd/meeting_transcript.go`
- Create: `cmd/meeting_transcript_test.go`

**Interfaces:**
- Consumes: Task 2 DB API, Task 4 `GenerateTranscriptRecap`, existing `UpsertMeetingRecap`, `CreatePipelineRun`/`CompletePipelineRun` (pipeline_runs.go:49/61), `cliGenerator(cfg)` (cmd/generator.go), `meeting.New`.
- Produces (consumed by Swift Task 10):
  - `watchtower meeting-prep transcript save --transcript-file <path> [--audio <path>] [--duration <sec>] [--event-id <id>] [--title <s>] [--lang-stats <json>]` → stdout JSON envelope:
    `{"transcript_id": 7, "event_id": "evt-1", "title": "...", "recap_ok": true, "recap_error": ""}`
    Exit 0 whenever the transcript row was saved, **even if the recap failed** (recap_error non-empty); exit 1 only when nothing was persisted.
  - `watchtower meeting-prep transcript recap <id>` → regenerates the recap for a saved transcript (retry path), same envelope.
  - `watchtower meeting-prep transcript list [--event-id <id>]` / `show <id>` → JSON.

- [ ] **Step 1: Write failing tests** in `cmd/meeting_transcript_test.go`. Follow the package's existing command-test patterns (see `meeting_test.go` / `helpers_test.go` for building a test config+DB and executing commands with `rootCmd.SetArgs`). Cover:

```go
func TestTranscriptSaveRequiresFile(t *testing.T)      // no --transcript-file → error, exit non-zero
func TestTranscriptSaveEmptyFileFails(t *testing.T)    // file with "   \n" → error "transcript is empty", NO row inserted
func TestTranscriptSaveAdHocPersistsAndRecaps(t *testing.T) {
    // mock generator (see how meeting_test.go injects one; if commands construct
    // cliGenerator directly, add a package-level test hook variable
    // `transcriptGeneratorFactory` defaulting to cliGenerator — same pattern as
    // other cmd tests that stub generators)
    // run: transcript save --transcript-file f --title "Ad hoc" --duration 60
    // assert: row exists (ListMeetingTranscripts), SummaryJSON.Valid,
    // stdout envelope recap_ok=true, pipeline_runs has a "meeting_transcript" row with status done
}
func TestTranscriptSaveEventLinkedWritesMeetingRecaps(t *testing.T) {
    // insert calendar event evt-1; save with --event-id evt-1
    // assert meeting_recaps row for evt-1 exists with recap_json set and
    // source_text == transcript text; meeting_transcripts.SummaryJSON NOT set
}
func TestTranscriptSaveRecapFailureStillPersists(t *testing.T) {
    // generator returns error → exit 0, envelope recap_ok=false + recap_error,
    // transcript row exists, pipeline_runs row status "error"
}
func TestTranscriptRecapRetry(t *testing.T)  // transcript recap <id> fills the missing summary
func TestTranscriptListAndShow(t *testing.T) // list returns saved rows; show <id> includes transcript_text
```

- [ ] **Step 2: Run to verify failure** — `go test ./cmd/ -run Transcript > /tmp/t5.log 2>&1; echo "exit=$?"` → exit=1.

- [ ] **Step 3: Implement `cmd/meeting_transcript.go`.** Structure (mirror `runMeetingRecap` boilerplate for config/db/generator):

```go
var (
    transcriptSaveFlagFile, transcriptSaveFlagAudio            string
    transcriptSaveFlagEventID, transcriptSaveFlagTitle         string
    transcriptSaveFlagLangStats                                string
    transcriptSaveFlagDuration                                 int
    transcriptListFlagEventID                                  string
)

var meetingTranscriptCmd = &cobra.Command{Use: "transcript", Short: "Manage meeting transcripts"}
// subcommands: transcriptSaveCmd, transcriptRecapCmd (Args: cobra.ExactArgs(1)),
// transcriptListCmd, transcriptShowCmd (Args: cobra.ExactArgs(1))

func init() {
    meetingPrepCmd.AddCommand(meetingTranscriptCmd)
    meetingTranscriptCmd.AddCommand(transcriptSaveCmd, transcriptRecapCmd, transcriptListCmd, transcriptShowCmd)
    // flags per the Produces contract above
}
```

`runTranscriptSave` core logic:

```go
raw, err := os.ReadFile(transcriptSaveFlagFile)
// error → return err (exit 1)
text := strings.TrimSpace(string(raw))
if text == "" { return fmt.Errorf("transcript file is empty") }

title := transcriptSaveFlagTitle
if title == "" && transcriptSaveFlagEventID != "" {
    if ev, err := database.GetCalendarEventByID(transcriptSaveFlagEventID); err == nil && ev != nil { title = ev.Title }
}
if title == "" { title = "Recording " + time.Now().Local().Format("2006-01-02 15:04") }

id, err := database.InsertMeetingTranscript(db.MeetingTranscript{ /* flags → fields; EventID/AudioPath via sql.NullString{Valid: flag != ""} */ })
if err != nil { return fmt.Errorf("persisting transcript: %w", err) }

recapErr := generateAndStoreTranscriptRecap(cmd.Context(), database, cfg, id)
return printTranscriptEnvelope(cmd, database, id, recapErr) // envelope; recap failure ⇒ still exit 0
```

`generateAndStoreTranscriptRecap(ctx, database, cfg, id)` — shared by save and the `recap <id>` retry command:

```go
tr, err := database.GetMeetingTranscript(id) // nil → error
runID, _ := database.CreatePipelineRun("meeting_transcript", "cli", cfg.Digest.Model)
pipe := meeting.New(database, cfg, transcriptGeneratorFactory(cfg), nil)
eventID := ""
if tr.EventID.Valid { eventID = tr.EventID.String }
res, usage, err := pipe.GenerateTranscriptRecap(ctx, eventID, tr.TranscriptText)
if err != nil {
    _ = database.CompletePipelineRun(runID, 0, 0, 0, 0, 0, nil, nil, err.Error())
    return err
}
recapJSON, _ := json.Marshal(res)
if eventID != "" {
    err = database.UpsertMeetingRecap(eventID, tr.TranscriptText, string(recapJSON))
} else {
    err = database.SetMeetingTranscriptSummary(id, string(recapJSON))
}
in, out, api := 0, 0, 0
if usage != nil { in, out, api = usage.InputTokens, usage.OutputTokens, usage.TotalAPITokens }
storeErrMsg := ""
if err != nil { storeErrMsg = err.Error() }
_ = database.CompletePipelineRun(runID, 1, in, out, 0, api, nil, nil, storeErrMsg)
return err
```

`list`/`show`: thin JSON encoders over `ListMeetingTranscripts`/`GetMeetingTranscript` (show includes `transcript_text`; list omits it, includes a 200-char snippet).

- [ ] **Step 4: Run tests** — `go test ./cmd/ > /tmp/t5b.log 2>&1; echo "exit=$?"` → exit=0. Also `go vet ./... && go build ./...`.

- [ ] **Step 5: Commit** — `git commit -m "feat(cli): meeting-prep transcript save/recap/list/show"`

---

### Task 6: Go — config + daemon audio-retention phase

**Files:**
- Modify: `internal/config/config.go` (add `TranscriptsConfig`, wire into `Config` struct ~line 165, add `v.SetDefault` in `Load`)
- Modify: `internal/config/defaults.go` (add `DefaultTranscriptAudioRetentionDays = 30`)
- Modify: `internal/daemon/daemon.go` (new phase; call site in `runSync` right after `d.phaseUnsnooze()` line 231)
- Test: `internal/daemon/transcript_cleanup_test.go`, config test alongside existing config tests

**Interfaces:**
- Consumes: Task 2 `ExpiredTranscriptAudio`/`ClearMeetingTranscriptAudio`.
- Produces: `cfg.Transcripts.AudioRetentionDays int` (`mapstructure:"audio_retention_days"`, YAML section `transcripts:`); daemon method `phaseTranscriptAudioCleanup()`.

- [ ] **Step 1: Config change** (small, test via existing config default tests pattern):

```go
// TranscriptsConfig holds settings for meeting transcript storage.
type TranscriptsConfig struct {
    AudioRetentionDays int `mapstructure:"audio_retention_days"` // delete recording audio after N days (default 30); transcript text is kept forever
}
```

Add `Transcripts TranscriptsConfig \`mapstructure:"transcripts"\`` to `Config`; `v.SetDefault("transcripts.audio_retention_days", DefaultTranscriptAudioRetentionDays)` in `Load`. Add a default-value assertion to the existing config defaults test.

- [ ] **Step 2: Write failing daemon test** in `internal/daemon/transcript_cleanup_test.go` (follow existing daemon phase tests for constructing a `Daemon` with a test DB — find the pattern in the package's tests, e.g. the unsnooze phase test):

```go
func TestPhaseTranscriptAudioCleanup(t *testing.T) {
    // create temp file /tmp-ish via t.TempDir(); insert transcript with that audio_path,
    // backdate created_at to 40 days ago via db.Exec; insert a fresh transcript with another file
    // run d.phaseTranscriptAudioCleanup()
    // old: file removed from disk, AudioPath NULL; fresh: file intact, AudioPath set
}
func TestPhaseTranscriptAudioCleanupMissingFileIdempotent(t *testing.T) {
    // expired row whose audio file was already deleted manually → phase still NULLs audio_path, no error
}
```

- [ ] **Step 3: Verify failure** — `go test ./internal/daemon/ -run TranscriptAudioCleanup > /tmp/t6.log 2>&1; echo "exit=$?"` → exit=1.

- [ ] **Step 4: Implement:**

```go
// phaseTranscriptAudioCleanup deletes meeting-recording audio files past the
// retention window and NULLs audio_path. Transcript text is never touched.
// Missing files are fine (idempotent re-runs).
func (d *Daemon) phaseTranscriptAudioCleanup() {
    if d.db == nil {
        return
    }
    days := d.cfg.Transcripts.AudioRetentionDays
    if days <= 0 {
        return // retention disabled
    }
    cutoff := time.Now().UTC().AddDate(0, 0, -days).Format(time.RFC3339)
    rows, err := d.db.ExpiredTranscriptAudio(cutoff)
    if err != nil {
        d.logger.Printf("transcript cleanup query error: %v", err)
        return
    }
    for _, tr := range rows {
        if err := os.Remove(tr.AudioPath.String); err != nil && !os.IsNotExist(err) {
            d.logger.Printf("transcript cleanup: removing %s: %v", tr.AudioPath.String, err)
            continue // keep audio_path so a later run retries
        }
        if err := d.db.ClearMeetingTranscriptAudio(tr.ID); err != nil {
            d.logger.Printf("transcript cleanup: clearing row %d: %v", tr.ID, err)
        }
    }
    if len(rows) > 0 {
        d.logger.Printf("transcript cleanup: processed %d expired recording(s)", len(rows))
    }
}
```

Call `d.phaseTranscriptAudioCleanup()` in `runSync` immediately after `d.phaseUnsnooze()`. (Confirm the daemon struct's config field name — it may be `d.cfg` or similar; adapt.)

- [ ] **Step 5: Run** — `go test ./internal/daemon/ ./internal/config/ > /tmp/t6b.log 2>&1; echo "exit=$?"` → exit=0.

- [ ] **Step 6: Commit** — `git commit -m "feat(daemon): transcript audio retention phase (transcripts.audio_retention_days)"`

---

### Task 7: Go — MCP tools `list_transcripts` / `get_transcript`

**Files:**
- Create: `internal/mcp/transcripts.go`
- Create: `internal/mcp/transcripts_test.go`
- Modify: `internal/mcp/server.go` (`NewServer` line ~76: add `registerTranscripts(s, database)`)

**Interfaces:**
- Consumes: Task 2 `ListMeetingTranscripts`/`GetMeetingTranscript`, mcp package helpers `jsonResult`/`jsonListResult`/`errResult`/`listLimit`.
- Produces: read-only MCP tools:
  - `list_transcripts` args `{event_id?, from?, to?, limit?}` (from/to = `YYYY-MM-DD`) → rows with `id, title, event_id, event_title, duration_sec, created_at, summary` (one-line summary from recap JSON if present).
  - `get_transcript` args `{id}` → full `transcript_text` + parsed recap fields.

- [ ] **Step 1: Write failing tests** in `internal/mcp/transcripts_test.go` — follow `messages_test.go` (in-process client session over the server, call tool, decode result). Cover: list returns inserted transcripts newest-first; `event_id` filter; `get_transcript` returns full text; unknown id → error result; `from`/`to` date filtering (map to `MeetingTranscriptFilter.FromTime`/`ToTime` as `<date>T00:00:00Z` / `<date>T23:59:59Z`).

- [ ] **Step 2: Verify failure** — `go test ./internal/mcp/ -run Transcript > /tmp/t7.log 2>&1; echo "exit=$?"` → exit=1.

- [ ] **Step 3: Implement** following `messages.go` shape:

```go
type listTranscriptsArgs struct {
    EventID string `json:"event_id,omitempty" jsonschema:"filter to one calendar event id"`
    From    string `json:"from,omitempty" jsonschema:"only transcripts recorded on/after this date (YYYY-MM-DD)"`
    To      string `json:"to,omitempty" jsonschema:"only transcripts recorded on/before this date (YYYY-MM-DD)"`
    Limit   int    `json:"limit,omitempty" jsonschema:"max results, 0 = default (50), capped at 200"`
}
type getTranscriptArgs struct {
    ID int64 `json:"id" jsonschema:"transcript id from list_transcripts"`
}
```

`list_transcripts` description: "List locally-recorded meeting transcripts (title, linked calendar event, recap summary). Use to find what was discussed/decided in a meeting; fetch full text with get_transcript." For `event_title`, look up `GetCalendarEventByID` when `event_id` valid. Summary line: unmarshal recap JSON (from `summary_json`, or `meeting_recaps` via event) and take `.summary`.

- [ ] **Step 4: Run** — `go test ./internal/mcp/ > /tmp/t7b.log 2>&1; echo "exit=$?"` → exit=0. Full gate: `go test ./... > /tmp/go-all.log 2>&1; echo "exit=$?"` → exit=0.

- [ ] **Step 5: Commit** — `git commit -m "feat(mcp): list_transcripts + get_transcript tools for secretary chat"`

---

### Task 8: Swift — WhisperKit dependency, model, queries, test schema

**Files:**
- Modify: `WatchtowerDesktop/Package.swift` (add WhisperKit)
- Create: `WatchtowerDesktop/Sources/Models/MeetingTranscript.swift`
- Create: `WatchtowerDesktop/Sources/Database/Queries/MeetingTranscriptQueries.swift`
- Modify: `WatchtowerDesktop/Tests/Helpers/TestDatabase.swift` (add table to `schema`, add fixture inserter)
- Create: `WatchtowerDesktop/Tests/MeetingTranscriptQueriesTests.swift`, `WatchtowerDesktop/Tests/MeetingTranscriptTests.swift`

**Interfaces:**
- Consumes: Task 1 schema (column names must match exactly).
- Produces (used by Tasks 12–14):

```swift
struct MeetingTranscript: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "meeting_transcripts"
    var id: Int64?
    let eventID: String?
    let title: String
    let audioPath: String?
    let durationSec: Int
    let langStats: String
    let transcriptText: String
    let summaryJSON: String?
    let createdAt: String
    let updatedAt: String
    var parsedSummary: MeetingRecap.Content? // decode summaryJSON (snake_case keys, reuse MeetingRecap.Content)
    // CodingKeys → snake_case columns (event_id, audio_path, duration_sec, lang_stats, transcript_text, summary_json, created_at, updated_at)
}
enum MeetingTranscriptQueries {
    static func fetch(_ db: Database, id: Int64) throws -> MeetingTranscript?
    static func fetchForEvent(_ db: Database, eventID: String) throws -> [MeetingTranscript] // newest first
    static func fetchAdHoc(_ db: Database, limit: Int = 50) throws -> [MeetingTranscript]    // event_id IS NULL, newest first
    /// Dual-path write (documented pattern, cf. CatchUpQueries.acknowledge):
    /// links transcript to event; if the event has no meeting_recaps row and the
    /// transcript has a summary, copies it into meeting_recaps (source_text = transcript text).
    static func linkToEvent(_ db: Database, id: Int64, eventID: String) throws
}
```

- [ ] **Step 1: Add WhisperKit to `Package.swift`:** `.package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0")` and `"WhisperKit"` in the executable target's dependencies. Run `swift build > /tmp/spm.log 2>&1; echo "exit=$?"` → exit=0 (resolves + builds; pin whatever `from:` version resolves cleanly with tools 5.10 / macOS 14 — adjust if 0.9.0 needs newer, record the chosen version in the commit).

- [ ] **Step 2: Add DDL to `TestDatabase.swift` `schema`** (after the `meeting_recaps` block, lines ~982-988) — copy the CREATE TABLE from Task 1 verbatim (with `IF NOT EXISTS`). Add fixture helper:

```swift
static func insertMeetingTranscript(
    _ db: Database, id: Int64? = nil, eventID: String? = nil, title: String = "Rec",
    audioPath: String? = nil, durationSec: Int = 60, transcriptText: String = "text",
    summaryJSON: String? = nil
) throws { /* INSERT with strftime defaults for timestamps */ }
```

- [ ] **Step 3: Write failing tests.**

`Tests/MeetingTranscriptTests.swift`: `parsedSummary` decodes `{"summary":"s","key_decisions":["d"],"action_items":[],"open_questions":[]}`; returns nil for nil/malformed JSON.

`Tests/MeetingTranscriptQueriesTests.swift` (pattern: `let db = try TestDatabase.create(); try db.write {...}; try db.read {...}`):
- fetchForEvent returns only that event's rows, newest first; fetchAdHoc returns only NULL-event rows.
- `linkToEvent` with transcript summary + no existing recap → `meeting_recaps` row appears with `recap_json == summaryJSON` and `source_text == transcriptText`, transcript's `event_id` set.
- `linkToEvent` when event already has a recap → recap untouched, only `event_id` written.
- `linkToEvent` when transcript has no summary → only `event_id` written, no recap row.

- [ ] **Step 4: Verify failure** — `cd WatchtowerDesktop && swift test > /tmp/t8.log 2>&1; echo "exit=$?"` → exit=1 (missing types).

- [ ] **Step 5: Implement model + queries** per the Produces block (queries are stateless statics over `Database`, GRDB record API like `MeetingRecapQueries.fetch`).

- [ ] **Step 6: Run** — `swift test > /tmp/t8b.log 2>&1; echo "exit=$?"` → exit=0.

- [ ] **Step 7: Commit** — `git commit -m "feat(desktop): WhisperKit dep, MeetingTranscript model + queries, test schema"`

---

### Task 9: Swift — `TranscriptionEngine` protocol + windowed language detection (pure logic)

**Files:**
- Create: `WatchtowerDesktop/Sources/Services/Transcription/TranscriptionEngine.swift`
- Create: `WatchtowerDesktop/Sources/Services/Transcription/WindowedTranscriber.swift`
- Create: `WatchtowerDesktop/Tests/WindowedTranscriberTests.swift`

**Interfaces:**
- Produces (used by Tasks 10, 12, 13):

```swift
/// Abstraction over the on-device STT engine so tests never load WhisperKit/CoreML.
protocol TranscriptionEngine: Sendable {
    /// Language probabilities for one audio window (16 kHz mono Float32 samples).
    func detectLanguage(_ samples: [Float]) async throws -> [String: Float]
    /// Transcribe one window with the language forced. Returns raw text ("" = no speech).
    func transcribeWindow(_ samples: [Float], language: String) async throws -> String
}

struct TranscriptionConfig: Equatable {
    var windowSec: Double = 20
    var overlapSec: Double = 1.0
    var langset: [String] = ["ru", "uk", "en"]
    var langThreshold: Float = 0.6
    var margin: Float = 0.2
    var firstWindowDefault: String = "ru"
    var forcedLanguage: String? = nil   // non-nil disables detection entirely
    static let sampleRate = 16_000
}

struct TranscriptionOutput: Equatable {
    let text: String                 // newline-joined non-empty window texts
    let langStats: [String: Int]     // windows per language (speech windows only)
}

/// Direct port of snoop transcribe.py's windowing + sticky-language algorithm.
struct WindowedTranscriber {
    let engine: TranscriptionEngine
    let config: TranscriptionConfig
    /// progress: (windowIndex, windowCount) after each window completes.
    func transcribe(samples: [Float], progress: @escaping @Sendable (Int, Int) -> Void) async throws -> TranscriptionOutput
}
```

Algorithm (must match snoop semantics exactly):
1. `windowSamples = windowSec * 16000`, `step = windowSamples - overlapSec * 16000`, window starts at `0, step, 2*step, …` while `< samples.count`; last window truncated.
2. Per window: if `forcedLanguage` set → use it. Else `detectLanguage`, restrict probs to `langset`, pick best; accept if `p >= langThreshold && (p - runnerUp) >= margin`; otherwise sticky fallback to previous *speech* window's language, or `firstWindowDefault` if none yet. `detectLanguage` throwing for one window → treated as low confidence (fallback), not fatal.
3. `transcribeWindow` with chosen language; empty/whitespace text → skip window, language does NOT stick, not counted in langStats. Non-empty → append text, `prevLang = chosen`, `langStats[chosen] += 1`. A window transcription error → skip that window, continue (count nothing).
4. Empty `samples` or zero speech windows → `TranscriptionOutput(text: "", langStats: [:])` (caller decides that empty text is an error).

- [ ] **Step 1: Write failing tests** with a scripted `MockEngine: TranscriptionEngine` (arrays of canned detection dicts + texts, records forced languages used):

```swift
func testForcedLanguageSkipsDetection()          // forcedLanguage "en" → detectLanguage never called
func testConfidentDetectionUsed()                // {"ru":0.9,"en":0.05} → window transcribed as ru
func testLowConfidenceFallsBackToPrevious()      // window1 ru@0.9 (speech); window2 {"ru":0.4,"en":0.35} → ru
func testLowMarginFallsBackToPrevious()          // {"ru":0.62,"uk":0.55} margin 0.07 < 0.2 → previous
func testFirstWindowLowConfidenceUsesDefault()   // first window unsure → "ru"
func testSilentWindowDoesNotStick()              // w1 en@0.9 speech; w2 uk@0.9 but text "" ; w3 unsure → falls back to "en" (not uk)
func testLangStatsCountsSpeechWindowsOnly()
func testWindowingMath()                         // 50s audio @20s window/1s overlap → starts at 0,19,38 (3 windows); progress called 3 times with (i,3)
func testDetectErrorFallsBack()                  // detectLanguage throws on w2 → previous language used, no crash
func testEmptySamplesReturnsEmptyOutput()
func testLangsetRestriction()                    // probs {"de":0.95,"ru":0.04,"en":0.01} → best-in-langset logic (ru wins the sub-dict; p=0.04 < threshold → fallback/default)
```

- [ ] **Step 2: Verify failure** — `swift test --filter WindowedTranscriber > /tmp/t9.log 2>&1; echo "exit=$?"` → exit=1.

- [ ] **Step 3: Implement `WindowedTranscriber.transcribe`** per the algorithm above (~60 lines, no Foundation beyond basics).

- [ ] **Step 4: Run** — `swift test --filter WindowedTranscriber > /tmp/t9b.log 2>&1; echo "exit=$?"` → exit=0.

- [ ] **Step 5: Commit** — `git commit -m "feat(desktop): TranscriptionEngine protocol + windowed sticky-language transcriber (snoop port)"`

---

### Task 10: Swift — `TranscriptSaveService` (CLI bridge)

**Files:**
- Create: `WatchtowerDesktop/Sources/Services/TranscriptSaveService.swift`
- Create: `WatchtowerDesktop/Tests/TranscriptSaveServiceTests.swift`

**Interfaces:**
- Consumes: `CLIRunnerProtocol` (CLIRunner.swift lines 8-12), Task 5's CLI envelope.
- Produces (used by Task 12):

```swift
struct TranscriptSaveResult: Decodable, Equatable {
    let transcriptID: Int64
    let recapOK: Bool
    let recapError: String
    // CodingKeys: transcript_id, recap_ok, recap_error
}
struct TranscriptSaveService {
    let runner: CLIRunnerProtocol
    /// Writes transcriptText to a temp file, invokes
    /// `meeting-prep transcript save --transcript-file <tmp> --audio <p> --duration <n> [--event-id][--title][--lang-stats]`,
    /// decodes the envelope. Temp file removed in defer.
    func save(transcriptText: String, audioPath: String, durationSec: Int,
              eventID: String?, title: String?, langStatsJSON: String) async throws -> TranscriptSaveResult
    /// `meeting-prep transcript recap <id>` — retry a failed recap.
    func retryRecap(transcriptID: Int64) async throws -> TranscriptSaveResult
}
```

- [ ] **Step 1: Write failing tests** with `FakeCLIRunner` (Tests/Helpers/FakeCLIRunner.swift), mirroring `MeetingRecapServiceTests` exact-args assertions:
  - args order: `["meeting-prep","transcript","save","--transcript-file",<path>,"--audio",<audio>,"--duration","1800","--event-id","evt-1","--title","Weekly","--lang-stats",<json>]`; optional flags omitted when nil.
  - the `--transcript-file` arg points to a file that exists **during** the run and contains the transcript (FakeCLIRunner subclass/closure captures and reads it inside `run`).
  - envelope decode: stdout `{"transcript_id":7,"recap_ok":false,"recap_error":"boom",...}` → result fields.
  - runner throw propagates.
  - `retryRecap` args: `["meeting-prep","transcript","recap","7"]`.

- [ ] **Step 2: Verify failure** — `swift test --filter TranscriptSaveService > /tmp/t10.log 2>&1; echo "exit=$?"` → exit=1.

- [ ] **Step 3: Implement** (temp file in `FileManager.default.temporaryDirectory`, `defer { try? FileManager.default.removeItem(...) }`).

- [ ] **Step 4: Run** — exit=0. **Step 5: Commit** — `git commit -m "feat(desktop): TranscriptSaveService CLI bridge"`

---

### Task 11: Swift — audio capture (mic + system-audio process tap) + entitlements

**Files:**
- Create: `WatchtowerDesktop/Sources/Services/Transcription/AudioRecording.swift` (protocol)
- Create: `WatchtowerDesktop/Sources/Services/Transcription/SystemAudioRecorder.swift`
- Modify: `scripts/build-app.sh` (Info.plist heredoc ~line 96: add usage descriptions; entitlements already applied at lines 160-174)
- Modify: `scripts/Watchtower.entitlements` (add `com.apple.security.device.audio-input`)

**Interfaces:**
- Produces (used by Tasks 12, 13):

```swift
struct RecordingResult: Equatable {
    let audioURL: URL
    let durationSec: Int
}
protocol AudioRecording: AnyObject {
    /// Throws immediately on permission denial or unsupported OS.
    func start(to url: URL) async throws
    /// Finalizes the file; always safe to call once after start.
    func stop() async throws -> RecordingResult
}
enum AudioRecordingError: LocalizedError {
    case unsupportedOS            // < macOS 14.4
    case microphonePermissionDenied
    case systemAudioPermissionDenied
    case deviceSetupFailed(String)
}
```

**Implementation shape for `SystemAudioRecorder: AudioRecording`** (this is the riskiest task; the API pattern follows Apple's CoreAudio process-tap API — the same approach as the open-source AudioCap reference. Expect iteration; keep everything else decoupled behind `AudioRecording`):

1. `@available(macOS 14.4, *)` gate; on older OS `start` throws `.unsupportedOS`.
2. Mic permission: `AVCaptureDevice.requestAccess(for: .audio)` → denied ⇒ `.microphonePermissionDenied`.
3. System-audio tap: `CATapDescription(stereoGlobalTapButExcludeProcesses: [])`, `.muteBehavior = .unmuted`, `AudioHardwareCreateProcessTap(desc, &tapID)` (first call triggers the System Audio Recording TCC prompt; OSStatus failure after denial ⇒ `.systemAudioPermissionDenied`).
4. Private aggregate device combining default input device (mic) + the tap, so ONE IOProc delivers both streams already clock-aligned:
   `AudioHardwareCreateAggregateDevice([kAudioAggregateDeviceNameKey: "Watchtower Recorder", kAudioAggregateDeviceUIDKey: UUID().uuidString, kAudioAggregateDeviceIsPrivateKey: true, kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: <default-input-UID>]], kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapDesc.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]]] as CFDictionary, &aggID)`.
5. `AudioDeviceCreateIOProcIDWithBlock` on the aggregate: per callback, mix to mono — `0.5*tapL + 0.5*tapR + 0.9*mic`, then soft-clip `tanh`-style limiter (ports record.sh's clipping lessons: mic weighted 0.9, hard ceiling, NO auto-leveling).
6. Downsample to 16 kHz via `AVAudioConverter` and append to `AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32000], commonFormat: .pcmFormatFloat32, interleaved: false)`.
7. `stop()`: destroy IOProc → destroy aggregate → destroy tap (reverse order), close file, compute duration from frames written. Deinit safety-net does the same teardown.

Info.plist additions in `build-app.sh` heredoc:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>Watchtower records your side of meetings to transcribe them locally.</string>
<key>NSAudioCaptureUsageDescription</key>
<string>Watchtower records meeting audio (other participants) to transcribe it locally. Audio never leaves this Mac.</string>
```

Entitlements addition: `<key>com.apple.security.device.audio-input</key><true/>`.

- [ ] **Step 1: Write the protocol + error enum** (no test — pure declarations) and a compile-only stub of `SystemAudioRecorder`.
- [ ] **Step 2: Implement the recorder** per the shape above. `swift build > /tmp/t11.log 2>&1; echo "exit=$?"` → exit=0.
- [ ] **Step 3: Update `build-app.sh` + entitlements.**
- [ ] **Step 4: MANUAL verification (required — no unit tests can cover CoreAudio/TCC):**
  1. `make app-dev`, launch the bundled app.
  2. First recording start → exactly two TCC prompts (Microphone, System Audio Recording); grant both.
  3. Record 30 s while playing a YouTube video in headphones and speaking; stop.
  4. Open the produced `.m4a` in QuickTime: BOTH the video audio and your voice are audible; headphones kept playing normally throughout (no output-device switch).
  5. Kill the app mid-recording; confirm the partial `.m4a` file exists and is playable.
  Record the checklist results in the commit message.
- [ ] **Step 5: Commit** — `git commit -m "feat(desktop): native mic+system-audio capture via CoreAudio process tap"`

---

### Task 12: Swift — WhisperKit engine adapter + audio file decoding

**Files:**
- Create: `WatchtowerDesktop/Sources/Services/Transcription/WhisperKitEngine.swift`
- Create: `WatchtowerDesktop/Sources/Services/Transcription/AudioFileDecoder.swift`

**Interfaces:**
- Consumes: `TranscriptionEngine` (Task 9), WhisperKit (Task 8).
- Produces (used by Task 13):

```swift
/// Loads/holds one WhisperKit model instance and adapts it to TranscriptionEngine.
final class WhisperKitEngine: TranscriptionEngine {
    /// modelName e.g. "large-v3"; downloadProgress reports 0…1 during first-run model download.
    static func load(modelName: String, downloadProgress: @escaping @Sendable (Double) -> Void) async throws -> WhisperKitEngine
    func detectLanguage(_ samples: [Float]) async throws -> [String: Float]
    func transcribeWindow(_ samples: [Float], language: String) async throws -> String
}
enum AudioFileDecoder {
    /// Decode any AVFoundation-readable file to 16 kHz mono Float32 samples.
    static func decodePCM16k(url: URL) throws -> [Float]
}
```

- [ ] **Step 1: Implement `AudioFileDecoder`** with `AVAudioFile(forReading:)` + `AVAudioConverter` to `AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)`.
- [ ] **Step 2: Implement `WhisperKitEngine`.** `load`: `WhisperKit(WhisperKitConfig(model: modelName, ...))` — pass a download progress callback (WhisperKit exposes model download progress; wire what the pinned version offers, otherwise report 0/1 around init). `detectLanguage`: WhisperKit's language-detection API over the window samples (`detectLanguage(audioArray:)` in current WhisperKit — returns language + probabilities; adapt to `[String: Float]`). `transcribeWindow`: `transcribe(audioArray:decodeOptions: DecodingOptions(language: language, detectLanguage: false, ...))` → join segment texts. **Note:** exact WhisperKit API names must be verified against the pinned version's docs at implementation time; the adapter exists precisely to contain that churn.
- [ ] **Step 3: Build** — `swift build > /tmp/t12.log 2>&1; echo "exit=$?"` → exit=0. (No unit tests — CoreML model; covered by Task 15 manual acceptance.)
- [ ] **Step 4: Manual smoke:** temporary debug hook (delete after): decode the Task 11 test recording, run WhisperKitEngine through WindowedTranscriber, print output — verify real ru/en text appears and langStats is sane.
- [ ] **Step 5: Commit** — `git commit -m "feat(desktop): WhisperKit engine adapter + 16k PCM decoder"`

---

### Task 13: Swift — `MeetingRecorderCenter` (state machine on AppState)

**Files:**
- Create: `WatchtowerDesktop/Sources/Services/MeetingRecorderCenter.swift`
- Modify: `WatchtowerDesktop/Sources/Services/NotificationService.swift` (two new methods)
- Modify: `WatchtowerDesktop/Sources/App/AppState.swift` (add `let meetingRecorderCenter = MeetingRecorderCenter()` next to `targetExtractCenter` line 33)
- Create: `WatchtowerDesktop/Tests/MeetingRecorderCenterTests.swift`

**Interfaces:**
- Consumes: `AudioRecording` (Task 11), `TranscriptionEngine`+`WindowedTranscriber` (Task 9), `TranscriptSaveService` (Task 10), `AudioFileDecoder` (Task 12).
- Produces (used by Task 14):

```swift
protocol MeetingTranscriptNotifying {
    func sendTranscriptReadyNotification(title: String)
    func sendTranscriptFailedNotification(reason: String)
}
extension NotificationService: MeetingTranscriptNotifying {} // impls added in NotificationService.swift

@MainActor @Observable final class MeetingRecorderCenter {
    enum Phase: Equatable {
        case idle
        case recording(startedAt: Date)
        case transcribing(done: Int, total: Int)
        case summarizing
        case failed(String)
    }
    private(set) var phase: Phase = .idle
    private(set) var currentEventID: String?   // nil = ad-hoc
    private(set) var currentTitle: String?
    /// Audio file awaiting (re-)transcription after a failure or relaunch.
    private(set) var pendingAudioURL: URL?
    var isBusy: Bool { if case .idle = phase { return false }; if case .failed = phase { return false }; return true }

    // Injected seams (defaults are the production impls); engineFactory is async
    // because model load/download happens lazily on first stop.
    init(recorderFactory: @escaping () -> AudioRecording = { SystemAudioRecorder() },
         engineFactory: @escaping (TranscriptionConfig) async throws -> TranscriptionEngine = /* WhisperKitEngine.load via settings */,
         notifier: MeetingTranscriptNotifying = NotificationService.shared)

    func startRecording(eventID: String?, title: String?) async     // no-op guard when isBusy
    func stopAndProcess(runner: CLIRunnerProtocol, config: TranscriptionConfig) async
    func retryTranscription(runner: CLIRunnerProtocol, config: TranscriptionConfig) async // re-runs from pendingAudioURL
    /// Point the Center at an existing audio file (re-transcribe from the UI),
    /// then call retryTranscription. No-op guard when isBusy.
    func prepareRetry(audioURL: URL, eventID: String?, title: String?)
    func dismissFailure()                                           // failed → idle (keeps pendingAudioURL)
    func restorePendingOnLaunch()                                   // reads UserDefaults "recorder.pendingAudioPath"
}
```

Behavior contract:
- `startRecording`: guard `isBusy` → return. Creates recordings dir (`~/Library/Application Support/Watchtower/recordings`), file `rec_yyyyMMdd_HHmmss.m4a`, persists path to UserDefaults key `recorder.pendingAudioPath`, `recorder.start(to:)`. Start failure → `.failed(message)` + failed notification.
- `stopAndProcess`: `recorder.stop()` → `.transcribing(0, ?)`; decode → `WindowedTranscriber` with progress → empty text ⇒ `.failed("No speech recognized")` (audio + pendingAudioURL kept). Non-empty → `.summarizing` → `TranscriptSaveService.save(...)`. Save success: clear UserDefaults key + `pendingAudioURL`, `.idle`, ready notification (recapError non-empty ⇒ still ready notification — transcript saved — but message mentions recap needs retry). Save throw → `.failed`, audio kept.
- Every failure path keeps the audio file on disk and `pendingAudioURL` set; `retryTranscription` re-enters at the decode step.
- `restorePendingOnLaunch`: if the UserDefaults path exists on disk → set `pendingAudioURL` (UI offers "Transcribe recovered recording"); if file gone → clear key.

- [ ] **Step 1: Write failing tests** (`@MainActor final class MeetingRecorderCenterTests: XCTestCase`, fakes: `FakeRecorder: AudioRecording` (scriptable success/throw), `MockEngine` from Task 9, `FakeCLIRunner`, `FakeNotifier: MeetingTranscriptNotifying`):

```swift
func testStartWhileBusyIsANoOp()                    // phase .recording → startRecording again → recorder.startCalls == 1
func testHappyPathPhaseSequence()                   // idle→recording→(stop)→transcribing→summarizing→idle; ready notification; UserDefaults key cleared
func testStateSurvivesViewLifetime()                // MANDATORY navigate-away analog: start; assert center (not any view) holds phase;
                                                    // simulate "view gone" by releasing a local reference that observed it;
                                                    // stopAndProcess still completes and phase reaches .idle
func testRecorderStartFailureGoesFailed()           // .failed + failed notification, not stuck busy
func testEmptyTranscriptFailsButKeepsAudio()        // engine returns all-silence → .failed("No speech…"), pendingAudioURL != nil, file still on disk
func testSaveFailureKeepsAudioAndAllowsRetry()      // FakeCLIRunner throws → .failed; then retryTranscription with working runner → .idle, key cleared
func testRecapErrorStillCompletes()                 // envelope recap_ok=false → .idle + ready notification (message contains "recap")
func testRestorePendingOnLaunch()                   // UserDefaults set + file exists → pendingAudioURL set; file missing → key cleared
func testProgressReported()                         // transcribing(done:total:) updates flow through
```

(For UserDefaults use a suite-isolated `UserDefaults(suiteName:)` injected via init parameter with default `.standard` — add that parameter.)

- [ ] **Step 2: Verify failure** — `swift test --filter MeetingRecorderCenter > /tmp/t13.log 2>&1; echo "exit=$?"` → exit=1.
- [ ] **Step 3: Implement Center + the two NotificationService methods** (`sendTranscriptReadyNotification(title:)`, `sendTranscriptFailedNotification(reason:)` — FNV-1a identifier pattern like `sendTargetExtractReadyNotification`). Add to AppState.
- [ ] **Step 4: Run full Swift suite** — `swift test > /tmp/t13b.log 2>&1; echo "exit=$?"` → exit=0.
- [ ] **Step 5: Commit** — `git commit -m "feat(desktop): MeetingRecorderCenter — recording state machine surviving navigation"`

---

### Task 14: Swift — UI (record button, global indicator, transcript section, ad-hoc, settings)

**Files:**
- Modify: `WatchtowerDesktop/Sources/Views/Calendar/CalendarEventsView.swift` (record button in `eventRow`; header "Record" ad-hoc button; recordings section)
- Modify: `WatchtowerDesktop/Sources/Views/Calendar/MeetingNotesView.swift` (transcript section under `recapSection`)
- Create: `WatchtowerDesktop/Sources/Views/Calendar/TranscriptSectionView.swift`
- Create: `WatchtowerDesktop/Sources/Views/Calendar/RecordingIndicatorView.swift`
- Create: `WatchtowerDesktop/Sources/Views/Calendar/LinkTranscriptSheet.swift`
- Modify: `WatchtowerDesktop/Sources/App/WatchtowerApp.swift` (`.overlay(alignment: .bottomTrailing) { RecordingIndicatorView() }` on the WindowGroup content, next to `.environment(appState)` line ~70)
- Modify: `WatchtowerDesktop/Sources/Views/Settings/SettingsView.swift` + `GeneralSettings` (transcription settings section)
- Create: `WatchtowerDesktop/Tests/TranscriptionSettingsTests.swift` (config mapping only, if logic warrants; UI itself is manually verified)

**Interfaces:**
- Consumes: `appState.meetingRecorderCenter` (Task 13), `MeetingTranscriptQueries` (Task 8), `TranscriptSaveService.retryRecap` (Task 10), `@AppStorage` settings keys (below).
- Produces: `TranscriptionConfig.fromDefaults()` — static factory reading `@AppStorage`-backed UserDefaults keys:
  `transcription.model` ("large-v3"), `transcription.langset` ("ru,uk,en"), `transcription.windowSec` (20), `transcription.langThreshold` (0.6), `transcription.margin` (0.2), `transcription.forceLang` ("").

UI pieces (concise specs; match existing visual idioms — `.buttonStyle(.bordered).controlSize(.small)`, `Label(_, systemImage:)`):

1. **Record button** in `CalendarEventsView.eventRow`: `Label("Record", systemImage: "record.circle")`; disabled when `center.isBusy` or `!SystemAudioRecorder.isSupported` (add `static var isSupported: Bool { if #available(macOS 14.4, *) { true } else { false } }` with `.help("Recording requires macOS 14.4+")`); tap → `Task { await center.startRecording(eventID: event.id, title: event.title) }`. When this event is being recorded, the button becomes "Stop" → `center.stopAndProcess(runner:config:)` with `ProcessCLIRunner.makeDefault()` + `TranscriptionConfig.fromDefaults()`.
2. **Header ad-hoc button** in `CalendarEventsView` header: same, `eventID: nil`.
3. **`RecordingIndicatorView`** (global overlay): visible when `center.phase != .idle`; shows phase-appropriate content — red dot + elapsed timer (`TimelineView`) + Stop for `.recording`; progress "Transcribing 3/12" for `.transcribing`; spinner "Summarizing…" for `.summarizing`; error text + Retry/Dismiss for `.failed`; also a "Transcribe recovered recording" pill when `pendingAudioURL != nil && phase == .idle`. Materials-style capsule, bottom-trailing padding 16.
4. **`TranscriptSectionView(eventID:)`** embedded in `MeetingNotesView` below `recapSection`: fetches `MeetingTranscriptQueries.fetchForEvent`; per transcript a `DisclosureGroup` — duration, created date, lang stats badges, scrollable transcript text (`.textSelection(.enabled)`, `.frame(maxHeight: 300)`); "Retry recap" button when event has no recap; "Re-transcribe" button when `audioPath != nil` (→ `center.retryTranscription` after setting the pending URL — expose a `func prepareRetry(audioURL: URL, eventID: String?, title: String?)` on the Center for this). Reload via the same `loadNotes()`-style refetch on appear + after actions.
5. **Recordings section** in `CalendarEventsView` (below the events list): `MeetingTranscriptQueries.fetchAdHoc` rows — title, date, duration, summary line if parsed; "Link to event…" button → `LinkTranscriptSheet`.
6. **`LinkTranscriptSheet(transcript:)`**: picker listing calendar events of the transcript's `createdAt` day (reuse `CalendarQueries` day fetch); confirm → `dbPool.write { MeetingTranscriptQueries.linkToEvent(...) }` → dismiss.
7. **Settings** (`GeneralSettings` form, new "Transcription" section): model picker (`large-v3`, `distil-large-v3`, `medium`), langset text field, retention-days stepper bound to `ConfigService` new property `transcriptAudioRetentionDays` (YAML `transcripts.audio_retention_days` — add parse in `reload()` / write in `save()` following the calendar block pattern); advanced disclosure with window/threshold/margin/force-language fields (`@AppStorage` keys above).

- [ ] **Step 1: Implement `TranscriptionConfig.fromDefaults()` + ConfigService property**, with a small test for the ConfigService YAML round-trip (follow existing ConfigService tests if present).
- [ ] **Step 2: Implement views 1–7.** Build: `swift build > /tmp/t14.log 2>&1; echo "exit=$?"` → exit=0; run full `swift test` → exit=0.
- [ ] **Step 3: MANUAL UI verification** (`make app-dev`):
  - Record from an event card → indicator visible from Dashboard tab (navigate away and back — state intact); stop → progress → notification → recap appears via existing recap UI + transcript section shows text.
  - Ad-hoc record → appears in Recordings section → link to an event → recap copied, transcript now under the event.
  - Fail path: stop a silent recording → failed pill → Retry works.
- [ ] **Step 4: Commit** — `git commit -m "feat(desktop): recording UI — event/ad-hoc record, global indicator, transcript section, settings"`

---

### Task 15: Docs + final verification

**Files:**
- Modify: `docs/app-guide.md` (new "Meeting recording & transcripts" section — the guide is injected into the chat-bot system prompt and MUST reflect UI changes: how to record from calendar/ad-hoc, where transcripts live, retention behavior, the two TCC permissions, MCP tools `list_transcripts`/`get_transcript`)
- Modify: `CLAUDE.md` (short Feature Notes entry: meeting transcriber — Swift capture/WhisperKit + `meeting_transcripts` + `meeting-prep transcript` CLI + retention phase; pointer to the spec)

- [ ] **Step 1: Write both doc updates.**
- [ ] **Step 2: Full verification gate:**

```bash
go test ./... > /tmp/final-go.log 2>&1; echo "go-exit=$?"
go vet ./... > /tmp/final-vet.log 2>&1; echo "vet-exit=$?"
go build ./... && echo "build-ok"
cd WatchtowerDesktop && swift build > /tmp/final-swift-build.log 2>&1; echo "sb-exit=$?"
swift test > /tmp/final-swift-test.log 2>&1; echo "st-exit=$?"
```

All exit codes 0.

- [ ] **Step 3: End-to-end manual acceptance (from the spec §9):**
  - Real Meet call with headphones → both sides in transcript, headphones uninterrupted.
  - Mixed ru/uk/en call → no суржик collapse, lang_stats plausible.
  - Recap on the event via existing recap UI.
  - Kill app mid-recording → relaunch offers recovered recording → transcribes.
  - `watchtower meeting-prep transcript list` shows rows; secretary chat answers a "what did we decide on the meeting" question via MCP.
- [ ] **Step 4: Commit** — `git commit -m "docs: app-guide + CLAUDE.md for meeting transcriber"`
- [ ] **Step 5: Run the local-review skill** over the branch before opening the PR (per repo process).
