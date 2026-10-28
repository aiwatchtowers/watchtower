package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/agentlogdb"
	"watchtower/internal/coach"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/fsutil"
	"watchtower/internal/ownerconfirm"
	"watchtower/internal/specreview"
)

// runCoach runs `watchtower coach <args>` with stdin and returns its output.
func runCoach(t *testing.T, stdin string, args ...string) (string, error) {
	t.Helper()
	var out bytes.Buffer
	var errb bytes.Buffer
	rootCmd.SetOut(&out)
	rootCmd.SetErr(&errb) // the --json failure echo lives here, not in the stdout under test
	rootCmd.SetIn(strings.NewReader(stdin))
	rootCmd.SetArgs(append([]string{"coach"}, args...))
	err := rootCmd.Execute()
	rootCmd.SetArgs(nil)
	rootCmd.SetIn(nil)
	coachFlagJSON, coachFlagWorkbench, coachFlagStatus = false, 0, "open"
	coachFlagStdin, coachFlagForce, coachFlagDryRun, coachFlagDays = false, false, false, coachDefaultDays
	return out.String(), err
}

// coachSetup points the CLI at a temp workspace and a temp home.
func coachSetup(t *testing.T) *db.DB {
	t.Helper()
	database := writeActionsConfig(t)
	home := t.TempDir()
	prev := coachHome
	coachHome = func() (string, error) { return home, nil }
	t.Cleanup(func() { coachHome = prev })
	return database
}

func insertCoachProposal(t *testing.T, d *db.DB, fp, after string) int64 {
	t.Helper()
	id, err := d.InsertCoachProposal(db.CoachProposal{Fingerprint: fp, Kind: "add", Destination: "session",
		Title: "Be brief", Why: "Three sessions asked for it.", Metric: "corrections", AfterText: after,
		Evidence: []db.CoachEvidence{{Kind: "session", Ref: "s1"}}, Sources: 3}, time.Now())
	require.NoError(t, err)
	require.NotZero(t, id)
	return id
}

func coachJSONObject(t *testing.T, raw string) map[string]json.RawMessage {
	t.Helper()
	var m map[string]json.RawMessage
	require.NoError(t, json.Unmarshal([]byte(raw), &m), raw)
	return m
}

func TestCoachAccept_RefusedUnderAgent(t *testing.T) {
	d := coachSetup(t)
	id := insertCoachProposal(t, d, "fp1", "Be brief.")
	t.Setenv(agentEnvMarkers[0], "1")

	for _, verb := range [][]string{{"accept", strconv.FormatInt(id, 10)}, {"decline", strconv.FormatInt(id, 10)},
		{"rollback", strconv.FormatInt(id, 10)}, {"run", "--dry-run"}} {
		_, err := runCoach(t, "", verb...)
		require.Error(t, err, verb[0])
		assert.Contains(t, err.Error(), agentEnvMarkers[0])
		assert.Contains(t, err.Error(), "the owner decides in Watchtower Desktop")
	}
	p, err := d.GetCoachProposal(id)
	require.NoError(t, err)
	assert.Equal(t, "open", p.Status)
}

