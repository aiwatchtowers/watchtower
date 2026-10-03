package tools

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/workbenchfiles"
)

// askRegistry is a workbench registry whose ask tools read the terminal
// session from env instead of the process environment.
func askRegistry(t *testing.T, d *db.DB, env string) *Registry {
	t.Helper()
	getenv := func() string { return env }
	reg := New(d)
	for _, tool := range WorkbenchTools(workbenchfiles.New(t.TempDir())) {
		switch tool.Name {
		case "ask_owner":
			tool = NewAskOwner(getenv)
		case "list_asks":
			tool = NewListAsks(getenv)
		}
		require.NoError(t, reg.Register(tool))
	}
	return reg
}

func seedTerminalSession(t *testing.T, d *db.DB, projectID int64) int64 {
	t.Helper()
	res, err := d.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id)
		VALUES (?, 'claude', 'New session', '/tmp/acme', 'uuid')`, projectID)
	require.NoError(t, err)
	id, err := res.LastInsertId()
	require.NoError(t, err)
	return id
}

const questionAsk = `{"kind":"question","title":"Which store?","questions":[{"question":"Where?",` +
	`"options":[{"label":"SQLite"},{"label":"Files"}]}],"reason":"blocked on a decision"}`

// answerAsk writes the owner's answer the way the Desktop does (open -> answered).
func answerAsk(t *testing.T, d *db.DB, id int64, answer string) {
	t.Helper()
	res, err := d.Exec(`UPDATE owner_asks SET status = 'answered', answer = ?,
		answered_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ? AND status = 'open'`, answer, id)
	require.NoError(t, err)
	n, err := res.RowsAffected()
	require.NoError(t, err)
	require.EqualValues(t, 1, n)
}

func askID(t *testing.T, out map[string]any) int64 {
	t.Helper()
	id, ok := out["ask_id"].(float64)
	require.True(t, ok, "ask_id %T in %v", out["ask_id"], out)
	return int64(id)
}

func storedAsk(t *testing.T, d *db.DB, projectID, id int64) *db.OwnerAsk {
	t.Helper()
	a, err := d.GetOwnerAsk(projectID, id)
	require.NoError(t, err)
	return a
}

func refusal(t *testing.T, err error) string {
	t.Helper()
	var verr *ValidationError
	require.ErrorAs(t, err, &verr)
	return verr.Msg
}

func TestAskOwner_FilesAnOpenAskWithItsAuditRow(t *testing.T) {
	fx := newWorkbenchFixture(t)
	reg := askRegistry(t, fx.d, "")
	out := mustApply(t, reg, fx.a, "ask_owner", fmt.Sprintf(`{"kind":"question","title":"  Which store?  ",
		"summary":" Two options. ","questions":[{"question":"Where?","options":[{"label":"SQLite"},{"label":"Files"}]}],
		"target_id":%d,"reason":"blocked on a decision"}`, fx.aTarget))
	id := askID(t, out)
	assert.Equal(t, "open", out["status"])
	assert.Equal(t, false, out["session_bound"])
	assert.NotContains(t, out, "superseded")

	a := storedAsk(t, fx.d, fx.a, id)
	assert.Equal(t, "Which store?", a.Title, "stored trimmed")
	assert.Equal(t, "Two options.", a.Summary)
	assert.Equal(t, fx.aTarget, a.TargetID.Int64)
	assert.False(t, a.SessionID.Valid)
	assert.Contains(t, a.Payload, `"id":"1"`, "the payload stores the filled-in ids")

	var tool, reason, status string
	require.NoError(t, fx.d.QueryRow(`SELECT tool, reason, status FROM agent_actions ORDER BY id DESC LIMIT 1`).
		Scan(&tool, &reason, &status))
	assert.Equal(t, []string{"ask_owner", "blocked on a decision", "applied"}, []string{tool, reason, status})
}

func TestAskOwner_RefusesBadInputWithoutWriting(t *testing.T) {
	fx := newWorkbenchFixture(t)
	reg := askRegistry(t, fx.d, "")
	for args, want := range map[string]string{
		`{"kind":"poll","title":"x","reason":"r"}`:                                            "kind: must be review, check or question",
		`{"kind":"check","title":"x","checklist":[],"reason":"r"}`:                            "checklist:",
		`{"kind":"question","title":"x","questions":[],"reason":"r"}`:                         "questions:",
		`{"kind":"check","title":"x","target_id":%d,"checklist":[{"text":"a"}],"reason":"r"}`: "target_id: target %d is not in this workbench",
	} {
		if strings.Contains(args, "%d") {
			args, want = fmt.Sprintf(args, fx.bTarget), fmt.Sprintf(want, fx.bTarget)
		}
		_, err := proposeIn(t, reg, fx.a, "ask_owner", args)
		assert.Contains(t, refusal(t, err), want, args)
	}
	var n int
	require.NoError(t, fx.d.QueryRow(`SELECT (SELECT COUNT(*) FROM owner_asks) + (SELECT COUNT(*) FROM agent_actions)`).Scan(&n))
	assert.Zero(t, n, "a refused ask writes neither an ask nor an audit row")
}

func TestAskOwner_TheOpenCapIsTheAgentFacingText(t *testing.T) {
	fx := newWorkbenchFixture(t)
	reg := askRegistry(t, fx.d, "")
	for i := 0; i < 30; i++ {
		mustApply(t, reg, fx.a, "ask_owner", questionAsk)
	}
	var actions int
	require.NoError(t, fx.d.QueryRow(`SELECT COUNT(*) FROM agent_actions`).Scan(&actions))
	_, err := proposeIn(t, reg, fx.a, "ask_owner", questionAsk)
	assert.Equal(t, "too many open asks (30) — withdraw or wait for answers", refusal(t, err))
	var after int
	require.NoError(t, fx.d.QueryRow(`SELECT COUNT(*) FROM agent_actions`).Scan(&after))
	assert.Equal(t, actions, after, "an over-cap ask records no failed action")

	// A follow-up that supersedes an open ask replaces it, so it still fits.
	var last int64
	require.NoError(t, fx.d.QueryRow(`SELECT MAX(id) FROM owner_asks`).Scan(&last))
	out := mustApply(t, reg, fx.a, "ask_owner", fmt.Sprintf(`{"kind":"question","title":"Again",`+
		`"questions":[{"question":"Where?","options":[{"label":"SQLite"},{"label":"Files"}]}],"previous_ask_id":%d,"reason":"r"}`, last))
	assert.EqualValues(t, last, out["superseded"])
}

func TestAskOwner_SessionBinding(t *testing.T) {
	fx := newWorkbenchFixture(t)
	mine := seedTerminalSession(t, fx.d, fx.a)
	theirs := seedTerminalSession(t, fx.d, fx.b)
	for env, want := range map[string]int64{
		strconv.FormatInt(mine, 10):       mine,
		" " + strconv.FormatInt(mine, 10): mine,
		strconv.FormatInt(theirs, 10):     0,
		"999999":                          0,
		"garbage":                         0,
		"-3":                              0,
		"":                                0,
	} {
		reg := askRegistry(t, fx.d, env)
		out := mustApply(t, reg, fx.a, "ask_owner", questionAsk)
		a := storedAsk(t, fx.d, fx.a, askID(t, out))
		assert.Equal(t, want != 0, out["session_bound"], "env %q", env)
		assert.Equal(t, want != 0, a.SessionID.Valid, "env %q", env)
		assert.Equal(t, want, a.SessionID.Int64, "env %q", env)
	}
}

func TestAskOwner_ReviewSnapshotsTheFileExactly(t *testing.T) {
	fx := newWorkbenchFixture(t)
	reg := askRegistry(t, fx.d, "")
	text := "# Spec ü\n\nLine one.\r\n  trailing space \n"
	writeWorkbenchFile(t, fx.d, fx.a, "docs/spec.markdown", text)
	out := mustApply(t, reg, fx.a, "ask_owner",
		`{"kind":"review","title":"Review the spec","doc_path":"docs/spec.markdown","reason":"spec ready"}`)
	a := storedAsk(t, fx.d, fx.a, askID(t, out))
	assert.Equal(t, "docs/spec.markdown", a.DocPath)
	assert.Equal(t, text, a.DocSnapshot)
	assert.NotContains(t, out, "index_warning")

	var n int
	require.NoError(t, fx.d.QueryRow(`SELECT COUNT(*) FROM kb_documents WHERE source = 'project_doc'`).Scan(&n))
	assert.Equal(t, 1, n, "the reviewed file is indexed")
}

func TestAskOwner_ReviewRefusesAnyFileItMustNotRead(t *testing.T) {
	fx := newWorkbenchFixture(t)
	reg := askRegistry(t, fx.d, "")
	p, err := fx.d.GetWorkbench(fx.a)
	require.NoError(t, err)
	outside := filepath.Join(t.TempDir(), "secret.md")
	require.NoError(t, os.WriteFile(outside, []byte("secret"), 0o644))
	require.NoError(t, os.Symlink(outside, filepath.Join(p.FolderPath, "link.md")))
	writeWorkbenchFile(t, fx.d, fx.a, "main.go", "package main\n")
	writeWorkbenchFile(t, fx.d, fx.a, "big.md", strings.Repeat("a", 2<<20+1))
	writeWorkbenchFile(t, fx.d, fx.a, "latin1.md", "caf\xe9\n")
	writeWorkbenchFile(t, fx.d, fx.a, "max.md", strings.Repeat("a", 2<<20))

	for name, path := range map[string]string{
		"outside":           outside,
		"dot-dot":           "../secret.md",
		"symlink escaping":  "link.md",
		"a .go file":        "main.go",
		"2 MiB + 1":         "big.md",
		"not UTF-8":         "latin1.md",
		"missing":           "nope.md",
		"the folder itself": ".",
	} {
		_, err := proposeIn(t, reg, fx.a, "ask_owner",
			fmt.Sprintf(`{"kind":"review","title":"Review","doc_path":%q,"reason":"r"}`, path))
		assert.True(t, strings.HasPrefix(refusal(t, err), "doc_path: "), name)
	}
	var n int
	require.NoError(t, fx.d.QueryRow(`SELECT COUNT(*) FROM owner_asks`).Scan(&n))
	assert.Zero(t, n)

	// Exactly 2 MiB passes (checked below the tool: indexing a 2 MiB file
	// through ask_owner costs seconds).
	_, text, err := readReviewDoc(p.FolderPath, "max.md")
	require.NoError(t, err)
	assert.Len(t, text, 2<<20)
}

// folderState is every entry of root with its content hash (files) and mtime.
func folderState(t *testing.T, root string) map[string]string {
	t.Helper()
	out := map[string]string{}
	r, err := os.OpenRoot(root)
	require.NoError(t, err)
	t.Cleanup(func() { _ = r.Close() })
	require.NoError(t, fs.WalkDir(r.FS(), ".", func(path string, _ fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		info, err := r.Lstat(path)
		if err != nil {
			return err
		}
		state := info.ModTime().String() + " " + info.Mode().String()
		if info.Mode().IsRegular() {
			b, err := r.ReadFile(path)
			if err != nil {
				return err
			}
			sum := sha256.Sum256(b)
			state += " " + hex.EncodeToString(sum[:])
		}
		out[path] = state
		return nil
	}))
	return out
}

// PROJ-03 (amended 2026-10-03): no workbench tool writes a file in the
// folder — ask_owner only reads its doc_path, and filing, superseding,
// reading and withdrawing the ask leave the tree byte- and mtime-identical.
func TestProj03_AskOwnerNeverWritesTheFolder(t *testing.T) {
	fx := newWorkbenchFixture(t)
	mine := seedTerminalSession(t, fx.d, fx.a)
	reg := askRegistry(t, fx.d, strconv.FormatInt(mine, 10))
	p, err := fx.d.GetWorkbench(fx.a)
	require.NoError(t, err)
	writeWorkbenchFile(t, fx.d, fx.a, "docs/spec.md", "# Spec\n\nBody.\n")
	writeWorkbenchFile(t, fx.d, fx.a, "notes.txt", "notes\n")
	before := folderState(t, p.FolderPath)

	first := askID(t, mustApply(t, reg, fx.a, "ask_owner",
		`{"kind":"review","title":"Review","doc_path":"docs/spec.md","reason":"r"}`))
	second := askID(t, mustApply(t, reg, fx.a, "ask_owner", fmt.Sprintf(
		`{"kind":"review","title":"Review again","doc_path":"docs/spec.md","previous_ask_id":%d,"changes":"tightened","reason":"r"}`, first)))
	answerAsk(t, fx.d, second, `{"verdict":"changes","comments":[{"quote":"Body.","body":"Say more."}]}`)
	callReadIn(t, reg, fx.a, "get_ask", fmt.Sprintf(`{"ask_id":%d}`, second))
	callReadIn(t, reg, fx.a, "list_asks", `{"status":"all"}`)
	third := askID(t, mustApply(t, reg, fx.a, "ask_owner", questionAsk))
	mustApply(t, reg, fx.a, "withdraw_ask", fmt.Sprintf(`{"ask_id":%d,"reason":"moot"}`, third))

	assert.Equal(t, before, folderState(t, p.FolderPath))
}

func TestAskOwner_Supersede(t *testing.T) {
	fx := newWorkbenchFixture(t)
	reg := askRegistry(t, fx.d, "")
	first := askID(t, mustApply(t, reg, fx.a, "ask_owner", questionAsk))
	out := mustApply(t, reg, fx.a, "ask_owner", fmt.Sprintf(`{"kind":"question","title":"Which store, again?",`+
		`"questions":[{"question":"Where?","options":[{"label":"SQLite"},{"label":"Files"}]}],"previous_ask_id":%d,"reason":"r"}`, first))
	assert.EqualValues(t, first, out["superseded"])
	prev := storedAsk(t, fx.d, fx.a, first)
	assert.Equal(t, []string{"withdrawn", "superseded"}, []string{prev.Status, prev.WithdrawnReason})
	assert.Equal(t, first, storedAsk(t, fx.d, fx.a, askID(t, out)).PreviousAskID.Int64)

	other := askID(t, mustApply(t, askRegistry(t, fx.d, ""), fx.b, "ask_owner", questionAsk))
	for args, want := range map[string]string{
		fmt.Sprintf(`{"kind":"question","title":"x","questions":[{"question":"q","options":[{"label":"a"},{"label":"b"}]}],"previous_ask_id":%d,"reason":"r"}`, other): fmt.Sprintf("previous_ask_id: no ask with id %d", other),
		fmt.Sprintf(`{"kind":"check","title":"x","checklist":[{"text":"a"}],"previous_ask_id":%d,"reason":"r"}`, first):                                                fmt.Sprintf("previous_ask_id: ask %d is a question ask, not a check ask", first),
	} {
		_, err := proposeIn(t, reg, fx.a, "ask_owner", args)
		assert.Equal(t, want, refusal(t, err))
	}
	assert.Equal(t, "open", storedAsk(t, fx.d, fx.b, other).Status, "another workbench's ask is never superseded")
}

func TestGetAsk_OpenAnsweredAndAnotherWorkbench(t *testing.T) {
	fx := newWorkbenchFixture(t)
	reg := askRegistry(t, fx.d, "")
	id := askID(t, mustApply(t, reg, fx.a, "ask_owner", questionAsk))

	got := callReadIn(t, reg, fx.a, "get_ask", fmt.Sprintf(`{"ask_id":%d}`, id))
	assert.Contains(t, got, `"status":"open"`)
	assert.NotContains(t, got, `"answer"`)
	assert.NotContains(t, got, `"answer_text"`)
	assert.Equal(t, "open", storedAsk(t, fx.d, fx.a, id).Status, "reading an open ask changes nothing")

	answerAsk(t, fx.d, id, `{"answers":[{"id":"1","labels":["SQLite"]}],"note":"keep it simple"}`)
	got = callReadIn(t, reg, fx.a, "get_ask", fmt.Sprintf(`{"ask_id":%d}`, id))
	var view map[string]any
	require.NoError(t, json.Unmarshal([]byte(got), &view))
	assert.Equal(t, "delivered", view["status"])
	assert.Equal(t, "question", view["kind"])
	assert.Equal(t, "Which store?", view["title"])
	answer, ok := view["answer"].(map[string]any)
	require.True(t, ok, "answer is structured JSON: %s", got)
	assert.Equal(t, "keep it simple", answer["note"])
	assert.Contains(t, view["answer_text"], "→ SQLite")
	assert.Contains(t, view["answer_text"], "Note: keep it simple")
	a := storedAsk(t, fx.d, fx.a, id)
	assert.Equal(t, "delivered", a.Status)
	assert.NotEmpty(t, a.DeliveredAt)

	again := callReadIn(t, reg, fx.a, "get_ask", fmt.Sprintf(`{"ask_id":%d}`, id))
	assert.Contains(t, again, `"answer_text"`, "a delivered ask still reads its answer")

	_, err := reg.CallRead(context.Background(), "get_ask", json.RawMessage(fmt.Sprintf(`{"ask_id":%d}`, id)), directBinding(fx.b))
	assert.Equal(t, fmt.Sprintf("no ask with id %d", id), refusal(t, err))
}

func TestGetAsk_AnInvalidStoredAnswerIsAnErrorAndStaysAnswered(t *testing.T) {
	fx := newWorkbenchFixture(t)
	reg := askRegistry(t, fx.d, "")
	id := askID(t, mustApply(t, reg, fx.a, "ask_owner", questionAsk))
	answerAsk(t, fx.d, id, `{"answers":[{"id":"1","labels":["Postgres"]}]}`)
	_, err := reg.CallRead(context.Background(), "get_ask", json.RawMessage(fmt.Sprintf(`{"ask_id":%d}`, id)), directBinding(fx.a))
	require.Error(t, err)
	assert.Equal(t, "answered", storedAsk(t, fx.d, fx.a, id).Status)
}

func TestListAsks_DefaultOrderAndFilters(t *testing.T) {
	fx := newWorkbenchFixture(t)
	mine := seedTerminalSession(t, fx.d, fx.a)
	reg := askRegistry(t, fx.d, strconv.FormatInt(mine, 10))
	unbound := askRegistry(t, fx.d, "")
	open1 := askID(t, mustApply(t, reg, fx.a, "ask_owner", questionAsk))
	answered := askID(t, mustApply(t, reg, fx.a, "ask_owner", questionAsk))
	delivered := askID(t, mustApply(t, reg, fx.a, "ask_owner", questionAsk))
	withdrawn := askID(t, mustApply(t, reg, fx.a, "ask_owner", questionAsk))
	open2 := askID(t, mustApply(t, unbound, fx.a, "ask_owner", questionAsk))
	answerAsk(t, fx.d, answered, `{"answers":[{"id":"1","labels":["Files"]}]}`)
	answerAsk(t, fx.d, delivered, `{"answers":[{"id":"1","labels":["Files"]}]}`)
	callReadIn(t, reg, fx.a, "get_ask", fmt.Sprintf(`{"ask_id":%d}`, delivered))
	mustApply(t, reg, fx.a, "withdraw_ask", fmt.Sprintf(`{"ask_id":%d,"reason":"moot"}`, withdrawn))
	mustApply(t, reg, fx.b, "ask_owner", questionAsk)

	ids := func(args string) []int64 {
		var rows []struct {
			AskID int64 `json:"ask_id"`
		}
		require.NoError(t, json.Unmarshal([]byte(callReadIn(t, reg, fx.a, "list_asks", args)), &rows))
		out := []int64{}
		for _, r := range rows {
			out = append(out, r.AskID)
		}
		return out
	}
	assert.Equal(t, []int64{answered, open2, open1}, ids(`{}`), "answered and undelivered first, then open")
	assert.Equal(t, []int64{open2, open1}, ids(`{"status":"open"}`))
	assert.Equal(t, []int64{answered, delivered}, ids(`{"status":"answered"}`))
	assert.Equal(t, []int64{answered, open2, open1, withdrawn, delivered}, ids(`{"status":"all"}`))
	assert.Equal(t, []int64{answered, open1}, ids(`{"session":"mine"}`))

	row := callReadIn(t, reg, fx.a, "list_asks", `{"status":"answered"}`)
	assert.Contains(t, row, fmt.Sprintf(`"session_id":%d`, mine))
	assert.Contains(t, row, `"answered_at":"2`)
	// Every row carries both keys: session_id null when unbound, answered_at
	// empty until answered.
	unboundOpen := callReadIn(t, reg, fx.a, "list_asks", `{"status":"open"}`)
	assert.Contains(t, unboundOpen, fmt.Sprintf(`{"ask_id":%d,"kind":"question","title":"Which store?","status":"open","session_id":null,`, open2))
	assert.Contains(t, unboundOpen, `"answered_at":""`)

	_, err := unbound.CallRead(context.Background(), "list_asks", json.RawMessage(`{"session":"mine"}`), directBinding(fx.a))
	assert.Contains(t, refusal(t, err), "session")
	_, err = reg.CallRead(context.Background(), "list_asks", json.RawMessage(`{"status":"closed"}`), directBinding(fx.a))
	assert.Contains(t, refusal(t, err), "status")
}

