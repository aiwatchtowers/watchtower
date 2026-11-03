package hub

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"watchtower/internal/agentlog"
	"watchtower/internal/db"
	"watchtower/internal/hub/actions/handlers"
	"watchtower/internal/hub/hubtest"
	"watchtower/internal/hub/link"
	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/memfake"
	"watchtower/internal/hub/wire"
	"watchtower/internal/logcanary"
	"watchtower/internal/sessionreport"
	"watchtower/internal/workbenchgit"
)

// canaryPort is a session host where every session is live for the
// handlers and the seeded session runs for the sources (Runs), and every line
// waits behind the owner's draft (held prompt_has_text), so a phone line is
// stored in held_session_lines; starts are accepted.
type canaryPort struct {
	running int64     // the session Runs lists
	runAt   time.Time // the one run's start: a line is held for this launch
	mu      sync.Mutex
	starts  []handlers.StartRequest
	start   int64 // the row a start answers with
}

func (p *canaryPort) Live(_ context.Context, id int64) (handlers.LiveRun, bool, error) {
	return handlers.LiveRun{SessionID: id, Run: 1, Agent: "claude", StartedAt: p.runAt}, true, nil
}

func (*canaryPort) Deliver(context.Context, handlers.DeliverRequest) (handlers.DeliverResult, error) {
	return handlers.DeliverResult{Outcome: handlers.DeliverHeld, Reason: "prompt_has_text"}, nil
}

func (p *canaryPort) Runs(context.Context) (map[int64]time.Time, error) {
	return map[int64]time.Time{p.running: p.runAt}, nil
}

func (*canaryPort) Interrupt(context.Context, int64, uint64) error { return nil }

func (p *canaryPort) Start(_ context.Context, r handlers.StartRequest) (handlers.StartResult, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.starts = append(p.starts, r)
	return handlers.StartResult{SessionID: p.start, State: "starting"}, nil
}

func (*canaryPort) Stop(context.Context, int64) error { return nil }

// The markers. Source markers never reach the sidecar; the session line is
// the one action text the sidecar keeps in the clear (held_session_lines.line).
var (
	mWorkbench      = logcanary.Text("workbench.name")
	mTarget         = logcanary.Text("target.title")
	mComment        = logcanary.Text("comment.body")
	mAskQuestion    = logcanary.Text("ask.question")
	mAskAnswer      = logcanary.Text("ask.answer")
	mPermission     = logcanary.Text("permission.summary")
	mSessionTitle   = logcanary.Text("session.title")
	mSessionError   = logcanary.Text("session.error") // a failed session's milestone text
	mFinishSummary  = logcanary.Text("session.finish")
	mChat           = logcanary.Text("chat.text")
	mReportTitle    = logcanary.Text("report.title")
	mReportPhase    = logcanary.Text("report.phase") // becomes a phase milestone's text
	mReportPRNote   = logcanary.Text("report.pr_note")
	mCalendar       = logcanary.Text("calendar.title")
	mTranscriptText = logcanary.Text("transcript.text")
	mTranscriptName = logcanary.Text("transcript.title")
	mRecording      = logcanary.Text("recording.audio")
	mLine           = logcanary.Text("action.session_line")
	mAnswerNote     = logcanary.Text("action.ask_answer")
	mCommentAction  = logcanary.Text("action.comment")
	mBrief          = logcanary.Text("action.brief")
	mReplyAction    = logcanary.Text("action.comment_reply")
	mTargetAction   = logcanary.Text("action.target_create")
	mAlert          = logcanary.Text("alert.ask_title") // an ask filed while the owner is away
)