// AGENT-07 (ask #659): without a marker an owner verb runs only after the
// owner confirms it in the running Desktop; the window shows the proposal and
// its change. No Desktop or a denial writes nothing.
func TestCoachOwnerVerbs_NeedTheDesktopsConfirmation(t *testing.T) {
	verbs := [][]string{{"accept"}, {"decline"}, {"rollback"}, {"run"}}
	for _, v := range verbs {
		t.Run(v[0]+" without a Desktop", func(t *testing.T) {
			d := coachSetup(t)
			id := insertCoachProposal(t, d, "fp1", "Be brief.")
			withOwnerDesktop(t, ownerconfirm.Reply{}, fmt.Errorf("%w: test", ownerconfirm.ErrNoDesktop))
			args := v
			if v[0] != "run" {
				args = []string{v[0], strconv.FormatInt(id, 10)}
			}
			_, err := runCoach(t, "", args...)
			require.Error(t, err)
			assert.Contains(t, err.Error(), "open Watchtower to confirm this")
			p, err := d.GetCoachProposal(id)
			require.NoError(t, err)
			assert.Equal(t, "open", p.Status)
			o, err := d.GetOwnerInstructions()
			require.NoError(t, err)
			assert.Empty(t, o.Session)
		})
	}

	t.Run("a dry run needs no Desktop", func(t *testing.T) {
		coachSetup(t)
		reqs := withOwnerDesktop(t, ownerconfirm.Reply{}, fmt.Errorf("%w: test", ownerconfirm.ErrNoDesktop))
		prev := coachGeneratorFactory
		coachGeneratorFactory = func(*config.Config) digest.Generator { return &scriptedGen{out: `{"proposals":[]}`} }
		t.Cleanup(func() { coachGeneratorFactory = prev })
		_, err := runCoach(t, "", "run", "--dry-run")
		require.NoError(t, err)
		assert.Empty(t, *reqs)
	})

	t.Run("the owner denies", func(t *testing.T) {
		d := coachSetup(t)
		id := insertCoachProposal(t, d, "fp1", "Be brief.")
		withOwnerDesktop(t, ownerconfirm.Reply{Decision: ownerconfirm.Denied}, nil)
		out, err := runCoach(t, "", "accept", strconv.FormatInt(id, 10), "--json")
		require.Error(t, err)
		assert.JSONEq(t, "false", string(coachJSONObject(t, out)["ok"]))
		p, err := d.GetCoachProposal(id)
		require.NoError(t, err)
		assert.Equal(t, "open", p.Status)
	})

	t.Run("the owner confirms what the window shows", func(t *testing.T) {
		d := coachSetup(t)
		id := insertCoachProposal(t, d, "fp1", "Be brief.")
		reqs := withOwnerDesktop(t, ownerconfirm.Reply{Decision: ownerconfirm.Confirmed}, nil)
		_, err := runCoach(t, "Be very brief.", "accept", strconv.FormatInt(id, 10), "--stdin")
		require.NoError(t, err)
		require.Len(t, *reqs, 1)
		detail := (*reqs)[0].Detail
		assert.Contains(t, detail, "Be brief")
		assert.Contains(t, detail, "+ Be brief.")
		assert.Contains(t, detail, "With your text:\nBe very brief.")
		o, err := d.GetOwnerInstructions()
		require.NoError(t, err)
		assert.Equal(t, "Be very brief.", o.Session)
	})

	t.Run("a marker is refused before the Desktop is asked", func(t *testing.T) {
		d := coachSetup(t)
		id := insertCoachProposal(t, d, "fp1", "Be brief.")
		reqs := withOwnerDesktop(t, ownerconfirm.Reply{Decision: ownerconfirm.Confirmed}, nil)
		t.Setenv(agentEnvMarkers[0], "1")
		_, err := runCoach(t, "", "decline", strconv.FormatInt(id, 10))
		require.Error(t, err)
		assert.Empty(t, *reqs)
	})
}

func TestCoachAccept_RefusedUnderAgentJSON(t *testing.T) {
	d := coachSetup(t)
	id := insertCoachProposal(t, d, "fp1", "Be brief.")
	t.Setenv(agentEnvMarkers[0], "1")

	out, err := runCoach(t, "", "accept", strconv.FormatInt(id, 10), "--json")
	require.Error(t, err)
	top := coachJSONObject(t, out)
	assert.JSONEq(t, "false", string(top["ok"]))
	assert.Contains(t, string(top["error"]), "the owner decides in Watchtower Desktop")
}

func TestCoachAccept_EmptyStdinRefused(t *testing.T) {
	d := coachSetup(t)
	id := insertCoachProposal(t, d, "fp1", "Be brief.")

	for _, in := range []string{"", " \n"} {
		_, err := runCoach(t, in, "accept", strconv.FormatInt(id, 10), "--stdin")
		require.Error(t, err)
		assert.Contains(t, err.Error(), "--stdin read no text")
	}
	p, err := d.GetCoachProposal(id)
	require.NoError(t, err)
	assert.Equal(t, "open", p.Status, "the proposed text was not applied")
	o, err := d.GetOwnerInstructions()
	require.NoError(t, err)
	assert.Empty(t, o.Session)
}