func TestWithdrawAsk(t *testing.T) {
	fx := newWorkbenchFixture(t)
	reg := askRegistry(t, fx.d, "")
	id := askID(t, mustApply(t, reg, fx.a, "ask_owner", questionAsk))
	out := mustApply(t, reg, fx.a, "withdraw_ask", fmt.Sprintf(`{"ask_id":%d,"reason":"found it myself"}`, id))
	assert.Equal(t, map[string]any{"ask_id": float64(id), "status": "withdrawn"}, out)
	a := storedAsk(t, fx.d, fx.a, id)
	assert.Equal(t, []string{"withdrawn", "agent"}, []string{a.Status, a.WithdrawnReason})
	var reason string
	require.NoError(t, fx.d.QueryRow(`SELECT reason FROM agent_actions WHERE tool = 'withdraw_ask'`).Scan(&reason))
	assert.Equal(t, "found it myself", reason, "the free-text reason lands in the audit row")

	answered := askID(t, mustApply(t, reg, fx.a, "ask_owner", questionAsk))
	answerAsk(t, fx.d, answered, `{"answers":[{"id":"1","labels":["Files"]}]}`)
	for ask, want := range map[int64]string{
		answered: fmt.Sprintf("ask %d is answered", answered),
		id:       fmt.Sprintf("ask %d is withdrawn", id),
	} {
		_, err := proposeIn(t, reg, fx.a, "withdraw_ask", fmt.Sprintf(`{"ask_id":%d,"reason":"r"}`, ask))
		assert.Equal(t, want, refusal(t, err))
	}
	other := askID(t, mustApply(t, reg, fx.b, "ask_owner", questionAsk))
	_, err := proposeIn(t, reg, fx.a, "withdraw_ask", fmt.Sprintf(`{"ask_id":%d,"reason":"r"}`, other))
	assert.Equal(t, fmt.Sprintf("no ask with id %d", other), refusal(t, err))
	assert.Equal(t, "open", storedAsk(t, fx.d, fx.b, other).Status)
}