// sealedAt is where each marker must be found inside a sealed record the
// phone opens (by the record's kind; the transcript text in its sealed
// segments asset): proof each one reached the sealer. The session line, the
// brief and the recording audio never become a record: they are checked
// where they went (held_session_lines.line, the start request, the
// recordings dir).
var sealedAt = map[string]string{
	mWorkbench:      "workbench",
	mTarget:         "workbench_target",
	mComment:        "workbench_comment",
	mAskQuestion:    "owner_ask",
	mAskAnswer:      "owner_ask",
	mPermission:     "permission_request",
	mSessionTitle:   "terminal_session",
	mSessionError:   "session_timeline",
	mFinishSummary:  "terminal_session",
	mChat:           "session_chat",
	mReportTitle:    "session_report",
	mReportPhase:    "session_report",
	mReportPRNote:   "session_report",
	mCalendar:       "calendar_event",
	mTranscriptName: "meeting_transcript",
	mTranscriptText: "meeting_transcript",
	mAlert:          "ask_alert",
	mAnswerNote:     "owner_ask",
	mCommentAction:  "workbench_comment",
	mReplyAction:    "workbench_comment",
	mTargetAction:   "workbench_target",
}

// alwaysAway is an owner who is away from the Mac (the work alerts push).
type alwaysAway struct{}

func (alwaysAway) Away() (bool, error) { return true, nil }

// encodings is each marker as itself and as the protocol encodes bytes
// elsewhere (the 1a interop test's set).
func encodings(markers []string) []string {
	out := slices.Clone(markers)
	for _, c := range markers {
		out = append(out, base64.StdEncoding.EncodeToString([]byte(c)),
			base64.RawURLEncoding.EncodeToString([]byte(c)), hex.EncodeToString([]byte(c)))
	}
	return out
}

// canaryDB is a watchtower.db file holding a marker in every row a slice
// source publishes, and a Claude transcript under home for the chat.
type canaryDB struct {
	d                         *db.DB
	project, target, session  int64
	ask, started, comment     int64
	folder, home              string
	sourceMarkers, allMarkers []string
}