func TestCoachProposals_JSONKeysPinned(t *testing.T) {
	d := coachSetup(t)
	insertCoachProposal(t, d, "fp1", "Be brief.")

	out, err := runCoach(t, "", "proposals", "--json")
	require.NoError(t, err)
	top := coachJSONObject(t, out)
	assert.Contains(t, top, "ok")
	var items []map[string]json.RawMessage
	require.NoError(t, json.Unmarshal(top["proposals"], &items))
	require.Len(t, items, 1)
	var got []string
	for k := range items[0] {
		got = append(got, k)
	}
	assert.ElementsMatch(t, []string{"id", "title", "why", "destination", "workbench_id", "prompt_id", "kind",
		"metric", "before", "after", "evidence", "sources", "status", "created_at", "decided_at", "baseline",
		"verdict", "verdict_value", "verdict_at", "reverts_id", "budget"}, got)
	assert.JSONEq(t, `[{"kind":"session","ref":"s1"}]`, string(items[0]["evidence"]))
	assert.Equal(t, "null", string(items[0]["decided_at"]))

	out, err = runCoach(t, "", "proposals", "--status", "declined", "--json")
	require.NoError(t, err)
	assert.JSONEq(t, `{"ok":true,"proposals":[]}`, out)
}

func TestCoachStatus_JSONKeysPinned(t *testing.T) {
	coachSetup(t)
	out, err := runCoach(t, "", "status", "--json")
	require.NoError(t, err)
	top := coachJSONObject(t, out)
	var keys []string
	for k := range top {
		keys = append(keys, k)
	}
	assert.ElementsMatch(t, []string{"ok", "period", "metrics", "open", "last_run"}, keys)
	assert.ElementsMatch(t, []string{"since", "until"}, coachObjectKeys(t, top["period"]))
	metrics := coachJSONObject(t, string(top["metrics"]))
	var names []string
	for k, v := range metrics {
		names = append(names, k)
		assert.ElementsMatch(t, []string{"value", "n", "known", "previous"}, coachObjectKeys(t, v), k)
		assert.Equal(t, "null", string(coachJSONObject(t, string(v))["value"]), "no data: value is null, not 0")
	}
	assert.ElementsMatch(t, []string{"corrections", "task_hours", "task_cost_usd", "owner_loop", "spec_findings", "review_comments"}, names)
	assert.JSONEq(t, `""`, string(top["last_run"]))
}

func coachObjectKeys(t *testing.T, raw json.RawMessage) []string {
	t.Helper()
	var out []string
	for k := range coachJSONObject(t, string(raw)) {
		out = append(out, k)
	}
	return out
}

func TestCoachRollback_ChangedSincePrintsDiff(t *testing.T) {
	d := coachSetup(t)
	id := insertCoachProposal(t, d, "fp1", "Be brief.")
	idArg := strconv.FormatInt(id, 10)

	_, err := runCoach(t, "", "accept", idArg)
	require.NoError(t, err)
	o, err := d.GetOwnerInstructions()
	require.NoError(t, err)
	assert.Equal(t, "Be brief.", o.Session)

	require.NoError(t, d.SetOwnerInstruction(db.InstructionSession, "Be brief.\nAnd polite."))
	out, err := runCoach(t, "", "rollback", idArg)
	require.Error(t, err)
	assert.Contains(t, out, "+And polite.", "the diff is printed")
	assert.Contains(t, err.Error(), "--force")
	p, err := d.GetCoachProposal(id)
	require.NoError(t, err)
	assert.Equal(t, "accepted", p.Status, "nothing was rolled back")

	out, err = runCoach(t, "", "rollback", idArg, "--force", "--json")
	require.NoError(t, err)
	assert.JSONEq(t, fmt.Sprintf(`{"ok":true,"id":%d,"status":"rolled_back"}`, id), out)
}