// Spec 2026-10-03 §4: the four ask tools are workbench tools; ask_owner and
// withdraw_ask write (direct apply, audited), get_ask and list_asks read.
func TestAskTools_AreWorkbenchTools(t *testing.T) {
	access := map[string]Access{}
	for _, tool := range WorkbenchTools(workbenchfiles.Store{}) {
		access[tool.Name] = tool.Access
		assert.Equal(t, workbenchSurfaces, tool.Surfaces, tool.Name)
	}
	assert.Equal(t, AccessWrite, access["ask_owner"])
	assert.Equal(t, AccessWrite, access["withdraw_ask"])
	assert.Equal(t, AccessRead, access["get_ask"])
	assert.Equal(t, AccessRead, access["list_asks"])
	assert.NotContains(t, access, "attach_document")
}

// The review read goes through an os.Root on the folder: a file that became
// a symlink out of the folder after ResolveWorkbenchDocumentPath checked it
// is still refused (the swap is simulated by reading past the check).
func TestReadInsideFolder_RefusesASymlinkOutOfTheFolder(t *testing.T) {
	folder := t.TempDir()
	outside := filepath.Join(t.TempDir(), "secret.md")
	require.NoError(t, os.WriteFile(outside, []byte("secret"), 0o644))
	require.NoError(t, os.WriteFile(filepath.Join(folder, "real.md"), []byte("real"), 0o644))
	require.NoError(t, os.Symlink(outside, filepath.Join(folder, "spec.md")))
	require.NoError(t, os.Symlink("real.md", filepath.Join(folder, "inside.md")))

	_, err := readInsideFolder(folder, "spec.md", 100)
	require.Error(t, err)
	data, err := readInsideFolder(folder, "inside.md", 100)
	require.NoError(t, err, "a symlink inside the folder still reads")
	assert.Equal(t, "real", string(data))
}

// A FIFO swapped in after checkDocumentFile passed must not block the read
// (and with it the ask_owner call): the open is non-blocking and the opened
// file must be regular.
func TestReadInsideFolder_RefusesAFIFOWithoutBlocking(t *testing.T) {
	folder := t.TempDir()
	require.NoError(t, syscall.Mkfifo(filepath.Join(folder, "spec.md"), 0o600))

	done := make(chan error, 1)
	go func() {
		_, err := readInsideFolder(folder, "spec.md", 100)
		done <- err
	}()
	select {
	case err := <-done:
		require.ErrorIs(t, err, errNotRegularFile)
	case <-time.After(5 * time.Second):
		t.Fatal("reading a FIFO blocked")
	}

	_, _, err := readReviewDoc(folder, "spec.md")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "doc_path: ")
}
