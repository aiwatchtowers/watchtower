# Recordings Tab + Recording Single-View Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A "Записи" (Recordings) tab inside the Calendar screen with a fast master-detail single-view per recording (Recap / Meeting notes / Transcript / Chat tabs), publishable AI meeting notes, and full delete.

**Architecture:** Go owns the new `notes_md` column, the `meeting.notes` AI prompt, and the `transcript notes <id>` CLI subcommand (mirroring the recap path). Swift owns the UI: a lightweight `RecordingListItem` GRDB projection for the master list, a `RecordingDetailView` with four lazy tabs, a `TranscriptNotesCenter` on AppState so notes generation survives navigation, a `MeetingChatViewModel` on the existing `chat_conversations` context pattern (`context_type = "meeting"`), and a Swift-side transactional delete.

**Tech Stack:** Go 1.25 + goose migrations + cobra + `digest.Generator` (claude/codex); Swift 5.10 SwiftUI + GRDB, XCTest + ViewInspector.

**Spec:** `docs/superpowers/specs/2026-07-15-recordings-tab-design.md`

## Global Constraints

- All GitHub-facing text (commit messages, PR) in English.
- Every AI call goes through `digest.Generator` and must work on BOTH claude and codex providers; never shell out directly.
- `meeting.notes` is quality-critical → default strong tier (Sonnet / gpt-5.4): do NOT add it to `ModelForSource` switches.
- Editing a shipped prompt template later requires bumping `DefaultVersions`.
- New table/column must be mirrored into `internal/db/schema.sql` and the golden snapshot regenerated (`go test ./internal/db/ -run TestSchemaGolden -update`).
- `meeting_recaps` rows are NEVER deleted by transcript delete (spec: safe delete scope).
- Recordings list queries must NEVER select `transcript_text` (only a `substr` snippet) or decode `summary_json` per row.
- Swift verification commands: capture the real exit code — redirect to a log file and check `$?`; do not pipe through `tail`.
- Run all commands from the worktree root `/Users/user/PhpstormProjects/watchtower/.claude/worktrees/pluggable-transcription-engines` (do not `cd` to the main checkout). Swift commands run in `WatchtowerDesktop/`.
- Existing prep-pane UI (`MeetingPrepDetailView` / `MeetingNotesView` / `TranscriptSectionView`) stays functional — the detail screen duplicates recap actions, it does not remove them from the prep pane.

---

### Task 1: Migration 00017 — `notes_md` column

**Files:**
- Create: `internal/db/migrations/00017_meeting_transcript_notes.sql`
- Modify: `internal/db/schema.sql` (the `CREATE TABLE meeting_transcripts` block, around line 1013)
- Modify: `internal/db/testdata/*.golden` (regenerated)

**Interfaces:**
- Consumes: existing `meeting_transcripts` table (migration 00016).
- Produces: nullable `meeting_transcripts.notes_md TEXT` column (NULL = notes never generated). All later tasks rely on this exact column name.

- [ ] **Step 1: Write the migration file**

`internal/db/migrations/00017_meeting_transcript_notes.sql`:

```sql
-- +goose Up
-- Publishable meeting notes (markdown) for a recording. NULL = never
-- generated. Written by `watchtower meeting-prep transcript notes <id>` (AI)
-- and edited directly by the Desktop app (GRDB) — unlike summary_json, which
-- only the CLI writes.
ALTER TABLE meeting_transcripts ADD COLUMN notes_md TEXT;

-- +goose Down
ALTER TABLE meeting_transcripts DROP COLUMN notes_md;
```

- [ ] **Step 2: Mirror into `internal/db/schema.sql`**

In the `CREATE TABLE meeting_transcripts` block, add after `summary_json    TEXT,`:

```sql
    notes_md        TEXT,
```

- [ ] **Step 3: Regenerate the schema golden snapshot**

Run: `go test ./internal/db/ -run TestSchemaGolden -update`
Expected: PASS (snapshot rewritten).

- [ ] **Step 4: Verify migration tests**

Run: `go test ./internal/db/ -run 'TestMigrationIdempotent|TestAllTablesExist|TestSchemaGolden'`
Expected: PASS (column add only — no new table, `TestAllTablesExist` unchanged).

- [ ] **Step 5: Commit**

```bash
git add internal/db/migrations/00017_meeting_transcript_notes.sql internal/db/schema.sql internal/db/testdata/
git commit -m "feat(db): add meeting_transcripts.notes_md for publishable meeting notes"
```

---

### Task 2: Go DB layer — `NotesMD` + `SetMeetingTranscriptNotes`

**Files:**
- Modify: `internal/db/meeting_transcripts.go`
- Test: `internal/db/meeting_transcripts_test.go` (existing file; add cases — if the file does not exist, create it following `internal/db/` test style with `testDB(t)` helpers used by neighboring tests; check `grep -rn "func TestInsertMeetingTranscript\|SetMeetingTranscriptSummary" internal/db/*_test.go` first and put the new test next to the existing transcript tests)

**Interfaces:**
- Consumes: `notes_md` column from Task 1.
- Produces: `MeetingTranscript.NotesMD sql.NullString` field; `func (db *DB) SetMeetingTranscriptNotes(id int64, notesMD string) error`. Task 5 (CLI) uses both.

- [ ] **Step 1: Write the failing test**

Locate the existing transcript DB tests (`grep -rn "SetMeetingTranscriptSummary" internal/db/ --include='*_test.go'`) and add alongside, using the same DB-fixture helper the neighboring tests use:

```go
func TestSetMeetingTranscriptNotes(t *testing.T) {
	database := testDB(t) // use the same fixture helper as the surrounding transcript tests

	id, err := database.InsertMeetingTranscript(MeetingTranscript{
		Title:          "Notes target",
		TranscriptText: "we talked",
	})
	if err != nil {
		t.Fatalf("insert: %v", err)
	}

	if err := database.SetMeetingTranscriptNotes(id, "# Notes\n- decided X"); err != nil {
		t.Fatalf("SetMeetingTranscriptNotes: %v", err)
	}

	tr, err := database.GetMeetingTranscript(id)
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if !tr.NotesMD.Valid || tr.NotesMD.String != "# Notes\n- decided X" {
		t.Fatalf("notes_md not stored, got %+v", tr.NotesMD)
	}
	if tr.UpdatedAt < tr.CreatedAt {
		t.Fatalf("updated_at must be bumped")
	}

	// Fresh rows have no notes.
	id2, _ := database.InsertMeetingTranscript(MeetingTranscript{Title: "No notes", TranscriptText: "x"})
	tr2, _ := database.GetMeetingTranscript(id2)
	if tr2.NotesMD.Valid {
		t.Fatalf("fresh transcript must have NULL notes_md")
	}
}
```

(Adapt the fixture call — `testDB(t)` — to whatever helper the existing transcript tests in that file actually use; do not invent a new one.)

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/db/ -run TestSetMeetingTranscriptNotes`
Expected: FAIL — `tr.NotesMD undefined` (compile error).

- [ ] **Step 3: Implement**

In `internal/db/meeting_transcripts.go`:

1. Add field to the struct after `SummaryJSON`:
```go
	NotesMD        sql.NullString
```
2. Extend the column list and scanner:
```go
const meetingTranscriptColumns = `id, event_id, title, audio_path, duration_sec, lang_stats, transcript_text, summary_json, notes_md, created_at, updated_at`