func TestCoachProposals_HumanOutputShowsTheEdit(t *testing.T) {
	d := coachSetup(t)
	_, err := d.InsertCoachProposal(db.CoachProposal{Fingerprint: "fp-r", Kind: "replace", Destination: "session",
		Title: "Name the tests", Why: "Three sessions asked for it.", Metric: "corrections",
		BeforeText: "Keep it short.\nUse tests.", AfterText: "Keep it short.\nUse table tests.",
		Evidence: []db.CoachEvidence{{Kind: "session", Ref: "s1"}}, Sources: 3}, time.Now())
	require.NoError(t, err)

	out, err := runCoach(t, "", "proposals")
	require.NoError(t, err)
	assert.Contains(t, out, "  change:\n    - Use tests.\n    + Use table tests.\n")
	assert.NotContains(t, out, "Keep it short.", "unchanged lines are left out")
}

func TestCoachAccept_StdinEditedText(t *testing.T) {
	d := coachSetup(t)
	id := insertCoachProposal(t, d, "fp1", "Be brief.")
	_, err := runCoach(t, "Be very brief.", "accept", strconv.FormatInt(id, 10), "--stdin")
	require.NoError(t, err)
	o, err := d.GetOwnerInstructions()
	require.NoError(t, err)
	assert.Equal(t, "Be very brief.", o.Session)
}

type scriptedGen struct {
	calls int
	out   string
}

func (g *scriptedGen) Generate(context.Context, string, string, string) (string, *digest.Usage, string, error) {
	g.calls++
	return g.out, &digest.Usage{}, "", nil
}

func TestCoachRun_DryRunWritesNothing(t *testing.T) {
	d := coachSetup(t)
	wb, err := d.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err)
	now := time.Now().UTC().Add(-24 * time.Hour).Format("2006-01-02T15:04:05Z")
	var refs []string
	for i := range 3 {
		key := fmt.Sprintf("bs:%012d", i)
		raw, err := json.Marshal(specreview.Result{BlindSpots: []specreview.BlindSpot{{Key: key, Text: "No rollback path", Why: "stuck"}}})
		require.NoError(t, err)
		r, err := d.Exec(`INSERT INTO owner_asks (project_id, kind, title, doc_path, doc_type) VALUES (?, 'review', 't', 'spec.md', 'spec')`, wb)
		require.NoError(t, err)
		ask, _ := r.LastInsertId()
		_, err = d.Exec(`INSERT INTO spec_reviews (ask_id, status, result, queued_at, finished_at, findings) VALUES (?, 'done', ?, ?, ?, 1)`,
			ask, string(raw), now, now)
		require.NoError(t, err)
		_, err = d.Exec(`INSERT INTO spec_review_marks (ask_id, item_key, state, body, updated_at) VALUES (?, ?, 'comment', 'add one', ?)`, ask, key, now)
		require.NoError(t, err)
		refs = append(refs, fmt.Sprintf("%q", fmt.Sprintf("ask:%d#%s", ask, key)))
	}
	gen := &scriptedGen{out: `{"proposals":[{"title":"Rollback paths","why":"Three specs lacked one.","destination":"chat","workbench_id":0,"prompt_id":"",` +
		`"kind":"add","find":"","replace":"Always state a rollback path.","metric":"review_findings","evidence":[` + strings.Join(refs, ",") + `]}]}`}
	prev := coachGeneratorFactory
	coachGeneratorFactory = func(*config.Config) digest.Generator { return gen }
	t.Cleanup(func() { coachGeneratorFactory = prev })

	out, err := runCoach(t, "", "run", "--dry-run", "--json")
	require.NoError(t, err, out)
	assert.Equal(t, 1, gen.calls)
	var res struct {
		DryRun    bool `json:"dry_run"`
		Proposals []struct {
			Title string `json:"title"`
		} `json:"proposals"`
	}
	require.NoError(t, json.Unmarshal([]byte(out), &res))
	assert.True(t, res.DryRun)
	require.Len(t, res.Proposals, 1)
	assert.Equal(t, "Rollback paths", res.Proposals[0].Title)

	out, err = runCoach(t, "", "run", "--dry-run")
	require.NoError(t, err, out)
	assert.Contains(t, out, "Rollback paths")
	assert.Contains(t, out, "  change:\n    + Always state a rollback path.\n", "the human output shows the edit")

	all, err := d.ListCoachProposals()
	require.NoError(t, err)
	assert.Empty(t, all, "a dry run stores nothing")
	_, statErr := os.Stat(coachStampPathForTest(t))
	assert.True(t, os.IsNotExist(statErr), "and does not touch the weekly stamp")

	// A failed judge step does not stop the proposals (as in the daemon); the
	// output says why judging failed.
	prevJudge := coachJudge
	coachJudge = func(*db.DB, *agentlogdb.DB, time.Time) (int, int, error) { return 0, 0, errors.New("judge boom") }
	t.Cleanup(func() { coachJudge = prevJudge })
	out, err = runCoach(t, "", "run", "--json")
	require.NoError(t, err, out)
	top := coachJSONObject(t, out)
	assert.JSONEq(t, `"judge boom"`, string(top["judge_error"]))
	all, err = d.ListCoachProposals()
	require.NoError(t, err)
	assert.Len(t, all, 1, "a real run writes it")
}