func seedCanaryDB(t *testing.T, home string) canaryDB {
	t.Helper()
	d, err := db.Open(filepath.Join(t.TempDir(), "watchtower.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = d.Close() })
	folder, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	c := canaryDB{d: d, folder: folder, home: home}
	id := func(q string, args ...any) int64 {
		t.Helper()
		res, err := d.Exec(q, args...)
		if err != nil {
			t.Fatalf("%v\n%s", err, q)
		}
		n, _ := res.LastInsertId()
		return n
	}
	now := time.Now().UTC()
	stamp := func(at time.Time) string { return at.UTC().Format(time.RFC3339) }

	c.project = id(`INSERT INTO projects (name, folder_path) VALUES (?, ?)`, mWorkbench, folder)
	c.target = id(`INSERT INTO targets (text, level, custom_label, period_start, period_end, status, priority, ownership, source_type, project_id)
VALUES (?, 'custom', 'project', '2026-09-29', '2026-09-29', 'todo', 'medium', 'mine', 'chat', ?)`, mTarget, c.project)
	c.comment = id(`INSERT INTO project_comments (project_id, target_id, author, body, status) VALUES (?, ?, 'agent', ?, 'open')`,
		c.project, c.target, mComment)
	conv := "00000000-0000-4000-8000-00000000c0a1"
	c.session = id(`INSERT INTO terminal_sessions (project_id, kind, title, target_id, folder_path, claude_session_id, last_active_at,
    agent_state, agent_state_at, agent_error, agent_failed_at)
VALUES (?, 'claude', ?, ?, ?, ?, ?, 'waiting', ?, ?, ?)`, c.project, mSessionTitle, c.target, folder, conv, db.AgentStateStamp(now),
		db.AgentStateStamp(now), mSessionError, db.AgentStateStamp(now)) // stopped on an error in its live run
	c.started = id(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id, finished_at, finish_summary)
VALUES (?, 'claude', 'Second', ?, '00000000-0000-4000-8000-00000000c0a2', ?, ?)`, c.project, folder, stamp(now), mFinishSummary)
	const questions = `{"questions":[{"id":"a","question":"%s","options":[{"label":"Yes"},{"label":"No"}]}]}`
	c.ask = id(`INSERT INTO owner_asks (project_id, session_id, kind, title, payload, status)
VALUES (?, ?, 'question', ?, ?, 'open')`, c.project, c.session, mAskQuestion, fmt.Sprintf(questions, mAskQuestion))
	id(`INSERT INTO owner_asks (project_id, session_id, kind, title, payload, status, answer, answered_at)
VALUES (?, ?, 'question', 'Answered', '{}', 'answered', ?, ?)`, c.project, c.started, `{"note":"`+mAskAnswer+`"}`, stamp(now))
	id(`INSERT INTO permission_requests (terminal_session_id, workbench_id, tool_name, summary, status, created_at)
VALUES (?, ?, 'Bash', ?, 'pending', ?)`, c.session, c.project, mPermission, stamp(now))
	id(`INSERT INTO calendar_calendars (id, name) VALUES ('cal', 'Work')`)
	id(`INSERT INTO calendar_events (id, calendar_id, title, start_time, end_time, attendees, event_status)
VALUES ('ev1', 'cal', ?, ?, ?, '[]', 'confirmed')`, mCalendar, stamp(now.Add(time.Hour)), stamp(now.Add(2*time.Hour)))
	segments := fmt.Sprintf(`[{"idx":0,"start_sec":0,"end_sec":1,"speaker":"A","text":%q,"deleted":false}]`, mTranscriptText)
	id(`INSERT INTO meeting_transcripts (title, transcript_text, segments_json, duration_sec, created_at, updated_at)
VALUES (?, ?, ?, 60, ?, ?)`, mTranscriptName, mTranscriptText, segments, stamp(now.Add(-time.Hour)), stamp(now.Add(-time.Hour)))

	// The session's Claude transcript, read for a phone's chat request.
	dir := filepath.Join(home, ".claude", "projects", agentlog.Slug(folder))
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	line, _ := json.Marshal(map[string]any{"type": "assistant", "uuid": "a1", "timestamp": stamp(now),
		"message": map[string]any{"id": "m1", "role": "assistant", "content": []map[string]any{{"type": "text", "text": mChat}}}})
	if err := os.WriteFile(filepath.Join(dir, conv+".jsonl"), append(line, '\n'), 0o600); err != nil {
		t.Fatal(err)
	}

	c.sourceMarkers = []string{mWorkbench, mTarget, mComment, mAskQuestion, mAskAnswer, mPermission, mSessionTitle, mSessionError,
		mFinishSummary, mChat, mReportTitle, mReportPhase, mReportPRNote, mCalendar, mTranscriptText, mTranscriptName, mRecording, mAlert}
	c.allMarkers = append(slices.Clone(c.sourceMarkers), mLine, mAnswerNote, mCommentAction, mBrief, mReplyAction, mTargetAction)
	return c
}

// TestCanary_NoPlaintextLeavesTheHub (spec §13 E2E (1), §8 p. 4a): a marker
// in every slice source's rows and in every text a phone sends; after a full
// cycle and mailbox passes no marker is in any frame or attachment on the
// fake, in the log, or anywhere in the sidecar but the two plaintext columns
// of today, and every frame is a padded envelope.
func TestCanary_NoPlaintextLeavesTheHub(t *testing.T) {
	sink := logcanary.Capture(t)
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("CODEX_HOME", filepath.Join(home, ".codex"))
	c := seedCanaryDB(t, home)
	port := &canaryPort{start: c.started, running: c.session, runAt: time.Now().Add(-time.Minute)}
	recordings := filepath.Join(t.TempDir(), "recordings")
	e := runEndToEnd(t, "", func(o *Options) {
		o.DB, o.Sessions, o.RecordingsDir = c.d, port, recordings
		o.runnerGap, o.away = 100*time.Millisecond, alwaysAway{}
		o.reportFetch = func(_ context.Context, _, sessionID int64, _ bool) (sessionreport.Report, error) {
			return sessionreport.Report{
				Session: sessionreport.Session{ID: sessionID, Title: mReportTitle, Kind: "claude"},
				Phases:  []sessionreport.Phase{{TargetID: c.target, Text: mReportPhase, StartedAt: time.Now().UTC().Format(time.RFC3339)}},
				PRNote:  mReportPRNote,
			}, nil
		}
		o.gitFetch = func(context.Context, int64) (workbenchgit.Status, error) {
			st := workbenchgit.Status{StatusOK: true, Git: true, GitAvailable: true}
			st.Branch = "feature/acme"
			return st, nil
		}
	})
	phone, fake := e.phone, e.rig.fake

	ctl, err := Dial(e.dir)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = ctl.Close() }()
	for _, g := range []link.Grant{link.GrantTyping, link.GrantStartSessions, link.GrantPermissions} {
		if a, err := ctl.Do(ControlRequest{Op: OpAllow, Device: phone.ID().String(), Grant: string(g), On: true}); err != nil || !a.OK {
			t.Fatalf("allow %s: %+v, %v", g, a, err)
		}
	}
	if a, err := ctl.Do(ControlRequest{Op: OpDesktopHeartbeat}); err != nil || !a.OK {
		t.Fatalf("heartbeat: %+v, %v", a, err)
	}
	// The alert's ask: filed after the hub was enabled (an alert counts only
	// newer asks; created_at has whole seconds, so in the next second), on the
	// running session while the owner is away.
	time.Sleep(time.Until(time.Now().Truncate(time.Second).Add(time.Second)))
	if _, err := c.d.Exec(`INSERT INTO owner_asks (project_id, session_id, kind, title, payload, status, created_at)
VALUES (?, ?, 'question', ?, '{}', 'open', ?)`, c.project, c.session, mAlert, time.Now().UTC().Format(time.RFC3339)); err != nil {
		t.Fatal(err)
	}

	wb := json.RawMessage(strconv.FormatInt(c.project, 10))
	text := func(s string) json.RawMessage { b, _ := json.Marshal(s); return b }
	entity := func(id int64) *string { s := strconv.FormatInt(id, 10); return &s }
	var seqs []uint64
	act := func(kind string, ent *string, params map[string]json.RawMessage) {
		t.Helper()
		a := phone.NewAction(kind)
		a.EntityID = ent
		for k, v := range params {
			a.Params[k] = v
		}
		seq, err := phone.Queue(a)
		if err != nil {
			t.Fatal(err)
		}
		if err := phone.Send(seq); err != nil {
			t.Fatal(err)
		}
		seqs = append(seqs, seq)
	}
	answer, _ := json.Marshal(map[string]any{
		"verdict": "", "answers": []any{map[string]any{"id": "a", "labels": []string{"Yes"}, "other": ""}},
		"checklist": []any{}, "comments": []any{}, "note": mAnswerNote,
	})
	act("session_chat_request", entity(c.session), map[string]json.RawMessage{"session_id": json.RawMessage(*entity(c.session))})
	act("session_report_request", entity(c.session), nil)
	act("session_input", entity(c.session), map[string]json.RawMessage{"text": text(mLine)})
	act("ask_answer", entity(c.ask), map[string]json.RawMessage{"workbench_id": wb, "answer": answer})
	act("board_comment_add", entity(c.target), map[string]json.RawMessage{"workbench_id": wb, "body": text(mCommentAction)})
	act("board_comment_reply", entity(c.comment), map[string]json.RawMessage{"workbench_id": wb, "body": text(mReplyAction)})
	act("board_target_create", nil, map[string]json.RawMessage{"workbench_id": wb, "text": text(mTargetAction), "priority": text("medium")})
	act("session_start", nil, map[string]json.RawMessage{"workbench_id": wb, "mode": text("new"),
		"plan_first": json.RawMessage("false"), "bring_forward": json.RawMessage("false"), "brief": text(mBrief)})

	audio := append(bytes.Repeat([]byte{0x41}, 4000), mRecording...)
	sealedAudio, desc, err := secure.EncryptAsset(audio, secure.ID{7}, bytes.Repeat([]byte{9}, 32), 1024)
	if err != nil {
		t.Fatal(err)
	}
	upload, _ := json.Marshal(map[string]any{"id": "u1", "status": "pending", "device_id": phone.ID().String()})
	if _, err := phone.WriteUpload("u1", upload, &desc, sealedAudio); err != nil {
		t.Fatal(err)
	}

	eventually(t, 20*time.Second, "an answer to every action and the upload", func() bool {
		if _, err := phone.Sync(); err != nil {
			t.Fatal(err)
		}
		for _, s := range seqs {
			switch phone.Echoes[s].Status {
			case wire.StatusApplied, wire.StatusHeld, wire.StatusFailed:
			default:
				return false
			}
		}
		return phone.UploadEchoes["u1"]["status"] == "received"
	})
	for _, s := range seqs {
		got := phone.Echoes[s]
		want := wire.StatusApplied
		if got.Kind == "session_input" { // the line waits behind the owner's draft
			want = wire.StatusHeld
		}
		if got.Status != want {
			t.Errorf("a%d (%s) echo %s (reason %v), want %s", s, got.Kind, got.Status, deref(got.Reason), want)
		}
	}
	port.mu.Lock()
	if len(port.starts) != 1 || port.starts[0].Brief != mBrief {
		t.Errorf("the start did not carry the brief: %d starts", len(port.starts))
	}
	port.mu.Unlock()
	if got, err := os.ReadFile(handlers.RecordingAudioPath(recordings, "u1")); err != nil || !bytes.Equal(got, audio) {
		t.Fatalf("the recording was not opened for the transcriber: %v", err)
	}

	// Each marker has its positive control: sealedAt, or one of the three
	// checked where they went (held line, start request, recordings dir).
	for _, m := range c.allMarkers {
		if _, ok := sealedAt[m]; !ok && m != mLine && m != mBrief && m != mRecording {
			t.Errorf("marker %s has no positive control", m)
		}
	}
	assertEveryMarkerSealed(t, e.dir, phone, fake)
	// The actions were applied with their text where it belongs.
	for q, m := range map[string]string{
		`SELECT COUNT(*) FROM project_comments WHERE body = ? AND author = 'owner' AND parent_id IS NULL`: mCommentAction,
		`SELECT COUNT(*) FROM project_comments WHERE body = ? AND parent_id IS NOT NULL`:                  mReplyAction,
		`SELECT COUNT(*) FROM targets WHERE text = ?`:                                                     mTargetAction,
		`SELECT COUNT(*) FROM owner_asks WHERE status = 'answered' AND instr(answer, ?) > 0`:              mAnswerNote,
	} {
		var n int
		if err := c.d.QueryRow(q, m).Scan(&n); err != nil || n != 1 {
			t.Errorf("%s: %d rows (%v)", m, n, err)
		}
	}
	if err := e.rig.stop(); err != nil {
		t.Fatal(err)
	}
	// The running session's error milestone is stored, its text sealed.
	if n := queryStrings(t, sidecarDB(t, e.dir), `SELECT COUNT(*) FROM session_milestones WHERE session_id = ?`, c.session); n[0] == "0" {
		t.Error("no state milestone stored for the failed running session")
	}

	assertNothingReadableLeft(t, e.dir, fake, sink, encodings(c.allMarkers))
}

// assertEveryMarkerSealed: the phone opens the data zone with its keybox keys
// and finds each sealedAt marker in a record of its kind, and every
// published kind has a record (a source that publishes nothing fails) —
// proof each marker reached the sealer.
func assertEveryMarkerSealed(t *testing.T, dir string, phone *hubtest.Phone, fake *memfake.Fake) {
	t.Helper()
	status, err := ReadStatus(dir)
	if err != nil {
		t.Fatal(err)
	}
	data := transport.DataZone(status.RelayDeviceID)
	kinds := []string{"workbench", "workbench_target", "workbench_comment", "terminal_session", "session_timeline", "owner_ask",
		"permission_request", "ask_alert", "session_chat", "session_report", "calendar_event", "meeting_transcript", "recording_job"}
	var missing []string
	deadline := time.Now().Add(30 * time.Second)
	for {
		missing = missingSealed(t, phone, fake.Attachments(), data, kinds)
		if len(missing) == 0 || time.Now().After(deadline) {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	if len(missing) > 0 {
		t.Fatalf("not found sealed where expected: %v", missing)
	}
}

// assertNothingReadableLeft: no marker (in any encoding) in a frame or
// attachment on the fake, in the log, in a sidecar cell but today's two
// plaintext columns, or in any file of the hub dir but the session line in
// the sidecar's own files; the Swift-only columns stay empty, no pairing
// request outlives its link, and every hub_meta key is a known one.
func assertNothingReadableLeft(t *testing.T, dir string, fake *memfake.Fake, sink *logcanary.Sink, all []string) {
	t.Helper()
	// (a) Frames and attachments on the fake.
	frames := fake.Frames()
	if len(frames) == 0 {
		t.Fatal("no frames")
	}
	for i, f := range frames {
		h, err := secure.ParseHeader(f)
		if err != nil {
			t.Fatalf("frame %d is not an envelope: %v", i, err)
		}
		if h.Flags&secure.FlagPadded == 0 {
			t.Errorf("frame %d (class %d) is not padded", i, h.Class)
		}
		for _, m := range all {
			if bytes.Contains(f, []byte(m)) {
				t.Errorf("frame %d carries %q in the clear", i, m)
			}
		}
	}
	atts := fake.Attachments()
	if len(atts) < 2 { // the phone's upload and the hub's transcript asset
		t.Fatalf("attachments %d, want the upload and the transcript asset", len(atts))
	}
	for id, b := range atts {
		for _, m := range all {
			if bytes.Contains(b, []byte(m)) {
				t.Errorf("attachment %s carries %q in the clear", id, m)
			}
		}
	}
	// (b) The log.
	sink.AssertClean(t)
	for _, m := range all {
		if strings.Contains(sink.String(), m) {
			t.Errorf("the log carries %q", m)
		}
	}
	// (c) The sidecar: no marker in any cell but held_session_lines.line and
	// relay_processed.echo, and none at all in the file's bytes but the
	// session line (the one action text such a column holds today).
	cells := sidecarMarkerCells(t, dir, all)
	for cell, marks := range cells {
		if _, ok := plaintextToday[cell]; !ok {
			t.Errorf("sidecar %s carries %v", cell, marks)
		}
	}
	if !slices.Contains(cells["held_session_lines.line"], mLine) {
		t.Errorf("the held line is not in held_session_lines.line (positive control): %v", cells)
	}
	// Every file in the hub dir (sidecar, its WAL, the staged sealed
	// assets, the identity…): no marker but the session line, and that only
	// in the sidecar's own files.
	allowedRaw := encodings([]string{mLine})
	var files []string
	if err := filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
		if err == nil && d.Type().IsRegular() {
			files = append(files, path)
		}
		return err
	}); err != nil {
		t.Fatal(err)
	}
	for _, path := range files {
		b, err := os.ReadFile(path) // #nosec G304 -- the test's own hub dir
		if err != nil {
			t.Fatal(err)
		}
		sidecar := strings.HasPrefix(filepath.Base(path), state.FileName)
		for _, m := range all {
			if sidecar && slices.Contains(allowedRaw, m) {
				continue
			}
			if bytes.Contains(b, []byte(m)) {
				t.Errorf("%s carries %q", strings.TrimPrefix(path, dir), m)
			}
		}
	}
	// The Swift-only columns stay empty under the Go hub, and no pairing
	// request's code or confirm nonce outlives the link.
	sd := sidecarDB(t, dir)
	for _, q := range []string{
		`SELECT COUNT(*) FROM phone_recordings WHERE audio_path IS NOT NULL OR error IS NOT NULL`,
		`SELECT COUNT(*) FROM slice_assets`,
		`SELECT COUNT(*) FROM pending_devices`,
	} {
		if n := queryStrings(t, sd, q); n[0] != "0" {
			t.Errorf("%s = %s, want 0", q, n[0])
		}
	}
	// Every hub_meta key is a known one (its value is no content).
	for _, k := range sidecarMetaKeys(t, dir) {
		if _, ok := hubMetaKeys[k]; !ok {
			t.Errorf("hub_meta key %q is not in the allowlist", k)
		}
	}
}

// plaintextToday is spec §8 p. 4a's allowlist: the only sidecar columns that
// hold readable text today (state.TestSidecarHasNoNewUnsealedContentColumns
// pins the same pair).
var plaintextToday = map[string]bool{"held_session_lines.line": true, "relay_processed.echo": true}

// hubMetaKeys is every hub_meta key the Go hub writes, each holding no
// content: ids, counts, flags, times, a sealed key, or the hub's own name.
var hubMetaKeys = map[string]string{
	state.MetaHubID:               "id",
	state.MetaEnabledAt:           "timestamp",
	state.MetaKMetaSealed:         "sealed",
	state.MetaSeqCeiling:          "counter",
	state.MetaHubImpl:             "enum",
	state.MetaEnabled:             "flag",
	state.MetaDisplayName:         "label", // the owner's own name for the hub
	state.MetaDesktopAt:           "timestamp",
	state.MetaDesktopSeen:         "flag", // Plan 1b's; no longer written
	state.MetaDesktopSeenAt:       "timestamp",
	state.MetaRecordings:          "enum",
	state.MetaSyncGeneration:      "counter",
	state.MetaWorkAlertsStartedAt: "timestamp",
	state.MetaWorkAlertsAwaySince: "timestamp",
	"handlers_held_asks":          "id", // ask, session and run ids
	"hygiene_last_run":            "timestamp",
}

// sidecarDB opens the stopped hub's sidecar read-only.
func sidecarDB(t *testing.T, dir string) *db.DB {
	t.Helper()
	d, err := db.OpenExisting(filepath.Join(dir, state.FileName), time.Second)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = d.Close() })
	return d
}

// sidecarMarkerCells is every table.column of the sidecar whose cells hold
// one of markers, with the markers found.
func sidecarMarkerCells(t *testing.T, dir string, markers []string) map[string][]string {
	t.Helper()
	d := sidecarDB(t, dir)
	tables := queryStrings(t, d, `SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'`)
	out := map[string][]string{}
	for _, table := range tables {
		for _, col := range queryStrings(t, d, `SELECT name FROM pragma_table_info(?)`, table) {
			key := table + "." + col
			for _, v := range columnCells(t, d, table, col) {
				for _, m := range markers {
					if bytes.Contains(v, []byte(m)) && !slices.Contains(out[key], m) {
						out[key] = append(out[key], m)
					}
				}
			}
		}
	}
	return out
}

// columnCells is every cell of table.col as bytes.
func columnCells(t *testing.T, d *db.DB, table, col string) [][]byte {
	t.Helper()
	rows, err := d.Query(`SELECT CAST("` + col + `" AS BLOB) FROM "` + table + `"`)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = rows.Close() }()
	var out [][]byte
	for rows.Next() {
		var v []byte
		if err := rows.Scan(&v); err != nil {
			t.Fatal(err)
		}
		out = append(out, v)
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	return out
}

func sidecarMetaKeys(t *testing.T, dir string) []string {
	t.Helper()
	return queryStrings(t, sidecarDB(t, dir), `SELECT key FROM hub_meta ORDER BY key`)
}

func queryStrings(t *testing.T, d *db.DB, q string, args ...any) []string {
	t.Helper()
	rows, err := d.Query(q, args...)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = rows.Close() }()
	var out []string
	for rows.Next() {
		var s string
		if err := rows.Scan(&s); err != nil {
			t.Fatal(err)
		}
		out = append(out, s)
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	return out
}

// missingSealed opens the data zone as the phone does and lists what is
// not there yet: a kind with no record ("kind:<k>"), or a marker absent from
// every record of its sealedAt kind ("<marker>@<kind>"), a record's sealed
// asset (decrypted with its descriptor) counting as its content.
func missingSealed(t *testing.T, p *hubtest.Phone, atts map[string][]byte, zone string, kinds []string) []string {
	t.Helper()
	recs, err := p.OpenData(zone)
	if err != nil {
		t.Fatal(err)
	}
	content := map[string][][]byte{}
	for _, r := range recs {
		k := r.Frame.Kind
		content[k] = append(content[k], r.Frame.Payload)
		if r.Frame.Asset == nil {
			continue
		}
		sealed, ok := atts[r.AttachmentID]
		if !ok {
			return []string{"asset of " + k}
		}
		plain, err := secure.DecryptAsset(sealed, *r.Frame.Asset)
		if err != nil {
			t.Fatalf("the %s asset does not open: %v", k, err)
		}
		content[k] = append(content[k], plain)
	}
	var missing []string
	for _, k := range kinds {
		if len(content[k]) == 0 {
			missing = append(missing, "kind:"+k)
		}
	}
	for m, k := range sealedAt {
		if !slices.ContainsFunc(content[k], func(b []byte) bool { return bytes.Contains(b, []byte(m)) }) {
			missing = append(missing, m+"@"+k)
		}
	}
	slices.Sort(missing)
	return missing
}

func deref(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}
