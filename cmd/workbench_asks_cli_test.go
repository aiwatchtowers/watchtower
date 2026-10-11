package cmd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
)

// asksFixture is two workbenches with a session and an ask of every kind,
// status and origin.
type asksFixture struct {
	database                     *db.DB
	acme, other                  int64
	session                      int64
	quick, check, review, chat   int64
	withdrawn, broken, elsewhere int64
}

func newAsksFixture(t *testing.T) asksFixture {
	t.Helper()
	var f asksFixture
	f.database = writeActionsConfig(t)
	var err error
	f.acme, err = f.database.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err)
	f.other, err = f.database.CreateWorkbench("other", t.TempDir())
	require.NoError(t, err)
	res, err := f.database.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id)
		VALUES (?, 'claude', 'Fix the parser', '/tmp/acme', ?)`, f.acme, briefLaunchID)
	require.NoError(t, err)
	f.session, err = res.LastInsertId()
	require.NoError(t, err)

	insert := func(project int64, session any, kind, title, status, payload string, extra map[string]string) int64 {
		t.Helper()
		answer, docPath := "", ""
		if status == "answered" || status == "delivered" {
			answer = `{"note":"ok"}`
		}
		if kind == "review" {
			docPath = "docs/spec.md"
		}
		res, err := f.database.Exec(`INSERT INTO owner_asks (project_id, session_id, kind, title, summary, payload,
			doc_path, status, answer, level, origin, chat_asked_at, created_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '2026-10-10T09:00:00Z')`,
			project, session, kind, title, "about "+title, payload, docPath, status, answer,
			orDefault(extra["level"], "full"), orDefault(extra["origin"], "agent"), extra["chat_asked_at"])
		require.NoError(t, err)
		id, err := res.LastInsertId()
		require.NoError(t, err)
		return id
	}
	f.quick = insert(f.acme, f.session, "question", "Key style?", "open",
		`{"focus":[],"questions":[{"id":"q1","question":"snake_case or camelCase?","options":[
			{"label":"snake_case","description":"as the API","recommended":true},{"label":"camelCase"}]}],"checklist":[]}`,
		map[string]string{"level": "quick"})
	f.check = insert(f.acme, nil, "check", "Try the build", "answered",
		`{"focus":[],"questions":[],"checklist":[{"id":"c1","text":"Open it"},{"id":"c2","text":"Close it"}]}`, nil)
	f.review = insert(f.acme, f.session, "review", "Read the spec", "delivered",
		`{"focus":[{"text":"Part 2"}],"questions":[],"checklist":[]}`, nil)
	f.chat = insert(f.acme, f.session, "question", "Which port?", "open",
		`{"focus":[],"questions":[{"id":"q1","question":"Which port?","options":[]}],"checklist":[]}`,
		map[string]string{"level": "quick", "origin": "chat", "chat_asked_at": "2026-10-10T08:58:00.000Z"})
	f.withdrawn = insert(f.acme, f.session, "question", "Old question", "withdrawn",
		`{"focus":[],"questions":[{"id":"q1","question":"Old?","options":[{"label":"a"},{"label":"b"}]}],"checklist":[]}`, nil)
	f.broken = insert(f.acme, f.session, "question", "Garbled", "open", `{not json`, nil)
	f.elsewhere = insert(f.other, nil, "check", "Other check", "open", `{"focus":[],"questions":[],"checklist":[]}`, nil)
	return f
}

func orDefault(s, def string) string {
	if s == "" {
		return def
	}
	return s
}

// runAsksJSON runs `workbench asks --json` with args and decodes its object.
func runAsksJSON(t *testing.T, args ...string) map[string]any {
	t.Helper()
	out, errOut, err := runWorkbench(t, append([]string{"asks", "--json"}, args...)...)
	require.NoError(t, err, "stderr: %s", errOut)
	var got map[string]any
	require.NoError(t, json.Unmarshal([]byte(out), &got), "stdout: %s", out)
	return got
}

// asksByID indexes the envelope's asks by id, after checking it is ok.
func asksByID(t *testing.T, got map[string]any) map[int64]map[string]any {
	t.Helper()
	require.Equal(t, true, got["ok"], "%v", got)
	list, ok := got["asks"].([]any)
	require.True(t, ok, "asks is a list: %v", got)
	out := map[int64]map[string]any{}
	for _, raw := range list {
		a := raw.(map[string]any)
		out[int64(a["id"].(float64))] = a
	}
	return out
}

func TestAsksJSONShape(t *testing.T) {
	f := newAsksFixture(t)
	acme, other, session := float64(f.acme), float64(f.other), float64(f.session)

	all := asksByID(t, runAsksJSON(t))
	require.Len(t, all, 7, "every status of every workbench")
	common := func(id int64, wb float64, wbName string, sess any, sessTitle, kind, level, origin, chatAt, status, title string) map[string]any {
		return map[string]any{"id": float64(id), "workbench_id": wb, "workbench_name": wbName,
			"session_id": sess, "session_title": sessTitle, "kind": kind, "level": level, "origin": origin,
			"chat_asked_at": chatAt, "status": status, "created_at": "2026-10-10T09:00:00Z",
			"title": title, "summary": "about " + title}
	}
	with := func(m map[string]any, key string, v any) map[string]any {
		m[key] = v
		return m
	}

	assert.Equal(t, with(common(f.quick, acme, "acme", session, "Fix the parser", "question", "quick", "agent", "", "open", "Key style?"),
		"questions", []any{map[string]any{"id": "q1", "question": "snake_case or camelCase?", "multi": false, "options": []any{
			map[string]any{"label": "snake_case", "description": "as the API", "recommended": true},
			map[string]any{"label": "camelCase", "description": "", "recommended": false},
		}}}), all[f.quick])
	assert.Equal(t, with(common(f.check, acme, "acme", nil, "", "check", "full", "agent", "", "answered", "Try the build"),
		"checklist_count", float64(2)), all[f.check], "no session: null id, empty title")
	assert.Equal(t, with(common(f.review, acme, "acme", session, "Fix the parser", "review", "full", "agent", "", "delivered", "Read the spec"),
		"doc_path", "docs/spec.md"), all[f.review])
	assert.Equal(t, with(common(f.chat, acme, "acme", session, "Fix the parser", "question", "quick", "chat", "2026-10-10T08:58:00.000Z", "open", "Which port?"),
		"questions", []any{map[string]any{"id": "q1", "question": "Which port?", "multi": false, "options": []any{}}}), all[f.chat])
	assert.Equal(t, "withdrawn", all[f.withdrawn]["status"])
	assert.Equal(t, with(common(f.elsewhere, other, "other", nil, "", "check", "full", "agent", "", "open", "Other check"),
		"checklist_count", float64(0)), all[f.elsewhere])

	// An unreadable payload is reported on its row; the row keeps its other
	// fields and the other rows are whole (checked above).
	broken := all[f.broken]
	assert.Contains(t, broken["payload_error"], "unreadable payload")
	assert.NotContains(t, broken, "questions")
	assert.Equal(t, "Garbled", broken["title"])
	assert.Equal(t, "open", broken["status"])

	t.Run("--open keeps only open asks", func(t *testing.T) {
		open := asksByID(t, runAsksJSON(t, "--open"))
		assert.ElementsMatch(t, []int64{f.quick, f.chat, f.broken, f.elsewhere}, keys(open))
	})
	t.Run("--workbench filters", func(t *testing.T) {
		mine := asksByID(t, runAsksJSON(t, "--workbench", strconv.FormatInt(f.acme, 10)))
		assert.ElementsMatch(t, []int64{f.quick, f.check, f.review, f.chat, f.withdrawn, f.broken}, keys(mine))
		theirs := asksByID(t, runAsksJSON(t, "--workbench", strconv.FormatInt(f.other, 10), "--open"))
		assert.ElementsMatch(t, []int64{f.elsewhere}, keys(theirs))
	})
}

// A workbench with no asks lists an empty array, never null.
func TestAsksJSONEmptyIsAnEmptyList(t *testing.T) {
	database := writeActionsConfig(t)
	id, err := database.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err)
	got := runAsksJSON(t, "--workbench", strconv.FormatInt(id, 10))
	assert.Equal(t, map[string]any{"ok": true, "asks": []any{}}, got)
}

// An unknown workbench, an id flag of 0 or below and both id flag spellings
// answer ok: false with exit 0.
func TestAsksJSONFailuresAreOKFalse(t *testing.T) {
	f := newAsksFixture(t)
	for name, args := range map[string][]string{
		"unknown workbench": {"--workbench", "999"},
		"zero id":           {"--workbench", "0"},
		"zero legacy id":    {"--project", "0"},
		"negative id":       {"--workbench", "-1"},
		"both flags":        {"--workbench", strconv.FormatInt(f.acme, 10), "--project", strconv.FormatInt(f.acme, 10)},
	} {
		t.Run(name, func(t *testing.T) {
			got := runAsksJSON(t, args...)
			assert.Equal(t, false, got["ok"])
			assert.NotEmpty(t, got["error"])
			assert.NotContains(t, got, "asks")
			if name != "unknown workbench" && name != "both flags" {
				assert.Contains(t, got["error"], "takes a positive id")
			}
		})
	}
}

func keys(m map[int64]map[string]any) []int64 {
	out := make([]int64, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}

// A read verb never creates the database: with none there it answers
// ok: false and leaves no file or directory behind.
func TestAsksJSONWithNoDatabaseCreatesNothing(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	configPath := filepath.Join(t.TempDir(), "config.yaml")
	require.NoError(t, os.WriteFile(configPath, []byte("active_workspace: test\n"), 0o600))
	orig := flagConfig
	flagConfig = configPath
	t.Cleanup(func() { flagConfig = orig })
	cfg, err := config.Load(flagConfig)
	require.NoError(t, err)

	got := runAsksJSON(t)

	assert.Equal(t, false, got["ok"])
	assert.Contains(t, got["error"], "opening database")
	_, statErr := os.Stat(cfg.WorkspaceDir())
	assert.True(t, os.IsNotExist(statErr), "the verb created %s", cfg.WorkspaceDir())
	_, statErr = os.Stat(cfg.DBPath())
	assert.True(t, os.IsNotExist(statErr), "the verb created the database")
}

// A database without the 00107 ask columns answers ok: false, never
// migrated: the columns are still missing afterwards.
func TestAsksJSONRefusesAnOlderSchema(t *testing.T) {
	database := writeActionsConfig(t)
	_, err := database.Exec(`DROP TABLE owner_asks`)
	require.NoError(t, err)
	_, err = database.Exec(`CREATE TABLE owner_asks (id INTEGER PRIMARY KEY, project_id INTEGER NOT NULL,
		kind TEXT NOT NULL, title TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'open')`)
	require.NoError(t, err)

	got := runAsksJSON(t)

	assert.Equal(t, false, got["ok"])
	assert.Contains(t, got["error"], "00107")
	has, err := database.HasColumns("owner_asks", "level")
	require.NoError(t, err)
	assert.False(t, has, "the verb migrated the database")
}