func coachStampPathForTest(t *testing.T) string {
	t.Helper()
	cfg, err := workspaceConfigFromFlags()
	require.NoError(t, err)
	return cfg.WorkspaceDir() + "/last_coach.txt"
}

// runCoachSplit is runCoach with stdout and stderr kept apart.
func runCoachSplit(t *testing.T, args ...string) (stdout, stderr string, err error) {
	t.Helper()
	var out, errb bytes.Buffer
	rootCmd.SetOut(&out)
	rootCmd.SetErr(&errb)
	rootCmd.SetIn(strings.NewReader(""))
	rootCmd.SetArgs(append([]string{"coach"}, args...))
	err = rootCmd.Execute()
	rootCmd.SetArgs(nil)
	rootCmd.SetIn(nil)
	coachFlagJSON, coachFlagWorkbench, coachFlagStatus = false, 0, "open"
	coachFlagStdin, coachFlagForce, coachFlagDryRun, coachFlagDays = false, false, false, coachDefaultDays
	return out.String(), errb.String(), err
}

// jsonObjectLine is the last stderr line that decodes as a JSON object.
func jsonObjectLine(t *testing.T, s string) string {
	t.Helper()
	lines := strings.Split(strings.TrimSpace(s), "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		var m map[string]any
		if json.Unmarshal([]byte(lines[i]), &m) == nil {
			return lines[i]
		}
	}
	t.Fatalf("no JSON object line in stderr: %q", s)
	return ""
}

func TestCoachStatus_DaysWindow(t *testing.T) {
	coachSetup(t)
	span := func(args ...string) time.Duration {
		out, err := runCoach(t, "", append([]string{"status", "--json"}, args...)...)
		require.NoError(t, err, out)
		var st coachStatusJSON
		require.NoError(t, json.Unmarshal([]byte(out), &st))
		since, err := time.Parse(time.RFC3339, st.Period.Since)
		require.NoError(t, err)
		until, err := time.Parse(time.RFC3339, st.Period.Until)
		require.NoError(t, err)
		return until.Sub(since)
	}
	assert.Equal(t, 7*24*time.Hour, span("--days", "7"))
	assert.Equal(t, 24*time.Hour, span("--days", "1"))
	assert.Equal(t, 14*24*time.Hour, span())
	for _, bad := range []string{"0", "91"} {
		_, err := runCoach(t, "", "status", "--days", bad)
		require.Error(t, err, bad)
		assert.Contains(t, err.Error(), "--days must be between 1 and 90")
	}
}