func scanMeetingTranscript(row interface{ Scan(...any) error }) (MeetingTranscript, error) {
	var t MeetingTranscript
	err := row.Scan(&t.ID, &t.EventID, &t.Title, &t.AudioPath, &t.DurationSec,
		&t.LangStats, &t.TranscriptText, &t.SummaryJSON, &t.NotesMD, &t.CreatedAt, &t.UpdatedAt)
	return t, err
}
```
3. Add after `SetMeetingTranscriptSummary`:
```go
// SetMeetingTranscriptNotes stores the publishable markdown notes for a
// transcript and bumps updated_at.
func (db *DB) SetMeetingTranscriptNotes(id int64, notesMD string) error {
	_, err := db.Exec(`
		UPDATE meeting_transcripts
		SET notes_md = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
		WHERE id = ?
	`, notesMD, id)
	if err != nil {
		return fmt.Errorf("setting meeting transcript %d notes: %w", id, err)
	}
	return nil
}
```

- [ ] **Step 4: Run tests**

Run: `go test ./internal/db/`
Expected: PASS (including all existing transcript tests — the scanner change touches every read path).

- [ ] **Step 5: Commit**

```bash
git add internal/db/meeting_transcripts.go internal/db/*_test.go
git commit -m "feat(db): NotesMD field + SetMeetingTranscriptNotes"
```

---

### Task 3: Prompt `meeting.notes`

**Files:**
- Modify: `internal/prompts/store.go` (ID constants block, line ~34)
- Modify: `internal/prompts/defaults.go` (`Defaults` map, `AllIDs`, `DefaultVersions`, template const)

**Interfaces:**
- Consumes: nothing new.
- Produces: `prompts.MeetingNotes = "meeting.notes"` constant + `defaultMeetingNotes` template with **7 `%s` verbs** in this order: title, startTime, endTime, attendees, description, recap block, language directive. Task 4 formats it with exactly these args.

- [ ] **Step 1: Add the ID constant**

In `internal/prompts/store.go` after `MeetingRecap         = "meeting.recap"`:

```go
	MeetingNotes         = "meeting.notes"
```

- [ ] **Step 2: Add the template + registrations in `internal/prompts/defaults.go`**

In the `Defaults` map after `MeetingRecap: defaultMeetingRecap,`:
```go
	MeetingNotes:         defaultMeetingNotes,
```
In `AllIDs` after `MeetingRecap,`:
```go
	MeetingNotes,
```
In `DefaultVersions` after the `MeetingRecap` line:
```go
	MeetingNotes:       1, // v1: publishable markdown meeting notes from a transcript
```
Template const, placed right after `defaultMeetingRecap` (keep neighboring prompts together):

```go
const defaultMeetingNotes = `You write publishable meeting notes from an automatic single-track audio transcript (speakers are not labeled; the transcript may mix ru/uk/en and contain recognition noise — ignore obvious mis-transcriptions). The notes will be pasted into Slack or Confluence for people who were NOT at the meeting.

=== EVENT ===
Title: %s
Time:  %s — %s
Attendees: %s
Description: %s

=== EXISTING AI RECAP (may be empty) ===
%s

%s

Return ONLY a markdown document (no code fences, no commentary before or after) with this structure:

# <meeting title>

**Date:** <date if known, else omit the line>
**Participants:** <names if identifiable from the event attendees, else omit the line>

## Summary
1-3 sentences: what the meeting was about and its outcome.

## Decisions
- bullet per explicitly resolved item (omit the section if none)

## Action items
- bullet per commitment, imperative, with the owner when named (omit the section if none)

## Next steps / open questions
- bullet per unresolved item (omit the section if none)

Rules:
- Neutral, publication-ready tone; no first person, no meta-commentary.
- Be faithful to the transcript; never invent facts, owners, or dates.
- Merge near-duplicates; keep it scannable.`
```

- [ ] **Step 3: Verify the prompts package**

Run: `go test ./internal/prompts/`
Expected: PASS (defaults tests iterate `AllIDs`/`Defaults` consistency).

- [ ] **Step 4: Commit**

```bash
git add internal/prompts/store.go internal/prompts/defaults.go
git commit -m "feat(prompts): meeting.notes template for publishable meeting notes"
```

---

### Task 4: `internal/meeting` — `GenerateTranscriptNotes`

**Files:**
- Create: `internal/meeting/transcript_notes.go`
- Test: `internal/meeting/transcript_notes_test.go`

**Interfaces:**
- Consumes: `prompts.MeetingNotes` + `defaultMeetingNotes` (Task 3); existing `Pipeline` (`p.db`, `p.cfg`, `p.generator`, `p.promptStore`), `prompts.Directive`.
- Produces: `func (p *Pipeline) GenerateTranscriptNotes(ctx context.Context, eventID, transcript string) (string, *digest.Usage, error)` — returns trimmed markdown. Task 5 (CLI) calls it. Transcript travels in the USER message (stdin path for >32 KB, same as `GenerateTranscriptRecap`).

- [ ] **Step 1: Write the failing test**

`internal/meeting/transcript_notes_test.go` (mirror `transcript_recap_test.go` style — check its mock generator setup and reuse the same helpers where they exist in the package):

```go
package meeting

import (
	"context"
	"strings"
	"testing"
)

type notesMockGen struct {
	response        string
	lastSystem      string
	lastUserMessage string
}

func (m *notesMockGen) Generate(_ context.Context, systemPrompt, userMessage, _ string) (string, *digestUsageAlias, string, error) {
	m.lastSystem = systemPrompt
	m.lastUserMessage = userMessage
	return m.response, nil, "", nil
}

// NOTE: digestUsageAlias is illustrative — use the exact mock-generator shape
// already present in transcript_recap_test.go / pipeline_test.go in this
// package (they implement digest.Generator directly with *digest.Usage).

func TestGenerateTranscriptNotesEmptyTranscriptFails(t *testing.T) {
	p := New(nil, nil, &notesMockGen{response: "# Notes"}, nil)
	_, _, err := p.GenerateTranscriptNotes(context.Background(), "", "   ")
	if err == nil || !strings.Contains(err.Error(), "empty") {
		t.Fatalf("expected empty-transcript error, got %v", err)
	}
}

func TestGenerateTranscriptNotesTranscriptInUserMessage(t *testing.T) {
	gen := &notesMockGen{response: "# Weekly Sync\n\n## Summary\nShipped."}
	p := New(nil, nil, gen, nil)

	out, _, err := p.GenerateTranscriptNotes(context.Background(), "", "we agreed to ship v2")
	if err != nil {
		t.Fatalf("GenerateTranscriptNotes: %v", err)
	}
	if out != "# Weekly Sync\n\n## Summary\nShipped." {
		t.Fatalf("unexpected notes output: %q", out)
	}
	if !strings.Contains(gen.lastUserMessage, "we agreed to ship v2") {
		t.Fatalf("transcript must travel in the user message (stdin path), got %q", gen.lastUserMessage)
	}
	if strings.Contains(gen.lastSystem, "we agreed to ship v2") {
		t.Fatalf("transcript must NOT be embedded in the system prompt")
	}
}

func TestGenerateTranscriptNotesStripsCodeFence(t *testing.T) {
	gen := &notesMockGen{response: "```markdown\n# Notes\nbody\n```"}
	p := New(nil, nil, gen, nil)

	out, _, err := p.GenerateTranscriptNotes(context.Background(), "", "talk talk")
	if err != nil {
		t.Fatalf("GenerateTranscriptNotes: %v", err)
	}
	if out != "# Notes\nbody" {
		t.Fatalf("fence must be stripped, got %q", out)
	}
}
```

Adapt the mock to the exact `digest.Generator` signature used by `transcriptMockGen`-style mocks in this package (`Generate(ctx, system, user, session) (string, *digest.Usage, string, error)`).

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/meeting/ -run TestGenerateTranscriptNotes`
Expected: FAIL — `p.GenerateTranscriptNotes undefined`.

- [ ] **Step 3: Implement `internal/meeting/transcript_notes.go`**

```go
package meeting

import (
	"context"
	"fmt"
	"strings"

	"watchtower/internal/digest"
	"watchtower/internal/prompts"
)

// GenerateTranscriptNotes produces publishable markdown meeting notes from a
// full meeting transcript. Like GenerateTranscriptRecap, the transcript
// travels in the USER message so the generators' stdin path keeps hour-long
// transcripts clear of ARG_MAX. eventID may be "" for ad-hoc recordings.
// The pipeline does NOT persist — the CLI caller writes notes_md.
func (p *Pipeline) GenerateTranscriptNotes(ctx context.Context, eventID, transcript string) (string, *digest.Usage, error) {
	trimmed := strings.TrimSpace(transcript)
	if trimmed == "" {
		return "", nil, fmt.Errorf("transcript is empty")
	}

	title, startTime, endTime, attendees, description := "(ad-hoc recording)", "", "", "", ""
	recapBlock := "(none)"
	if eventID != "" && p.db != nil {
		if ev, err := p.db.GetCalendarEventByID(eventID); err == nil && ev != nil {
			title, startTime, endTime = ev.Title, ev.StartTime, ev.EndTime
			attendees, description = ev.Attendees, ev.Description
		}
		if recap, err := p.db.GetMeetingRecap(eventID); err == nil && recap != nil {
			recapBlock = recap.RecapJSON
		}
	}

	lang := ""
	if p.cfg != nil {
		lang = p.cfg.Digest.Language
	}

	tmpl := p.loadNotesPrompt()
	systemPrompt := fmt.Sprintf(tmpl,
		title, startTime, endTime, attendees, description,
		recapBlock,
		prompts.Directive(lang),
	)
	userMessage := "Below is the full single-track meeting transcript (speakers are not labeled). " +
		"Generate the meeting-notes markdown exactly per the system prompt.\n\n=== TRANSCRIPT ===\n" + trimmed

	aiResponse, usage, _, err := p.generator.Generate(ctx, systemPrompt, userMessage, "")
	if err != nil {
		return "", nil, fmt.Errorf("AI generation: %w", err)
	}
	notes := stripMarkdownFence(aiResponse)
	if notes == "" {
		return "", nil, fmt.Errorf("AI returned empty notes")
	}
	return notes, usage, nil
}

// stripMarkdownFence removes a single wrapping ```/```markdown code fence if
// the model added one despite instructions, and trims whitespace.
func stripMarkdownFence(s string) string {
	out := strings.TrimSpace(s)
	if !strings.HasPrefix(out, "```") {
		return out
	}
	lines := strings.Split(out, "\n")
	if len(lines) < 2 {
		return out
	}
	// Drop the opening fence line (``` or ```markdown) and a trailing fence.
	lines = lines[1:]
	if strings.TrimSpace(lines[len(lines)-1]) == "```" {
		lines = lines[:len(lines)-1]
	}
	return strings.TrimSpace(strings.Join(lines, "\n"))
}

func (p *Pipeline) loadNotesPrompt() string {
	if p.promptStore != nil {
		if tmpl, _, err := p.promptStore.Get(prompts.MeetingNotes); err == nil && tmpl != "" {
			return tmpl
		}
	}
	if tmpl, ok := prompts.Defaults[prompts.MeetingNotes]; ok && tmpl != "" {
		return tmpl
	}
	return defaultNotesPromptFallback
}

const defaultNotesPromptFallback = `Write publishable markdown meeting notes. Event: %s (%s-%s, attendees: %s, description: %s). Recap: %s. %s
Return ONLY markdown.`
```

- [ ] **Step 4: Run tests**

Run: `go test ./internal/meeting/`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/meeting/transcript_notes.go internal/meeting/transcript_notes_test.go
git commit -m "feat(meeting): GenerateTranscriptNotes — publishable markdown notes from a transcript"
```

---

### Task 5: CLI `watchtower meeting-prep transcript notes <id>`

**Files:**
- Modify: `cmd/meeting_transcript.go`
- Test: `cmd/meeting_transcript_test.go`

**Interfaces:**
- Consumes: `GenerateTranscriptNotes` (Task 4), `SetMeetingTranscriptNotes` (Task 2), existing `transcriptEnv()`, `transcriptGeneratorFactory` seam, `prompts.New`.
- Produces: subcommand `notes <id>`; stdout envelope `{"transcript_id": N, "notes_md": "..."}` on success; **exit 1** on any failure (nothing partially persisted — notes are only written after successful generation). Task 9 (Swift service) decodes exactly this envelope.

- [ ] **Step 1: Write the failing tests** (append to `cmd/meeting_transcript_test.go`)

```go
func TestTranscriptNotesGeneratesAndStores(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	resetTranscriptFlags(t)
	stubTranscriptGenerator(t, &transcriptMockGen{response: "# Sync\n\n## Summary\nShipped v2."})

	database, err := openDBFromConfig()
	require.NoError(t, err)
	id, err := database.InsertMeetingTranscript(db.MeetingTranscript{
		Title:          "Sync",
		TranscriptText: "we shipped v2",
	})
	require.NoError(t, err)
	database.Close()

	var buf bytes.Buffer
	transcriptNotesCmd.SetOut(&buf)
	require.NoError(t, transcriptNotesCmd.RunE(transcriptNotesCmd, []string{fmt.Sprint(id)}))

	var env struct {
		TranscriptID int64  `json:"transcript_id"`
		NotesMD      string `json:"notes_md"`
	}
	require.NoError(t, json.Unmarshal(buf.Bytes(), &env))
	assert.Equal(t, id, env.TranscriptID)
	assert.Contains(t, env.NotesMD, "## Summary")

	database, err = openDBFromConfig()
	require.NoError(t, err)
	defer database.Close()
	tr, err := database.GetMeetingTranscript(id)
	require.NoError(t, err)
	require.True(t, tr.NotesMD.Valid, "notes_md must be persisted")
	assert.Equal(t, env.NotesMD, tr.NotesMD.String)

	run := findPipelineRun(t, database, "meeting_notes")
	require.NotNil(t, run, "a meeting_notes pipeline run must be recorded")
	assert.Equal(t, "done", run.Status)
}

func TestTranscriptNotesGenerationFailureExitsNonZeroAndStoresNothing(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	resetTranscriptFlags(t)
	stubTranscriptGenerator(t, &transcriptMockGen{err: errors.New("boom")})

	database, err := openDBFromConfig()
	require.NoError(t, err)
	id, err := database.InsertMeetingTranscript(db.MeetingTranscript{
		Title:          "Sync",
		TranscriptText: "we shipped v2",
	})
	require.NoError(t, err)
	database.Close()

	err = transcriptNotesCmd.RunE(transcriptNotesCmd, []string{fmt.Sprint(id)})
	require.Error(t, err, "notes failure must flip the exit code — nothing was persisted")
	assert.Contains(t, err.Error(), "boom")

	database, err = openDBFromConfig()
	require.NoError(t, err)
	defer database.Close()
	tr, err := database.GetMeetingTranscript(id)
	require.NoError(t, err)
	assert.False(t, tr.NotesMD.Valid, "failed generation must not write notes_md")

	run := findPipelineRun(t, database, "meeting_notes")
	require.NotNil(t, run)
	assert.Equal(t, "error", run.Status)
}

func TestTranscriptNotesUnknownIDFails(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	resetTranscriptFlags(t)
	stubTranscriptGenerator(t, &transcriptMockGen{response: "# n"})

	err := transcriptNotesCmd.RunE(transcriptNotesCmd, []string{"9999"})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "not found")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `go test ./cmd/ -run TestTranscriptNotes`
Expected: FAIL — `transcriptNotesCmd` undefined.

- [ ] **Step 3: Implement in `cmd/meeting_transcript.go`**

Add the command var next to the other transcript subcommands:

```go
var transcriptNotesCmd = &cobra.Command{
	Use:   "notes <id>",
	Short: "Generate publishable markdown meeting notes for a saved transcript",
	Long: "Runs the meeting.notes AI prompt over the transcript text and stores the result in meeting_transcripts.notes_md. " +
		"Prints {transcript_id, notes_md} on success; exits 1 on any failure (nothing is persisted on failure).",
	Args: cobra.ExactArgs(1),
	RunE: runTranscriptNotes,
}
```

Register it in `init()`:
```go
	meetingTranscriptCmd.AddCommand(transcriptSaveCmd, transcriptRecapCmd, transcriptListCmd, transcriptShowCmd, transcriptNotesCmd)
```

Add the runner (after `runTranscriptRecap`):

```go
func runTranscriptNotes(cmd *cobra.Command, args []string) error {
	id, err := strconv.ParseInt(args[0], 10, 64)
	if err != nil {
		return fmt.Errorf("invalid transcript id %q: %w", args[0], err)
	}

	cfg, database, err := transcriptEnv()
	if err != nil {
		return err
	}
	defer database.Close()

	tr, err := database.GetMeetingTranscript(id)
	if err != nil {
		return err
	}
	if tr == nil {
		return fmt.Errorf("transcript %d not found", id)
	}

	runID, err := database.CreatePipelineRun("meeting_notes", "cli", "auto")
	if err != nil {
		fmt.Fprintf(cmd.ErrOrStderr(), "warning: recording meeting_notes pipeline run: %v\n", err)
	}
	completeRun := func(items, in, out, api int, errMsg string) {
		if err := database.CompletePipelineRun(runID, items, in, out, 0, api, nil, nil, errMsg); err != nil {
			fmt.Fprintf(cmd.ErrOrStderr(), "warning: completing meeting_notes pipeline run %d: %v\n", runID, err)
		}
	}

	pipe := meeting.New(database, cfg, transcriptGeneratorFactory(cfg), nil)
	pipe.SetPromptStore(prompts.New(database, nil))

	eventID := ""
	if tr.EventID.Valid {
		eventID = tr.EventID.String
	}
	notes, usage, err := pipe.GenerateTranscriptNotes(cmd.Context(), eventID, tr.TranscriptText)
	if err != nil {
		completeRun(0, 0, 0, 0, err.Error())
		return err
	}
	if err := database.SetMeetingTranscriptNotes(id, notes); err != nil {
		completeRun(0, 0, 0, 0, err.Error())
		return err
	}

	in, out, api := 0, 0, 0
	if usage != nil {
		in, out, api = usage.InputTokens, usage.OutputTokens, usage.TotalAPITokens
	}
	completeRun(1, in, out, api, "")

	enc := json.NewEncoder(cmd.OutOrStdout())
	enc.SetIndent("", "  ")
	return enc.Encode(map[string]any{
		"transcript_id": id,
		"notes_md":      notes,
	})
}
```

- [ ] **Step 4: Run tests**

Run: `go test ./cmd/ -run TestTranscript`
Expected: PASS (new + all existing transcript CLI tests).

- [ ] **Step 5: Full Go verification**

Run: `go build ./... && go vet ./... && go test ./internal/db/ ./internal/meeting/ ./internal/prompts/ ./cmd/`
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add cmd/meeting_transcript.go cmd/meeting_transcript_test.go
git commit -m "feat(cli): meeting-prep transcript notes <id> subcommand"
```

---

### Task 6: Swift model + test schema — `notesMD`

**Files:**
- Modify: `WatchtowerDesktop/Sources/Models/MeetingTranscript.swift`
- Modify: `WatchtowerDesktop/Tests/Helpers/TestDatabase.swift` (schema block at line ~996 and `insertMeetingTranscript` helper at line ~1493)
- Test: `WatchtowerDesktop/Tests/MeetingTranscriptTests.swift` (existing; add one decode case)

**Interfaces:**
- Consumes: `notes_md` column (Task 1). **Known drift trap** (see memory `reference_tasks_targets`): `TestDatabase.swift` schema must be updated in the same commit as the model.
- Produces: `MeetingTranscript.notesMD: String?`; `TestDatabase.insertMeetingTranscript(..., notesMD: String? = nil)`. Tasks 7, 8, 11–15 rely on both.

- [ ] **Step 1: Update the test schema + helper**

In `TestDatabase.swift`, inside `CREATE TABLE IF NOT EXISTS meeting_transcripts`, add after `summary_json    TEXT,`:
```sql
        notes_md        TEXT,
```
Extend the insert helper:
```swift
    static func insertMeetingTranscript(
        _ db: Database,
        id: Int64? = nil,
        eventID: String? = nil,
        title: String = "Rec",
        audioPath: String? = nil,
        durationSec: Int = 60,
        transcriptText: String = "text",
        summaryJSON: String? = nil,
        notesMD: String? = nil
    ) throws {
        try db.execute(sql: """
            INSERT INTO meeting_transcripts (id, event_id, title, audio_path,
                duration_sec, transcript_text, summary_json, notes_md)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [id, eventID, title, audioPath, durationSec,
                        transcriptText, summaryJSON, notesMD])
    }
```

- [ ] **Step 2: Write the failing test** (add to `MeetingTranscriptTests.swift`)

```swift
    func test_notesMDRoundTrips() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertMeetingTranscript(
                db, id: 1, title: "With notes", notesMD: "# Notes\n- point")
            try TestDatabase.insertMeetingTranscript(db, id: 2, title: "Without notes")
        }
        try db.read { db in
            let withNotes = try XCTUnwrap(MeetingTranscriptQueries.fetch(db, id: 1))
            XCTAssertEqual(withNotes.notesMD, "# Notes\n- point")
            let without = try XCTUnwrap(MeetingTranscriptQueries.fetch(db, id: 2))
            XCTAssertNil(without.notesMD)
        }
    }
```

- [ ] **Step 3: Run test to verify it fails**

```bash
cd WatchtowerDesktop && swift test --filter MeetingTranscriptTests > /tmp/swift-test.log 2>&1; echo "exit=$?"
```
Expected: `exit=1` — `notesMD` not a member (compile error).

- [ ] **Step 4: Implement the model change**

In `MeetingTranscript.swift`: add `let notesMD: String?` after `summaryJSON`, and to `CodingKeys`:
```swift
        case notesMD = "notes_md"
```
Also update the doc comment: `notes_md` holds user-editable publishable markdown notes.

Note: `MeetingTranscript` is `Codable`+`PersistableRecord`; any code that constructs it memberwise (search `MeetingTranscript(` across Sources/Tests) must gain `notesMD: nil`.

- [ ] **Step 5: Run tests**

```bash
cd WatchtowerDesktop && swift test --filter 'MeetingTranscript' > /tmp/swift-test.log 2>&1; echo "exit=$?"
```
Expected: `exit=0`.

- [ ] **Step 6: Commit**

```bash
git add WatchtowerDesktop/Sources/Models/MeetingTranscript.swift WatchtowerDesktop/Tests/Helpers/TestDatabase.swift WatchtowerDesktop/Tests/MeetingTranscriptTests.swift
git commit -m "feat(desktop): notesMD on MeetingTranscript + test schema"
```

---

### Task 7: `RecordingListItem` projection + list query

**Files:**
- Create: `WatchtowerDesktop/Sources/Models/RecordingListItem.swift`
- Modify: `WatchtowerDesktop/Sources/Database/Queries/MeetingTranscriptQueries.swift`
- Test: `WatchtowerDesktop/Tests/MeetingTranscriptQueriesTests.swift`

**Interfaces:**
- Consumes: `meeting_transcripts` + `meeting_recaps` tables.
- Produces:
  ```swift
  struct RecordingListItem: Decodable, FetchableRecord, Identifiable, Equatable {
      let id: Int64; let eventID: String?; let title: String
      let durationSec: Int; let langStats: String; let createdAt: String
      let hasRecap: Bool; let hasNotes: Bool; let snippet: String
  }
  static func fetchRecordingList(_ db: Database, limit: Int = 200) throws -> [RecordingListItem]
  ```
  Used by Tasks 14–15. The query NEVER selects full `transcript_text`/`summary_json` (perf guard).

- [ ] **Step 1: Write the failing tests** (append to `MeetingTranscriptQueriesTests.swift`)

```swift
    func test_recordingListReturnsAllNewestFirstWithLightFields() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertCalendarEvent(db, id: "evt-1")
            try TestDatabase.insertMeetingTranscript(
                db, id: 1, eventID: "evt-1", title: "Linked",
                transcriptText: String(repeating: "x", count: 500))
            try TestDatabase.insertMeetingTranscript(
                db, id: 2, title: "AdHoc", transcriptText: "short",
                summaryJSON: self.summaryJSON, notesMD: "# n")
        }
        try db.read { db in
            let items = try MeetingTranscriptQueries.fetchRecordingList(db)
            XCTAssertEqual(items.map(\.id), [2, 1])
            XCTAssertEqual(items[0].title, "AdHoc")
            XCTAssertTrue(items[0].hasRecap, "summary_json counts as a recap")
            XCTAssertTrue(items[0].hasNotes)
            XCTAssertEqual(items[0].snippet, "short")
            XCTAssertFalse(items[1].hasRecap)
            XCTAssertFalse(items[1].hasNotes)
            XCTAssertEqual(items[1].snippet.count, 200, "snippet must be capped at 200 chars")
            XCTAssertEqual(items[1].eventID, "evt-1")
        }
    }

    func test_recordingListCountsEventRecapAsRecap() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertCalendarEvent(db, id: "evt-1")
            try TestDatabase.insertMeetingRecap(db, eventID: "evt-1", recapJSON: self.summaryJSON)
            try TestDatabase.insertMeetingTranscript(db, id: 1, eventID: "evt-1", title: "Linked")
        }
        try db.read { db in
            let items = try MeetingTranscriptQueries.fetchRecordingList(db)
            XCTAssertTrue(items[0].hasRecap, "meeting_recaps row for the linked event counts as a recap")
        }
    }
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd WatchtowerDesktop && swift test --filter MeetingTranscriptQueriesTests > /tmp/swift-test.log 2>&1; echo "exit=$?"
```
Expected: `exit=1` — `fetchRecordingList` undefined.

- [ ] **Step 3: Implement**

`WatchtowerDesktop/Sources/Models/RecordingListItem.swift`:

```swift
import Foundation
import GRDB

/// Lightweight projection of `meeting_transcripts` for the Recordings master
/// list. Deliberately excludes `transcript_text` (only a 200-char snippet) and
/// `summary_json` (only a boolean) so scrolling the list never deserializes
/// megabyte blobs — mirroring the Go `transcript list` command.
struct RecordingListItem: Decodable, FetchableRecord, Identifiable, Equatable {
    let id: Int64
    let eventID: String?
    let title: String
    let durationSec: Int
    let langStats: String
    let createdAt: String
    let hasRecap: Bool
    let hasNotes: Bool
    let snippet: String

    enum CodingKeys: String, CodingKey {
        case id
        case eventID = "event_id"
        case title
        case durationSec = "duration_sec"
        case langStats = "lang_stats"
        case createdAt = "created_at"
        case hasRecap = "has_recap"
        case hasNotes = "has_notes"
        case snippet
    }
}
```

Append to `MeetingTranscriptQueries`:

```swift
    /// Recordings master list (ad-hoc + event-linked), newest first. A recap
    /// "exists" when the row has summary_json OR its event has a
    /// meeting_recaps row (the recap collision guard can put it in either).
    static func fetchRecordingList(_ db: Database, limit: Int = 200) throws -> [RecordingListItem] {
        try RecordingListItem.fetchAll(
            db,
            sql: """
                SELECT t.id, t.event_id, t.title, t.duration_sec, t.lang_stats, t.created_at,
                       (t.summary_json IS NOT NULL
                        OR EXISTS (SELECT 1 FROM meeting_recaps r WHERE r.event_id = t.event_id)) AS has_recap,
                       (t.notes_md IS NOT NULL) AS has_notes,
                       substr(t.transcript_text, 1, 200) AS snippet
                FROM meeting_transcripts t
                ORDER BY t.created_at DESC, t.id DESC
                LIMIT ?
                """,
            arguments: [limit])
    }
```

- [ ] **Step 4: Run tests**

```bash
cd WatchtowerDesktop && swift test --filter MeetingTranscriptQueriesTests > /tmp/swift-test.log 2>&1; echo "exit=$?"
```
Expected: `exit=0`.

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/Sources/Models/RecordingListItem.swift WatchtowerDesktop/Sources/Database/Queries/MeetingTranscriptQueries.swift WatchtowerDesktop/Tests/MeetingTranscriptQueriesTests.swift
git commit -m "feat(desktop): RecordingListItem lightweight projection for the recordings list"
```

---

### Task 8: Swift queries — `saveNotes` + transactional `delete`

**Files:**
- Modify: `WatchtowerDesktop/Sources/Database/Queries/MeetingTranscriptQueries.swift`
- Test: `WatchtowerDesktop/Tests/MeetingTranscriptQueriesTests.swift`

**Interfaces:**
- Consumes: `ChatMessageQueries.deleteByConversation(_:conversationID:)`, `ChatConversationQueries.fetchByContext(_:type:id:)` / `.delete(_:id:)`.
- Produces:
  ```swift
  static func saveNotes(_ db: Database, id: Int64, markdown: String) throws
  static func delete(_ db: Database, id: Int64) throws -> String?  // returns audio_path for post-commit file removal
  ```
  Task 14 calls both. Chat context type is the string `"meeting"`, context id is `String(transcriptID)` — must match Task 11 exactly.

- [ ] **Step 1: Write the failing tests** (append to `MeetingTranscriptQueriesTests.swift`; add `import Foundation` if missing)

```swift
    func test_saveNotesWritesMarkdownAndBumpsUpdatedAt() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertMeetingTranscript(db, id: 1)
            try MeetingTranscriptQueries.saveNotes(db, id: 1, markdown: "# edited")
        }
        try db.read { db in
            let tr = try XCTUnwrap(MeetingTranscriptQueries.fetch(db, id: 1))
            XCTAssertEqual(tr.notesMD, "# edited")
        }
    }

    func test_deleteRemovesRowChatAndReturnsAudioPath() throws {
        let db = try TestDatabase.create()
        var returnedPath: String?
        try db.write { db in
            try ChatConversationQueries.ensureTable(db)
            try ChatMessageQueries.ensureTable(db)
            try TestDatabase.insertCalendarEvent(db, id: "evt-1")
            try TestDatabase.insertMeetingRecap(db, eventID: "evt-1", recapJSON: self.summaryJSON)
            try TestDatabase.insertMeetingTranscript(
                db, id: 1, eventID: "evt-1", audioPath: "/tmp/rec_1.caf")
            try TestDatabase.insertMeetingTranscript(db, id: 2, title: "Keep me")
            let conv = try ChatConversationQueries.create(
                db, title: "Meeting: Rec", contextType: "meeting", contextID: "1")
            _ = try ChatMessageQueries.insert(db, conversationID: conv.id, role: "user", text: "hi")

            returnedPath = try MeetingTranscriptQueries.delete(db, id: 1)
        }
        XCTAssertEqual(returnedPath, "/tmp/rec_1.caf")
        try db.read { db in
            XCTAssertNil(try MeetingTranscriptQueries.fetch(db, id: 1))
            XCTAssertNotNil(try MeetingTranscriptQueries.fetch(db, id: 2), "other transcripts untouched")
            XCTAssertNil(try ChatConversationQueries.fetchByContext(db, type: "meeting", id: "1"))
            let msgCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chat_messages") ?? -1
            XCTAssertEqual(msgCount, 0, "chat messages must be deleted with the conversation")
            XCTAssertNotNil(try MeetingRecapQueries.fetch(db, eventID: "evt-1"),
                            "the event's recap must survive transcript deletion (safe delete scope)")
        }
    }

    // Valid-but-degenerate inputs: no chat, no audio, already-swept audio.
    func test_deleteWithoutChatOrAudioSucceeds() throws {
        let db = try TestDatabase.create()
        var returnedPath: String? = "sentinel"
        try db.write { db in
            try ChatConversationQueries.ensureTable(db)
            try ChatMessageQueries.ensureTable(db)
            try TestDatabase.insertMeetingTranscript(db, id: 1, audioPath: nil)
            returnedPath = try MeetingTranscriptQueries.delete(db, id: 1)
        }
        XCTAssertNil(returnedPath, "NULL audio_path (already swept) must return nil")
        try db.read { db in
            XCTAssertNil(try MeetingTranscriptQueries.fetch(db, id: 1))
        }
    }

    func test_deleteUnknownIDIsNoOp() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try ChatConversationQueries.ensureTable(db)
            try ChatMessageQueries.ensureTable(db)
            XCTAssertNil(try MeetingTranscriptQueries.delete(db, id: 999))
        }
    }
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd WatchtowerDesktop && swift test --filter MeetingTranscriptQueriesTests > /tmp/swift-test.log 2>&1; echo "exit=$?"
```
Expected: `exit=1` — `saveNotes`/`delete` undefined.

- [ ] **Step 3: Implement** (append to `MeetingTranscriptQueries`)

```swift
    /// Direct notes write from the editor (GRDB, no CLI round-trip — same
    /// local-write precedent as `linkToEvent`).
    static func saveNotes(_ db: Database, id: Int64, markdown: String) throws {
        try db.execute(
            sql: """
                UPDATE meeting_transcripts
                SET notes_md = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                WHERE id = ?
                """,
            arguments: [markdown, id])
    }

    /// Deletes a recording with all its content: the transcript row and its
    /// "meeting" chat conversation (+ messages). The event's `meeting_recaps`
    /// row is deliberately NOT touched — a recap can exist independently of
    /// the recording (safe delete scope). Returns the audio_path (if any) so
    /// the caller can remove the file AFTER the transaction commits;
    /// callers must treat a missing file as success (daemon retention may
    /// have swept it already).
    static func delete(_ db: Database, id: Int64) throws -> String? {
        guard let transcript = try fetch(db, id: id) else { return nil }
        if let conv = try ChatConversationQueries.fetchByContext(db, type: "meeting", id: String(id)) {
            try ChatMessageQueries.deleteByConversation(db, conversationID: conv.id)
            try ChatConversationQueries.delete(db, id: conv.id)
        }
        try db.execute(sql: "DELETE FROM meeting_transcripts WHERE id = ?", arguments: [id])
        return transcript.audioPath
    }
```

- [ ] **Step 4: Run tests**

```bash
cd WatchtowerDesktop && swift test --filter MeetingTranscriptQueriesTests > /tmp/swift-test.log 2>&1; echo "exit=$?"
```
Expected: `exit=0`.

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/Sources/Database/Queries/MeetingTranscriptQueries.swift WatchtowerDesktop/Tests/MeetingTranscriptQueriesTests.swift
git commit -m "feat(desktop): saveNotes + transactional delete for recordings"
```

---

### Task 9: `TranscriptSaveService.generateNotes`

**Files:**
- Modify: `WatchtowerDesktop/Sources/Services/TranscriptSaveService.swift`
- Test: `WatchtowerDesktop/Tests/MeetingRecapServiceTests.swift` — check where `TranscriptSaveService` tests live first (`grep -rln "TranscriptSaveService" WatchtowerDesktop/Tests/`); add to that file, or create `WatchtowerDesktop/Tests/TranscriptSaveServiceTests.swift` if none.

**Interfaces:**
- Consumes: CLI envelope from Task 5: `{"transcript_id": N, "notes_md": "..."}`; existing `CLIRunnerProtocol` (`func run(args: [String]) async throws -> Data` — verify the exact protocol signature in `WatchtowerDesktop/Sources/Services/` and match it in the mock).
- Produces:
  ```swift
  struct TranscriptNotesResult: Decodable, Equatable { let transcriptID: Int64; let notesMD: String }
  func generateNotes(transcriptID: Int64) async throws -> TranscriptNotesResult
  ```
  Task 10 (center) calls `generateNotes`.

- [ ] **Step 1: Write the failing test** (use the existing mock CLI runner if the test target has one — `grep -rn "CLIRunnerProtocol" WatchtowerDesktop/Tests/` — otherwise define a local mock matching the protocol)

```swift
    func test_generateNotesInvokesCLIAndDecodesEnvelope() async throws {
        let mock = MockCLIRunner(stdout: Data("""
            {"transcript_id": 7, "notes_md": "# Sync\\n\\n## Summary\\nShipped."}
            """.utf8))
        let service = TranscriptSaveService(runner: mock)

        let result = try await service.generateNotes(transcriptID: 7)

        XCTAssertEqual(result.transcriptID, 7)
        XCTAssertTrue(result.notesMD.contains("## Summary"))
        XCTAssertEqual(mock.lastArgs, ["meeting-prep", "transcript", "notes", "7"])
    }
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd WatchtowerDesktop && swift test --filter generateNotes > /tmp/swift-test.log 2>&1; echo "exit=$?"
```
Expected: `exit=1` — `generateNotes` undefined.

- [ ] **Step 3: Implement** (append to `TranscriptSaveService.swift`)

```swift
// MARK: - TranscriptNotesResult

/// Decoded stdout envelope of `watchtower meeting-prep transcript notes <id>`.
/// The CLI exits non-zero on any failure (nothing persisted), so decoding
/// only happens on success.
struct TranscriptNotesResult: Decodable, Equatable {
    let transcriptID: Int64
    let notesMD: String

    enum CodingKeys: String, CodingKey {
        case transcriptID = "transcript_id"
        case notesMD = "notes_md"
    }
}
```

And inside `TranscriptSaveService`:

```swift
    /// `meeting-prep transcript notes <id>` — generate publishable markdown
    /// meeting notes. The CLI persists notes_md itself; the returned markdown
    /// is for immediate display.
    func generateNotes(transcriptID: Int64) async throws -> TranscriptNotesResult {
        let args = ["meeting-prep", "transcript", "notes", String(transcriptID)]
        let data = try await runner.run(args: args)
        return try JSONDecoder().decode(TranscriptNotesResult.self, from: data)
    }
```

- [ ] **Step 4: Run tests**

```bash
cd WatchtowerDesktop && swift test --filter TranscriptSaveService > /tmp/swift-test.log 2>&1; echo "exit=$?"
```
Expected: `exit=0`.

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/Sources/Services/TranscriptSaveService.swift WatchtowerDesktop/Tests/
git commit -m "feat(desktop): TranscriptSaveService.generateNotes"
```

---

### Task 10: `TranscriptNotesCenter` on AppState (navigation-surviving generation)

**Files:**
- Create: `WatchtowerDesktop/Sources/Services/TranscriptNotesCenter.swift`
- Modify: `WatchtowerDesktop/Sources/App/AppState.swift` (one `let` near `meetingRecorderCenter`, line ~38)
- Test: `WatchtowerDesktop/Tests/TranscriptNotesCenterTests.swift`

**Interfaces:**
- Consumes: `TranscriptSaveService.generateNotes` (Task 9).
- Produces:
  ```swift
  @MainActor @Observable final class TranscriptNotesCenter {
      private(set) var generating: Set<Int64>
      private(set) var lastError: [Int64: String]
      func generate(transcriptID: Int64, service: TranscriptSaveService, onFinished: @escaping @MainActor () -> Void)
      func clearError(transcriptID: Int64)
  }
  ```
  On AppState: `let transcriptNotesCenter = TranscriptNotesCenter()`. Task 14's notes tab reads `generating.contains(id)` — the in-flight flag survives "начал → ушёл → вернулся" because the center lives on AppState, not the view (feedback: async ops need navigation-surviving state).

- [ ] **Step 1: Write the failing tests**

`WatchtowerDesktop/Tests/TranscriptNotesCenterTests.swift`:

```swift
import XCTest
@testable import WatchtowerDesktop

@MainActor
final class TranscriptNotesCenterTests: XCTestCase {

    private func makeService(result: Result<Data, Error>) -> TranscriptSaveService {
        TranscriptSaveService(runner: MockCLIRunner(result: result))
    }

    func test_generateSetsInFlightFlagAndClearsOnSuccess() async throws {
        let center = TranscriptNotesCenter()
        let service = makeService(result: .success(Data(
            #"{"transcript_id": 5, "notes_md": "# n"}"#.utf8)))

        let done = expectation(description: "finished")
        center.generate(transcriptID: 5, service: service) { done.fulfill() }
        XCTAssertTrue(center.generating.contains(5),
                      "in-flight flag must be set synchronously — it survives navigation on AppState")

        await fulfillment(of: [done], timeout: 5)
        XCTAssertFalse(center.generating.contains(5))
        XCTAssertNil(center.lastError[5])
    }

    func test_generateFailureRecordsErrorAndClearsFlag() async throws {
        struct Boom: Error {}
        let center = TranscriptNotesCenter()
        let service = makeService(result: .failure(Boom()))

        let done = expectation(description: "finished")
        center.generate(transcriptID: 5, service: service) { done.fulfill() }
        await fulfillment(of: [done], timeout: 5)

        XCTAssertFalse(center.generating.contains(5))
        XCTAssertNotNil(center.lastError[5])

        center.clearError(transcriptID: 5)
        XCTAssertNil(center.lastError[5])
    }

    func test_generateIgnoresDuplicateStartForSameTranscript() async throws {
        let center = TranscriptNotesCenter()
        let service = makeService(result: .success(Data(
            #"{"transcript_id": 5, "notes_md": "# n"}"#.utf8)))

        let done = expectation(description: "first finished")
        center.generate(transcriptID: 5, service: service) { done.fulfill() }
        center.generate(transcriptID: 5, service: service) {
            XCTFail("second start for the same transcript must be a no-op")
        }
        await fulfillment(of: [done], timeout: 5)
    }
}
```

(Adapt `MockCLIRunner` to the shape the test target already has; if it only supports fixed stdout, extend it with a `Result`-based init in the Tests helpers.)

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd WatchtowerDesktop && swift test --filter TranscriptNotesCenterTests > /tmp/swift-test.log 2>&1; echo "exit=$?"
```
Expected: `exit=1` — type undefined.

- [ ] **Step 3: Implement `TranscriptNotesCenter.swift`**

```swift
import Foundation

/// App-wide owner of in-flight meeting-notes generation, living on AppState
/// so the "generating…" state survives navigation (view-local state would
/// lose the flag when the user leaves the recording and comes back — the CLI
/// keeps running and persists notes_md regardless; this center keeps the UI
/// truthful about it).
@MainActor
@Observable
final class TranscriptNotesCenter {
    private(set) var generating: Set<Int64> = []
    private(set) var lastError: [Int64: String] = [:]

    /// Starts notes generation for a transcript. No-op when a run for the
    /// same transcript is already in flight. `onFinished` fires on success
    /// AND failure — callers reload notes_md from the DB (the CLI is the
    /// writer).
    func generate(
        transcriptID: Int64,
        service: TranscriptSaveService,
        onFinished: @escaping @MainActor () -> Void
    ) {
        guard !generating.contains(transcriptID) else { return }
        generating.insert(transcriptID)
        lastError[transcriptID] = nil
        Task {
            do {
                _ = try await service.generateNotes(transcriptID: transcriptID)
            } catch {
                lastError[transcriptID] = error.localizedDescription
            }
            generating.remove(transcriptID)
            onFinished()
        }
    }

    func clearError(transcriptID: Int64) {
        lastError[transcriptID] = nil
    }
}
```

In `AppState.swift`, next to `let meetingRecorderCenter = MeetingRecorderCenter()`:

```swift
    let transcriptNotesCenter = TranscriptNotesCenter()
```

- [ ] **Step 4: Run tests**

```bash
cd WatchtowerDesktop && swift test --filter TranscriptNotesCenterTests > /tmp/swift-test.log 2>&1; echo "exit=$?"
```
Expected: `exit=0`.

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/Sources/Services/TranscriptNotesCenter.swift WatchtowerDesktop/Sources/App/AppState.swift WatchtowerDesktop/Tests/TranscriptNotesCenterTests.swift
git commit -m "feat(desktop): TranscriptNotesCenter — navigation-surviving notes generation"
```

---

### Task 11: `MeetingChatViewModel`

**Files:**
- Create: `WatchtowerDesktop/Sources/ViewModels/MeetingChatViewModel.swift`
- Test: `WatchtowerDesktop/Tests/MeetingChatViewModelTests.swift`

**Interfaces:**
- Consumes: `ChatConversationQueries` / `ChatMessageQueries`, `AIServiceProtocol` (`WatchtowerAIService`), `ChatModel`, `ConfigService`, `MeetingTranscript` (+ `notesMD`), `MeetingRecap.Content`. Context type string `"meeting"` / context id `String(transcript.id!)` — must match Task 8's delete.
- Produces: `@MainActor @Observable final class MeetingChatViewModel` with the same public surface as `SituationChatViewModel` (`messages`, `isStreaming`, `inputText`, `errorMessage`, `send()`, `cancelStream()`, `static persistedMessageCount(_:transcriptID:)`). Task 14's chat tab binds to it.

- [ ] **Step 1: Write the failing tests**

`WatchtowerDesktop/Tests/MeetingChatViewModelTests.swift` (mirror `SituationChatViewModelTests` setup — `TestDatabase.createDatabaseManager()` + `ensureTable` calls + `MockClaudeService`):

```swift
import XCTest
import GRDB
@testable import WatchtowerDesktop

@MainActor
final class MeetingChatViewModelTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!

    override func setUp() {
        super.setUp()
        do {
            (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
            try dbManager.dbPool.write { db in
                try ChatConversationQueries.ensureTable(db)
                try ChatMessageQueries.ensureTable(db)
                try TestDatabase.insertMeetingTranscript(
                    db, id: 7, title: "Weekly Sync",
                    transcriptText: "we agreed to ship v2 on friday")
            }
        } catch { XCTFail("setUp failed: \(error)") }
    }

    override func tearDown() {
        TestDatabase.cleanup(path: dbPath)
        super.tearDown()
    }

    private func loadTranscript() throws -> MeetingTranscript {
        try XCTUnwrap(dbManager.dbPool.read { db in
            try MeetingTranscriptQueries.fetch(db, id: 7)
        })
    }

    func testCreatesConversationWithMeetingContext() throws {
        let transcript = try loadTranscript()
        _ = MeetingChatViewModel(
            transcript: transcript, recapContent: nil,
            dbManager: dbManager, aiService: MockClaudeService())

        let conv = try dbManager.dbPool.read { db in
            try ChatConversationQueries.fetchByContext(db, type: "meeting", id: "7")
        }
        let unwrapped = try XCTUnwrap(conv)
        XCTAssertTrue(unwrapped.title.hasPrefix("Meeting:"))
    }

    func testReopensExistingConversationWithHistory() throws {
        let transcript = try loadTranscript()
        _ = MeetingChatViewModel(
            transcript: transcript, recapContent: nil,
            dbManager: dbManager, aiService: MockClaudeService())
        let conv = try XCTUnwrap(dbManager.dbPool.read { db in
            try ChatConversationQueries.fetchByContext(db, type: "meeting", id: "7")
        })
        try dbManager.dbPool.write { db in
            _ = try ChatMessageQueries.insert(db, conversationID: conv.id, role: "user", text: "earlier question")
        }

        let vm2 = MeetingChatViewModel(
            transcript: transcript, recapContent: nil,
            dbManager: dbManager, aiService: MockClaudeService())
        XCTAssertEqual(vm2.messages.map(\.text), ["earlier question"])
    }

    func testSystemPromptCarriesMeetingContextAndCapsTranscript() throws {
        let long = String(repeating: "слово ", count: 5_000) // ~30k chars
        let transcript = MeetingTranscript(
            id: 7, eventID: nil, title: "Big meeting", audioPath: nil,
            durationSec: 3600, langStats: "{}", transcriptText: long,
            summaryJSON: nil, notesMD: nil, createdAt: "2026-07-15T10:00:00Z",
            updatedAt: "2026-07-15T10:00:00Z")
        let recap = MeetingRecap.Content(
            summary: "shipped v2", keyDecisions: ["ship"], actionItems: [], openQuestions: [])

        let prompt = MeetingChatViewModel.buildSystemPrompt(
            transcript: transcript, recapContent: recap)

        XCTAssertTrue(prompt.contains("Big meeting"))
        XCTAssertTrue(prompt.contains("shipped v2"))
        XCTAssertTrue(prompt.contains("get_transcript"),
                      "prompt must point the model at the MCP tool for the full text")
        XCTAssertLessThan(prompt.count, 16_000,
                          "transcript excerpt must be capped so the interactive CLI prompt stays clear of ARG_MAX")
    }

    func testPersistedMessageCount() throws {
        let transcript = try loadTranscript()
        let vm = MeetingChatViewModel(
            transcript: transcript, recapContent: nil,
            dbManager: dbManager, aiService: MockClaudeService())
        _ = vm
        let conv = try XCTUnwrap(dbManager.dbPool.read { db in
            try ChatConversationQueries.fetchByContext(db, type: "meeting", id: "7")
        })
        try dbManager.dbPool.write { db in
            _ = try ChatMessageQueries.insert(db, conversationID: conv.id, role: "user", text: "q")
        }
        let count = try dbManager.dbPool.read { db in
            try MeetingChatViewModel.persistedMessageCount(db, transcriptID: 7)
        }
        XCTAssertEqual(count, 1)
    }
}
```

Note: the memberwise `MeetingTranscript(...)` init in the cap test — if the struct's synthesized memberwise init is unavailable from tests, insert a row via `TestDatabase.insertMeetingTranscript(db, id:..., transcriptText: long)` and fetch it instead.

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd WatchtowerDesktop && swift test --filter MeetingChatViewModelTests > /tmp/swift-test.log 2>&1; echo "exit=$?"
```
Expected: `exit=1` — type undefined.

- [ ] **Step 3: Implement `MeetingChatViewModel.swift`**

Copy the streaming/persistence skeleton of `SituationChatViewModel` verbatim (send / executeStream / cancelStream / updateLastMessage / finishStream / handleSessionID / persistMessage / persistResponse — replace the `SituationChat:` log prefixes with `MeetingChat:`), with these differences:

```swift
import Foundation
import GRDB

/// Secretary chat about ONE meeting recording. Persisted conversation per
/// transcript (`chat_conversations.context_type = "meeting"`), streaming via
/// `AIServiceProtocol` — same skeleton as SituationChatViewModel, but the
/// context is the transcript + recap, and the full transcript text is
/// reachable via the get_transcript MCP tool instead of being inlined
/// wholesale (hour-long transcripts would blow the interactive CLI's ARG_MAX).
@MainActor
@Observable
final class MeetingChatViewModel {
    var messages: [ChatMessage] = []
    var isStreaming = false
    var inputText = ""
    var errorMessage: String?

    private var conversationID: Int64?
    private var sessionID: String?
    private let aiService: any AIServiceProtocol
    private let dbManager: DatabaseManager
    private let transcript: MeetingTranscript
    private let recapContent: MeetingRecap.Content?
    private let selectedModel: ChatModel
    private var streamTask: Task<Void, Never>?

    /// Characters of transcript inlined into the system prompt; the rest is
    /// fetched by the model on demand via get_transcript.
    static let transcriptExcerptLimit = 12_000

    init(
        transcript: MeetingTranscript,
        recapContent: MeetingRecap.Content?,
        dbManager: DatabaseManager,
        aiService: (any AIServiceProtocol)? = nil,
        provider: AIProvider? = nil
    ) {
        self.transcript = transcript
        self.recapContent = recapContent
        self.dbManager = dbManager
        self.aiService = aiService ?? WatchtowerAIService()
        let resolvedProvider = provider
            ?? (ConfigService().aiProvider == "codex" ? .codex : .claude)
        self.selectedModel = ChatModel.defaultModel(for: resolvedProvider)

        loadOrCreateConversation()
    }

    static func persistedMessageCount(_ db: Database, transcriptID: Int64) throws -> Int {
        guard let conv = try ChatConversationQueries.fetchByContext(
            db, type: "meeting", id: String(transcriptID)
        ) else { return 0 }
        return try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM chat_messages WHERE conversation_id = ?",
            arguments: [conv.id]
        ) ?? 0
    }

    private func loadOrCreateConversation() {
        guard let id = transcript.id else { return }
        do {
            if let existing = try dbManager.dbPool.read({ db in
                try ChatConversationQueries.fetchByContext(db, type: "meeting", id: String(id))
            }) {
                let records = try dbManager.dbPool.read { db in
                    try ChatMessageQueries.fetchByConversation(db, conversationID: existing.id)
                }
                conversationID = existing.id
                sessionID = existing.sessionID
                messages = records.map { $0.toChatMessage() }
                return
            }
            let conv = try dbManager.dbPool.write { db in
                try ChatConversationQueries.create(
                    db,
                    title: "Meeting: \(String(transcript.title.prefix(60)))",
                    contextType: "meeting",
                    contextID: String(id)
                )
            }
            conversationID = conv.id
            sessionID = conv.sessionID
            messages = []
        } catch {
            errorMessage = "Failed to load conversation: \(error.localizedDescription)"
        }
    }

    // … send()/sendUserMessage/executeStream/cancelStream/updateLastMessage/
    //   finishStream/handleSessionID/persistMessage/persistResponse — copied
    //   from SituationChatViewModel with:
    //   - systemPrompt: Self.buildSystemPrompt(transcript: transcript, recapContent: recapContent)
    //   - resumed-session context block: Self.meetingContextBlock(transcript, recapContent: recapContent)

    // MARK: - System prompt

    nonisolated static func meetingContextBlock(
        _ transcript: MeetingTranscript, recapContent: MeetingRecap.Content?
    ) -> String {
        var b = """
        === MEETING RECORDING ===
        Title: \(transcript.title)
        Recorded: \(transcript.createdAt)  Duration: \(transcript.durationSec)s
        Transcript id: \(transcript.id.map(String.init) ?? "?") (fetch the FULL text with the get_transcript tool)
        """
        if let recap = recapContent {
            if !recap.summary.isEmpty { b += "\nRecap summary: \(recap.summary)" }
            if !recap.keyDecisions.isEmpty { b += "\nDecisions:\n- " + recap.keyDecisions.joined(separator: "\n- ") }
            if !recap.actionItems.isEmpty { b += "\nAction items:\n- " + recap.actionItems.joined(separator: "\n- ") }
            if !recap.openQuestions.isEmpty { b += "\nOpen questions:\n- " + recap.openQuestions.joined(separator: "\n- ") }
        }
        return b
    }

    nonisolated static func buildSystemPrompt(
        transcript: MeetingTranscript, recapContent: MeetingRecap.Content?
    ) -> String {
        let excerpt = String(transcript.transcriptText.prefix(transcriptExcerptLimit))
        let truncated = transcript.transcriptText.count > transcriptExcerptLimit

        return """
        You are the user's AI secretary, discussing ONE recorded meeting. \
        Help them recall what was said, clarify decisions, and draft follow-ups when asked.

        \(meetingContextBlock(transcript, recapContent: recapContent))

        === TRANSCRIPT EXCERPT (single-track, speakers not labeled, may mix ru/uk/en) ===
        \(excerpt)
        \(truncated ? "(…truncated — use get_transcript with the transcript id above for the full text)" : "(full transcript shown)")

        === TOOLS (local Watchtower data — already connected; use them, never ask the user) ===
        - get_transcript / list_transcripts — the full transcript text of this and other recordings.
        - list_messages, get_person / list_people, get_target / list_tracks — surrounding work context.
        Never ask for a database path; the data is already local and the tools are already connected.

        === RESPONSE STYLE ===
        - Match the user's language in conversation.
        - Be concise; this is a working discussion, not a report.
        - Quote the transcript verbatim when the user asks "what exactly was said".
        """
    }
}
```

The `// … copied` comment above is a planning shorthand for THIS document only — the implementer copies those nine members from `SituationChatViewModel.swift` (lines 95–250) literally, adjusting only the two lines that reference the system prompt / context block and the log prefixes. No other logic changes.

- [ ] **Step 4: Run tests**

```bash
cd WatchtowerDesktop && swift test --filter MeetingChatViewModelTests > /tmp/swift-test.log 2>&1; echo "exit=$?"
```
Expected: `exit=0`.

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/Sources/ViewModels/MeetingChatViewModel.swift WatchtowerDesktop/Tests/MeetingChatViewModelTests.swift
git commit -m "feat(desktop): MeetingChatViewModel — secretary chat about a recording"
```

---

### Task 12: Detail tab views — Recap / Notes / Transcript / Chat

**Files:**
- Create: `WatchtowerDesktop/Sources/Views/Calendar/RecordingDetailTabs.swift` (all four tab subviews in one file — they are small and change together)

**Interfaces:**
- Consumes: `MeetingTranscript` (+`notesMD`), `MeetingRecap.Content`, `TranscriptSaveService`, `TranscriptNotesCenter` (Task 10), `MeetingChatViewModel` (Task 11), `MarkdownText`, `ChatInput`, `MeetingTranscriptQueries.saveNotes`.
- Produces four views used by Task 14:
  ```swift
  struct RecordingRecapTab: View   // init(transcript:recapContent:onRetryRecap:isRetrying:)
  struct RecordingNotesTab: View   // init(transcript:notesMD:onGenerate:isGenerating:generationError:onSave:)
  struct RecordingTranscriptTab: View // init(transcriptText:)
  struct RecordingChatTab: View    // init(chatVM:)
  ```

- [ ] **Step 1: Implement the four tabs**

`RecordingDetailTabs.swift`:

```swift
import SwiftUI
import AppKit

// MARK: - Recap tab

/// Structured recap (summary / decisions / action items / open questions) —
/// same plain-Text rendering as MeetingNotesView.recapSection, duplicated
/// here because the prep pane keeps its own copy (both stay functional).
struct RecordingRecapTab: View {
    let transcript: MeetingTranscript
    let recapContent: MeetingRecap.Content?
    let onRetryRecap: () -> Void
    let isRetrying: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let content = recapContent {
                    if !content.summary.isEmpty {
                        Text(content.summary)
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                    if !content.keyDecisions.isEmpty {
                        recapSubsection(title: "Decisions", items: content.keyDecisions)
                    }
                    if !content.actionItems.isEmpty {
                        recapSubsection(title: "Action items", items: content.actionItems)
                    }
                    if !content.openQuestions.isEmpty {
                        recapSubsection(title: "Open questions", items: content.openQuestions)
                    }
                } else {
                    VStack(spacing: 8) {
                        Text("No recap yet")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
                }

                Button {
                    onRetryRecap()
                } label: {
                    Label(recapContent == nil ? "Generate recap" : "Re-generate",
                          systemImage: isRetrying ? "hourglass" : "arrow.triangle.2.circlepath")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isRetrying)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func recapSubsection(title: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.medium)
            ForEach(Array(items.enumerated()), id: \.offset) { _, text in
                HStack(alignment: .top, spacing: 6) {
                    Text("•").foregroundStyle(.secondary)
                    Text(text)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

// MARK: - Notes tab

/// Publishable meeting notes: generate (AI, via TranscriptNotesCenter) →
/// edit in a TextEditor (debounced autosave) → Copy to clipboard.
struct RecordingNotesTab: View {
    let transcript: MeetingTranscript
    let notesMD: String?
    let onGenerate: () -> Void
    let isGenerating: Bool
    let generationError: String?
    let onSave: (String) -> Void

    @State private var draft: String = ""
    @State private var copied = false
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    onGenerate()
                } label: {
                    Label(notesMD == nil ? "Generate" : "Re-generate",
                          systemImage: "sparkles")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isGenerating)

                if isGenerating {
                    ProgressView().controlSize(.small)
                    Text("Generating notes…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if !draft.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(draft, forType: .string)
                        copied = true
                        Task { try? await Task.sleep(for: .seconds(2)); copied = false }
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if let error = generationError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if notesMD == nil && draft.isEmpty && !isGenerating {
                Text("Generate publishable meeting notes from the transcript, edit them, then copy anywhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextEditor(text: $draft)
                .font(.callout)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(.textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                .onChange(of: draft) { _, newValue in
                    scheduleSave(newValue)
                }
        }
        .padding(12)
        .onAppear { draft = notesMD ?? "" }
        .onChange(of: notesMD) { _, newValue in
            // Generation finished (or another window edited) — adopt the DB
            // value only when the local draft isn't ahead of it.
            if let newValue, draft != newValue, saveTask == nil {
                draft = newValue
            }
        }
        .onDisappear {
            saveTask?.cancel()
            saveTask = nil
            flushSave()
        }
    }

    private func scheduleSave(_ text: String) {
        guard text != (notesMD ?? "") else { return }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            onSave(text)
            saveTask = nil
        }
    }

    private func flushSave() {
        if draft != (notesMD ?? "") {
            onSave(draft)
        }
    }
}

// MARK: - Transcript tab

/// Full transcript text — the ONLY place the heavy blob is rendered.
struct RecordingTranscriptTab: View {
    let transcriptText: String

    var body: some View {
        ScrollView {
            Text(transcriptText)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
    }
}

// MARK: - Chat tab

/// Secretary chat about this meeting. The ChatInput is docked BELOW the
/// ScrollView (nested-NSScrollView collapse — same constraint as
/// SituationDiscussInputBar).
struct RecordingChatTab: View {
    @Bindable var chatVM: MeetingChatViewModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if chatVM.messages.isEmpty {
                        Text("Ask about this meeting — what was decided, who said what, or draft a follow-up.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 8)
                    }
                    ForEach(chatVM.messages) { msg in
                        bubble(msg)
                    }
                }
                .padding(12)
            }

            Divider()

            if let err = chatVM.errorMessage {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
            }
            ChatInput(
                text: $chatVM.inputText,
                isStreaming: chatVM.isStreaming,
                onSend: { chatVM.send() },
                onStop: { chatVM.cancelStream() },
                placeholder: "Ask about this meeting…"
            )
        }
    }

    @ViewBuilder
    private func bubble(_ msg: ChatMessage) -> some View {
        switch msg.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(msg.text)
                    .font(.subheadline)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 14))
            }
        case .assistant:
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "sparkle")
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 9)
                Group {
                    if msg.text.isEmpty && msg.isStreaming {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("Thinking…").foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                    } else {
                        MarkdownText(text: msg.text)
                            .font(.subheadline)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
            }
        case .system:
            Text(msg.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}
```

- [ ] **Step 2: Build**

```bash
cd WatchtowerDesktop && swift build > /tmp/swift-build.log 2>&1; echo "exit=$?"
```
Expected: `exit=0`. (Pure views; behavior is exercised through Tasks 10–11 unit tests and Task 14's view tests.)

- [ ] **Step 3: Commit**

```bash
git add WatchtowerDesktop/Sources/Views/Calendar/RecordingDetailTabs.swift
git commit -m "feat(desktop): recording detail tab views (recap/notes/transcript/chat)"
```

---

### Task 13: `RecordingRow` + `RecordingsListView` (master list)

**Files:**
- Create: `WatchtowerDesktop/Sources/Views/Calendar/RecordingsListView.swift`
- Test: `WatchtowerDesktop/Tests/RecordingsListViewTests.swift`

**Interfaces:**
- Consumes: `RecordingListItem` (Task 7), `TranscriptFormatting` / `TranscriptLangBadges`.
- Produces:
  ```swift
  struct RecordingsListView: View {
      let items: [RecordingListItem]
      @Binding var selectedID: Int64?
  }
  ```
  Task 14's container owns loading; this view is presentation-only (easy ViewInspector coverage).

- [ ] **Step 1: Write the failing test**

`WatchtowerDesktop/Tests/RecordingsListViewTests.swift`:

```swift
import XCTest
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop

@MainActor
final class RecordingsListViewTests: XCTestCase {
    private func makeItem(
        id: Int64, title: String = "Rec", eventID: String? = nil,
        hasRecap: Bool = false, hasNotes: Bool = false, snippet: String = "…"
    ) -> RecordingListItem {
        RecordingListItem(
            id: id, eventID: eventID, title: title, durationSec: 125,
            langStats: #"{"ru":3}"#, createdAt: "2026-07-15T10:00:00Z",
            hasRecap: hasRecap, hasNotes: hasNotes, snippet: snippet)
    }

    func test_rendersRowPerItemWithTitle() throws {
        let view = RecordingsListView(
            items: [makeItem(id: 1, title: "Weekly Sync"), makeItem(id: 2, title: "1:1")],
            selectedID: .constant(nil))
        let texts = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        XCTAssertTrue(texts.contains("Weekly Sync"))
        XCTAssertTrue(texts.contains("1:1"))
    }

    func test_emptyStateShown() throws {
        let view = RecordingsListView(items: [], selectedID: .constant(nil))
        let texts = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        XCTAssertTrue(texts.contains { $0.contains("No recordings") })
    }
}
```

(If `RecordingListItem`'s synthesized memberwise init is not accessible, add an explicit internal init to the struct in Task 7's file.)

- [ ] **Step 2: Run test to verify it fails**

```bash
cd WatchtowerDesktop && swift test --filter RecordingsListViewTests > /tmp/swift-test.log 2>&1; echo "exit=$?"
```
Expected: `exit=1`.

- [ ] **Step 3: Implement `RecordingsListView.swift`**

```swift
import SwiftUI

/// Master list of all recordings (ad-hoc + event-linked), newest first.
/// Presentation-only: the parent owns loading and selection.
struct RecordingsListView: View {
    let items: [RecordingListItem]
    @Binding var selectedID: Int64?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .foregroundStyle(.blue)
                    Text("Recordings")
                        .font(.title2)
                        .fontWeight(.bold)
                    Spacer()
                }

                if items.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "waveform.slash")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No recordings yet")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text("Record a meeting from the Events tab — it will appear here.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                }

                ForEach(items) { item in
                    row(item)
                }
            }
            .padding()
        }
    }

    private func row(_ item: RecordingListItem) -> some View {
        let isSelected = selectedID == item.id
        return Button {
            selectedID = isSelected ? nil : item.id
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: item.eventID == nil ? "waveform" : "calendar")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(item.title)
                        .font(.callout)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Spacer()
                    if item.hasNotes {
                        Image(systemName: "doc.text")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help("Has meeting notes")
                    }
                    if item.hasRecap {
                        Image(systemName: "sparkles")
                            .font(.caption2)
                            .foregroundStyle(.purple)
                            .help("Has AI recap")
                    }
                }
                HStack(spacing: 8) {
                    Text(TranscriptFormatting.formattedDate(item.createdAt))
                    Text(TranscriptFormatting.formatDuration(item.durationSec))
                    TranscriptLangBadges(langStatsJSON: item.langStats)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if !item.snippet.isEmpty {
                    Text(item.snippet)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 4: Run tests**

```bash
cd WatchtowerDesktop && swift test --filter RecordingsListViewTests > /tmp/swift-test.log 2>&1; echo "exit=$?"
```
Expected: `exit=0`.

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/Sources/Views/Calendar/RecordingsListView.swift WatchtowerDesktop/Tests/RecordingsListViewTests.swift
git commit -m "feat(desktop): RecordingsListView master list"
```

---

### Task 14: `RecordingDetailView` + `RecordingsView` container

**Files:**
- Create: `WatchtowerDesktop/Sources/Views/Calendar/RecordingDetailView.swift`
- Create: `WatchtowerDesktop/Sources/Views/Calendar/RecordingsView.swift`
- Test: `WatchtowerDesktop/Tests/RecordingDetailViewTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 7–13; `LinkTranscriptSheet` (existing), `TranscriptSaveService`, `ProcessCLIRunner.makeDefault()` (check the exact factory name in `MeetingRecorderCenter.swift` and reuse it), `MeetingRecapQueries.fetch`, `appState.transcriptNotesCenter`, `appState.databaseManager`.
- Produces:
  ```swift
  struct RecordingsView: View            // master-detail container; owns list state
  struct RecordingDetailView: View       // init(transcriptID: Int64, onDeleted: () -> Void, onChanged: () -> Void)
  enum RecordingDetailTab: String, CaseIterable { case recap, notes, transcript, chat }
  ```
  Task 15 embeds `RecordingsView` into `CalendarEventsView`.

- [ ] **Step 1: Write the failing tests**

`WatchtowerDesktop/Tests/RecordingDetailViewTests.swift`:

```swift
import XCTest
@testable import WatchtowerDesktop

final class RecordingDetailViewTests: XCTestCase {
    func test_tabEnumHasFourCasesInOrder() {
        XCTAssertEqual(
            RecordingDetailTab.allCases.map(\.rawValue),
            ["recap", "notes", "transcript", "chat"])
    }

    func test_tabTitles() {
        XCTAssertEqual(RecordingDetailTab.recap.title, "Recap")
        XCTAssertEqual(RecordingDetailTab.notes.title, "Notes")
        XCTAssertEqual(RecordingDetailTab.transcript.title, "Transcript")
        XCTAssertEqual(RecordingDetailTab.chat.title, "Chat")
    }
}
```

(View behavior — lazy loading, delete cascade — is covered by the query/VM tests of Tasks 8, 10, 11; the detail view is glue. Keep view tests to the stable enum surface.)

- [ ] **Step 2: Run test to verify it fails**

```bash
cd WatchtowerDesktop && swift test --filter RecordingDetailViewTests > /tmp/swift-test.log 2>&1; echo "exit=$?"
```
Expected: `exit=1`.

- [ ] **Step 3: Implement `RecordingDetailView.swift`**

```swift
import SwiftUI

enum RecordingDetailTab: String, CaseIterable {
    case recap, notes, transcript, chat

    var title: String {
        switch self {
        case .recap: return "Recap"
        case .notes: return "Notes"
        case .transcript: return "Transcript"
        case .chat: return "Chat"
        }
    }
}

/// Single-view screen for one recording: header (title/date/duration/badges,
/// link-to-event, delete) + four tabs. The full transcript row is fetched
/// asynchronously on selection; the chat VM is created lazily on first
/// opening of the Chat tab (perf: opening a recording must not pay for the
/// heavy tabs).
struct RecordingDetailView: View {
    let transcriptID: Int64
    let onDeleted: () -> Void
    let onChanged: () -> Void

    @Environment(AppState.self) private var appState
    @State private var transcript: MeetingTranscript?
    @State private var recapContent: MeetingRecap.Content?
    @State private var tab: RecordingDetailTab = .recap
    @State private var chatVM: MeetingChatViewModel?
    @State private var isRetryingRecap = false
    @State private var showDeleteConfirm = false
    @State private var linkTarget: MeetingTranscript?
    @State private var errorMessage: String?

    private var notesService: TranscriptSaveService? {
        guard let runner = try? ProcessCLIRunner.makeDefault() else { return nil }
        return TranscriptSaveService(runner: runner)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let transcript {
                header(transcript)
                Picker("", selection: $tab) {
                    ForEach(RecordingDetailTab.allCases, id: \.self) { t in
                        Text(t.title).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 12)
                .padding(.bottom, 6)

                if let error = errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 12)
                }

                tabContent(transcript)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: transcriptID) {
            tab = .recap
            chatVM = nil
            await load()
        }
        .confirmationDialog(
            "Delete this recording?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete recording, notes and chat", role: .destructive) { deleteRecording() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The transcript, its meeting notes, chat and audio file will be removed. This cannot be undone.")
        }
        .sheet(item: $linkTarget) { t in
            LinkTranscriptSheet(transcript: t, onLinked: {
                Task { await load() }
                onChanged()
            })
            .environment(appState)
        }
    }

    @ViewBuilder
    private func tabContent(_ transcript: MeetingTranscript) -> some View {
        let center = appState.transcriptNotesCenter
        switch tab {
        case .recap:
            RecordingRecapTab(
                transcript: transcript,
                recapContent: recapContent,
                onRetryRecap: retryRecap,
                isRetrying: isRetryingRecap)
        case .notes:
            RecordingNotesTab(
                transcript: transcript,
                notesMD: transcript.notesMD,
                onGenerate: generateNotes,
                isGenerating: center.generating.contains(transcriptID),
                generationError: center.lastError[transcriptID],
                onSave: saveNotes)
        case .transcript:
            RecordingTranscriptTab(transcriptText: transcript.transcriptText)
        case .chat:
            if let chatVM {
                RecordingChatTab(chatVM: chatVM)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear { openChat(transcript) }
            }
        }
    }

    private func header(_ transcript: MeetingTranscript) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(transcript.title)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                Spacer()
                if transcript.eventID == nil {
                    Button {
                        linkTarget = transcript
                    } label: {
                        Label("Link to event…", systemImage: "link")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Delete recording with all its content")
            }
            HStack(spacing: 8) {
                Text(TranscriptFormatting.formattedDate(transcript.createdAt))
                Text(TranscriptFormatting.formatDuration(transcript.durationSec))
                TranscriptLangBadges(langStatsJSON: transcript.langStats)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    // MARK: - Data

    private func load() async {
        guard let db = appState.databaseManager else { return }
        do {
            let (row, recap) = try await Task.detached(priority: .userInitiated) { [transcriptID] in
                try db.dbPool.read { conn -> (MeetingTranscript?, MeetingRecap?) in
                    let row = try MeetingTranscriptQueries.fetch(conn, id: transcriptID)
                    var recap: MeetingRecap?
                    if let eventID = row?.eventID {
                        recap = try MeetingRecapQueries.fetch(conn, eventID: eventID)
                    }
                    return (row, recap)
                }
            }.value
            transcript = row
            // Event recap wins; ad-hoc (or collision-guarded) recap falls back
            // to the transcript's own summary_json. Decoded ONCE here, never
            // in row builders.
            recapContent = recap?.parsed ?? row?.parsedSummary
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func openChat(_ transcript: MeetingTranscript) {
        guard let db = appState.databaseManager else { return }
        chatVM = MeetingChatViewModel(
            transcript: transcript, recapContent: recapContent, dbManager: db)
    }

    private func retryRecap() {
        guard let service = notesService else {
            errorMessage = "watchtower CLI not found"
            return
        }
        isRetryingRecap = true
        Task {
            defer { isRetryingRecap = false }
            do {
                _ = try await service.retryRecap(transcriptID: transcriptID)
                await load()
                onChanged()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func generateNotes() {
        guard let service = notesService else {
            errorMessage = "watchtower CLI not found"
            return
        }
        appState.transcriptNotesCenter.generate(
            transcriptID: transcriptID, service: service
        ) {
            Task { await load() }
            onChanged()
        }
    }

    private func saveNotes(_ markdown: String) {
        guard let db = appState.databaseManager else { return }
        do {
            try db.dbPool.write { conn in
                try MeetingTranscriptQueries.saveNotes(conn, id: transcriptID, markdown: markdown)
            }
            onChanged()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteRecording() {
        guard let db = appState.databaseManager else { return }
        do {
            chatVM?.cancelStream()
            let audioPath = try db.dbPool.write { conn in
                try MeetingTranscriptQueries.delete(conn, id: transcriptID)
            }
            // Post-commit, best-effort: the daemon retention phase may have
            // already removed the file — a missing file is success.
            if let audioPath {
                try? FileManager.default.removeItem(atPath: audioPath)
            }
            onDeleted()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
```

(Verify `ProcessCLIRunner.makeDefault()` — use the exact factory & error shape found in `MeetingRecorderCenter.swift`/`TranscriptSectionView.swift`; if it's non-throwing, drop the `try?`.)

- [ ] **Step 4: Implement `RecordingsView.swift`** (container)

```swift
import SwiftUI

/// Master-detail container for the Calendar screen's "Recordings" tab.
/// Owns the lightweight list (RecordingListItem — never the heavy rows) and
/// the selection; reloads when the recorder finishes a run.
struct RecordingsView: View {
    @Environment(AppState.self) private var appState
    @State private var items: [RecordingListItem] = []
    @State private var selectedID: Int64?

    var body: some View {
        HStack(spacing: 0) {
            RecordingsListView(items: items, selectedID: $selectedID)
                .frame(minWidth: 300, idealWidth: 350)

            if let selectedID {
                Divider()
                RecordingDetailView(
                    transcriptID: selectedID,
                    onDeleted: {
                        self.selectedID = nil
                        loadItems()
                    },
                    onChanged: loadItems
                )
                .id(selectedID)
                .frame(minWidth: 400, idealWidth: 500)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: selectedID)
        .onAppear(perform: loadItems)
        .onChange(of: appState.meetingRecorderCenter.phase) { _, phase in
            if case .idle = phase { loadItems() }
        }
    }

    private func loadItems() {
        guard let db = appState.databaseManager else { return }
        do {
            items = try db.dbPool.read { conn in
                try MeetingTranscriptQueries.fetchRecordingList(conn)
            }
        } catch {
            // Silent: table may not exist yet on older DB schema versions.
        }
    }
}
```

- [ ] **Step 5: Run tests + build**

```bash
cd WatchtowerDesktop && swift build > /tmp/swift-build.log 2>&1; echo "build=$?" && swift test --filter RecordingDetailViewTests > /tmp/swift-test.log 2>&1; echo "test=$?"
```
Expected: `build=0`, `test=0`.

- [ ] **Step 6: Commit**

```bash
git add WatchtowerDesktop/Sources/Views/Calendar/RecordingDetailView.swift WatchtowerDesktop/Sources/Views/Calendar/RecordingsView.swift WatchtowerDesktop/Tests/RecordingDetailViewTests.swift
git commit -m "feat(desktop): RecordingDetailView with four tabs + RecordingsView container"
```

---

### Task 15: Calendar segmented control «События | Записи»

**Files:**
- Modify: `WatchtowerDesktop/Sources/Views/Calendar/CalendarEventsView.swift`
- Test: `WatchtowerDesktop/Tests/CalendarTests.swift` or a new `WatchtowerDesktop/Tests/CalendarModeTests.swift`

**Interfaces:**
- Consumes: `RecordingsView` (Task 14).
- Produces: `enum CalendarMode: String, CaseIterable { case events, recordings }` + segmented Picker at the top of `CalendarEventsView`. Removes the ad-hoc `recordingsSection`/`adHocRow`/`loadAdHocTranscripts`/`linkTarget` (recordings now live in the Recordings tab; link-to-event moved into the detail header in Task 14).

- [ ] **Step 1: Write the failing test** (`WatchtowerDesktop/Tests/CalendarModeTests.swift`)

```swift
import XCTest
@testable import WatchtowerDesktop

final class CalendarModeTests: XCTestCase {
    func test_modesInOrder() {
        XCTAssertEqual(CalendarMode.allCases.map(\.rawValue), ["events", "recordings"])
    }

    func test_titles() {
        XCTAssertEqual(CalendarMode.events.title, "Events")
        XCTAssertEqual(CalendarMode.recordings.title, "Recordings")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd WatchtowerDesktop && swift test --filter CalendarModeTests > /tmp/swift-test.log 2>&1; echo "exit=$?"
```
Expected: `exit=1`.

- [ ] **Step 3: Implement**

In `CalendarEventsView.swift`:

1. Add above the struct (or in the same file, bottom):
```swift
enum CalendarMode: String, CaseIterable {
    case events, recordings

    var title: String {
        switch self {
        case .events: return "Events"
        case .recordings: return "Recordings"
        }
    }
}
```
2. Add state: `@State private var mode: CalendarMode = .events`.
3. Restructure `body`'s connected branch:
```swift
            if googleAuth.isConnected, let calVM = appState.calendarViewModel {
                VStack(spacing: 0) {
                    Picker("", selection: $mode) {
                        ForEach(CalendarMode.allCases, id: \.self) { m in
                            Text(m.title).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 260)
                    .padding(.top, 10)

                    switch mode {
                    case .events:
                        eventsMasterDetail(calVM)
                    case .recordings:
                        RecordingsView()
                    }
                }
            } else {
                notConnectedView
            }
```
4. Extract the existing `HStack { eventsList... MeetingPrepDetailView... }` (current body lines 19–41, including the `.animation`/`.onAppear` modifiers) into `private func eventsMasterDetail(_ vm: CalendarViewModel) -> some View` unchanged.
5. Delete: `@State private var adHocTranscripts`, `@State private var linkTarget`, `recordingsSection`, `adHocRow(_:)`, `loadAdHocTranscripts()`, the `recordingsSection` reference in `eventsList`, the `.onAppear(perform: loadAdHocTranscripts)` / `.onChange` reload / `.sheet(item: $linkTarget)` modifiers on `eventsList`.

- [ ] **Step 4: Run tests + full Swift suite**

```bash
cd WatchtowerDesktop && swift build > /tmp/swift-build.log 2>&1; echo "build=$?" && swift test > /tmp/swift-test.log 2>&1; echo "test=$?"
```
Expected: `build=0`, `test=0`. If existing `CalendarEventsView`-related view tests referenced the removed ad-hoc section, update them to the new structure (the recordings list coverage moved to `RecordingsListViewTests`).

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/Sources/Views/Calendar/CalendarEventsView.swift WatchtowerDesktop/Tests/CalendarModeTests.swift WatchtowerDesktop/Tests/
git commit -m "feat(desktop): Events|Recordings segmented tab in Calendar"
```

---

### Task 16: Docs — CLAUDE.md + app-guide.md

**Files:**
- Modify: `CLAUDE.md` (Meeting Transcriber section)
- Modify: `docs/app-guide.md` (Calendar/recordings UI description — injected into the chat-bot system prompt, must reflect the new UI)

**Interfaces:** none (documentation).

- [ ] **Step 1: Update `CLAUDE.md`** — append to the Meeting Transcriber section:

```markdown
- **Recordings tab & single-view (v75+):** The Calendar screen has an Events | Recordings segmented control. Recordings (ad-hoc + event-linked) live in a master-detail list (`RecordingsView`/`RecordingsListView`/`RecordingDetailView`): master uses the lightweight `RecordingListItem` projection (never selects `transcript_text`/`summary_json` — perf guard), detail has four lazy tabs (Recap / Notes / Transcript / Chat). Recap resolution: event's `meeting_recaps` row wins, falls back to the transcript's `summary_json`.
- **Meeting notes:** `meeting_transcripts.notes_md` (migration 00017) — publishable markdown. Generated by `watchtower meeting-prep transcript notes <id>` (`meeting.notes` prompt, strong tier, transcript in the user message / stdin path like the recap; exit 1 on failure, nothing persisted). Edited in the Notes tab (debounced direct GRDB write via `MeetingTranscriptQueries.saveNotes` — a second dual-path with the CLI writer). Generation state lives in `TranscriptNotesCenter` on AppState so it survives navigation.
- **Meeting chat:** per-recording secretary chat, `chat_conversations.context_type='meeting'`, `context_id=transcript id` (`MeetingChatViewModel`). System prompt inlines a capped transcript excerpt (12k chars) and points the model at the `get_transcript` MCP tool for the full text.
- **Delete:** Swift-only transactional delete (`MeetingTranscriptQueries.delete`): transcript row + meeting chat (+messages); returns `audio_path` for post-commit best-effort file removal (missing file = success — retention may have swept it). The event's `meeting_recaps` row is NEVER deleted with the recording.
```

- [ ] **Step 2: Update `docs/app-guide.md`** — in the Calendar section, describe: the Events | Recordings segmented control; the recordings master list (title, date, duration, language badges, recap/notes indicators); the detail screen's four tabs (Recap — structured AI recap with re-generate; Notes — generate/edit/copy publishable markdown notes; Transcript — full text; Chat — discuss the meeting with the secretary); Link to event for ad-hoc recordings; the Delete button removing the recording with notes, chat and audio. Follow the file's existing tone and format.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md docs/app-guide.md
git commit -m "docs: recordings tab, meeting notes, meeting chat, delete"
```

---

### Task 17: Final verification + review

**Files:** none new.

- [ ] **Step 1: Full Go suite**

```bash
go build ./... && go vet ./... && go test ./... > /tmp/go-test.log 2>&1; echo "exit=$?"
```
Expected: `exit=0`.

- [ ] **Step 2: Full Swift suite**

```bash
cd WatchtowerDesktop && swift build > /tmp/swift-build.log 2>&1; echo "build=$?" && swift test > /tmp/swift-test.log 2>&1; echo "test=$?"
```
Expected: `build=0`, `test=0`.

- [ ] **Step 3: End-to-end sanity via CLI** (no AI provider in CI — use `--provider` only if a real provider is configured; otherwise verify command wiring only)

```bash
go run . meeting-prep transcript --help
```
Expected: `notes` listed among subcommands.

- [ ] **Step 4: Run the `local-review` skill** (per project convention: quality gate before any PR — CI mirror + review panel + triage).

- [ ] **Step 5: Update the plan checkboxes and commit any review fixes.**