func TestCoachRun_BusyWhenLocked(t *testing.T) {
	coachSetup(t)
	cfg, err := workspaceConfigFromFlags()
	require.NoError(t, err)
	unlock, ok, err := fsutil.TryLockFile(coach.LockPath(cfg.WorkspaceDir()))
	require.NoError(t, err)
	require.True(t, ok)
	defer unlock()

	stdout, stderr, err := runCoachSplit(t, "run", "--json")
	require.Error(t, err)
	assert.JSONEq(t, `{"ok":false,"code":"busy","error":"the coach is already running"}`, stdout)
	assert.JSONEq(t, stdout, jsonObjectLine(t, stderr))
}

func TestCoachJSONFailure_EchoedOnStderr(t *testing.T) {
	coachSetup(t)
	stdout, stderr, err := runCoachSplit(t, "accept", "999", "--json")
	require.Error(t, err)
	var a, b map[string]any
	require.NoError(t, json.Unmarshal([]byte(stdout), &a), stdout)
	require.NoError(t, json.Unmarshal([]byte(jsonObjectLine(t, stderr)), &b), stderr)
	assert.Equal(t, false, a["ok"])
	assert.Equal(t, a, b)
}

func TestCoachProposals_BudgetPerDestination(t *testing.T) {
	d := coachSetup(t)
	claude := strings.Repeat("x", 3800)
	short := strings.Repeat("y", 100)
	cases := []struct {
		dest, before string
		want         int
	}{
		{"session", "", 1000}, {"procedure", "", 1000}, {"chat", "", 1000},
		{"prompt_addition", "", 600}, {"claude_settings_allow", "", 0},
		{"claude_md_user", short, 500}, {"claude_md_user", claude, 4000},
	}
	for i, c := range cases {
		_, err := d.InsertCoachProposal(db.CoachProposal{Fingerprint: fmt.Sprintf("fp%d", i), Kind: "add",
			Destination: c.dest, Title: c.dest, Metric: "corrections", BeforeText: c.before, AfterText: "z",
			Evidence: []db.CoachEvidence{{Kind: "session", Ref: "s1"}}, Sources: 3}, time.Now())
		require.NoError(t, err)
	}
	out, err := runCoach(t, "", "proposals", "--status", "all", "--json")
	require.NoError(t, err)
	var res struct {
		Proposals []struct {
			Destination string `json:"destination"`
			Before      string `json:"before"`
			Budget      int    `json:"budget"`
		} `json:"proposals"`
	}
	require.NoError(t, json.Unmarshal([]byte(out), &res))
	require.Len(t, res.Proposals, len(cases))
	for i, c := range cases {
		var got int = -1
		for _, p := range res.Proposals {
			if p.Destination == c.dest && p.Before == c.before {
				got = p.Budget
			}
		}
		assert.Equal(t, c.want, got, "case %d %s", i, c.dest)
	}
}

// Through the real Execute(): the JSON line is on stderr, followed by its prose line.
func TestCoachJSONFailure_ThroughExecute(t *testing.T) {
	coachSetup(t)
	r, w, err := os.Pipe()
	require.NoError(t, err)
	origErr, origArgs := os.Stderr, os.Args
	os.Stderr, os.Args = w, []string{"watchtower", "coach", "accept", "999", "--json"}
	t.Cleanup(func() {
		os.Stderr, os.Args = origErr, origArgs
		rootCmd.SetArgs(nil)
		coachFlagJSON, coachFlagDays = false, coachDefaultDays
	})
	var out bytes.Buffer
	rootCmd.SetOut(&out)
	rootCmd.SetErr(w)
	rootCmd.SetArgs(os.Args[1:])
	code := Execute()
	require.NoError(t, w.Close())
	raw, err := io.ReadAll(r)
	require.NoError(t, err)
	assert.Equal(t, 1, code)
	lines := strings.Split(strings.TrimSpace(string(raw)), "\n")
	require.GreaterOrEqual(t, len(lines), 2, string(raw))
	var obj map[string]any
	require.NoError(t, json.Unmarshal([]byte(jsonObjectLine(t, string(raw))), &obj))
	assert.Equal(t, false, obj["ok"])
	var last map[string]any
	assert.Error(t, json.Unmarshal([]byte(lines[len(lines)-1]), &last), "Execute's prose line follows the JSON line")
}
