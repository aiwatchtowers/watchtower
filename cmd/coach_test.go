package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/agentlogdb"
	"watchtower/internal/agentreport"
	"watchtower/internal/coach"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/fsutil"
	"watchtower/internal/ownerconfirm"
	"watchtower/internal/specreview"
	"watchtower/internal/workbenchgit"
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
	coachFlagAgent = agentreport.AgentAll
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
		"verdict", "verdict_value", "verdict_at", "reverts_id", "budget", "origin", "skill", "conversation_id",
		"written_branch", "measure_from"}, got)
	assert.JSONEq(t, `[{"kind":"session","ref":"s1"}]`, string(items[0]["evidence"]))
	assert.Equal(t, `""`, string(items[0]["written_branch"]))
	assert.Equal(t, "null", string(items[0]["measure_from"]))
	assert.Equal(t, "null", string(items[0]["decided_at"]))
	assert.Equal(t, `"weekly"`, string(items[0]["origin"]))
	assert.Equal(t, `""`, string(items[0]["skill"]))
	assert.Equal(t, "null", string(items[0]["conversation_id"]))

	out, err = runCoach(t, "", "proposals", "--status", "declined", "--json")
	require.NoError(t, err)
	assert.JSONEq(t, `{"ok":true,"proposals":[]}`, out)
}

// insertChatCoachProposal files an open chat proposal on a user skill, made in
// tuning conversation conv (created here with that id).
func insertChatCoachProposal(t *testing.T, d *db.DB, conv int64) int64 {
	t.Helper()
	_, err := d.Exec(`INSERT INTO chat_conversations (id, title, context_type, created_at, updated_at)
		VALUES (?, '', 'analytics_tuning', 0, 0)`, conv)
	require.NoError(t, err)
	id, err := d.InsertChatCoachProposal(db.CoachProposal{Fingerprint: "fp-chat", Kind: "add",
		Destination: coach.DestClaudeSkillUser, Skill: "review-pr", Title: "Check tests", Why: "Asked in the chat.", Metric: "corrections",
		AfterText: "Run the tests.", Evidence: []db.CoachEvidence{{Kind: "chat", Ref: "c7"}}, Sources: 1},
		&conv, time.Now())
	require.NoError(t, err)
	require.NotZero(t, id)
	return id
}

func coachFirstProposal(t *testing.T, out string) map[string]json.RawMessage {
	t.Helper()
	var items []map[string]json.RawMessage
	require.NoError(t, json.Unmarshal(coachJSONObject(t, out)["proposals"], &items))
	require.Len(t, items, 1)
	return items[0]
}

func TestCoachProposals_ChatKeys(t *testing.T) {
	d := coachSetup(t)
	insertChatCoachProposal(t, d, 7)

	out, err := runCoach(t, "", "proposals", "--json")
	require.NoError(t, err)
	p := coachFirstProposal(t, out)
	assert.Equal(t, `"chat"`, string(p["origin"]))
	assert.Equal(t, "7", string(p["conversation_id"]))
	assert.Equal(t, `"review-pr"`, string(p["skill"]))

	out, err = runCoach(t, "", "proposals")
	require.NoError(t, err)
	assert.Contains(t, out, "  where: "+coach.DestClaudeSkillUser+" [review-pr]\n")
	assert.Contains(t, out, "  from: chat 7\n")
}

func TestCoachProposals_DeletedConversation(t *testing.T) {
	d := coachSetup(t)
	insertChatCoachProposal(t, d, 7)
	_, err := d.Exec(`DELETE FROM chat_conversations WHERE id = 7`)
	require.NoError(t, err)

	out, err := runCoach(t, "", "proposals", "--json")
	require.NoError(t, err)
	p := coachFirstProposal(t, out)
	assert.Equal(t, `"chat"`, string(p["origin"]))
	assert.Equal(t, "null", string(p["conversation_id"]))

	out, err = runCoach(t, "", "proposals")
	require.NoError(t, err)
	assert.Contains(t, out, "  from: chat deleted\n")
}

func TestCoachProposals_WeeklyHasNoFromLine(t *testing.T) {
	d := coachSetup(t)
	insertCoachProposal(t, d, "fp1", "Be brief.")
	out, err := runCoach(t, "", "proposals")
	require.NoError(t, err)
	assert.NotContains(t, out, "from:")
}

func TestCodedCoachErr_Refused(t *testing.T) {
	assert.Equal(t, "refused", codedCoachErr(fmt.Errorf("wrap: %w", coach.ErrRefused)).code)
	assert.Equal(t, "failed", codedCoachErr(errors.New("boom")).code)
}

func TestCoachAccept_JSONKeysPinned(t *testing.T) {
	d := coachSetup(t)
	id := insertCoachProposal(t, d, "fp1", "Be brief.")

	out, err := runCoach(t, "", "accept", strconv.FormatInt(id, 10), "--json")
	require.NoError(t, err)
	top := coachJSONObject(t, out)
	var got []string
	for k := range top {
		got = append(got, k)
	}
	assert.ElementsMatch(t, []string{"ok", "id", "status", "pack_copies_updated", "pack_copies_drifted",
		"written_path", "written_branch"}, got)
	assert.Equal(t, "accepted", strings.Trim(string(top["status"]), `"`))
	assert.Equal(t, "0", string(top["pack_copies_updated"]))
	assert.JSONEq(t, `""`, string(top["written_path"]))
	assert.JSONEq(t, `""`, string(top["written_branch"]))
}

// insertRepoProposal is an open chat edit creating CLAUDE.md in workbench wb.
func insertRepoProposal(t *testing.T, d *db.DB, wb int64, fp string) int64 {
	t.Helper()
	id, err := d.InsertChatCoachProposal(db.CoachProposal{Fingerprint: fp, Kind: "add",
		Destination: coach.DestRepoClaudeMD, WorkbenchID: wb, Title: "Run tests", Why: "Asked twice.",
		Metric: "corrections", AfterText: "Run tests.\n", Sources: 1}, nil, time.Now())
	require.NoError(t, err)
	require.NotZero(t, id)
	return id
}

// A workbench repository file: dirty → "dirty", not a git work tree →
// "not_git", written → "written_path" relative to the folder.
func TestCoachAccept_RepoCodes(t *testing.T) {
	d := coachSetup(t)
	repo := gitBranchRepo(t)
	wb, err := d.CreateWorkbench("acme", repo)
	require.NoError(t, err)
	plain, err := filepath.EvalSymlinks(t.TempDir())
	require.NoError(t, err)
	wbPlain, err := d.CreateWorkbench("acme-plain", plain)
	require.NoError(t, err)

	// Untracked CLAUDE.md in the folder: dirty.
	require.NoError(t, os.WriteFile(filepath.Join(repo, "CLAUDE.md"), []byte("Mine.\n"), 0o644))
	id := insertRepoProposal(t, d, wb, "repo1")
	out, err := runCoach(t, "", "accept", strconv.FormatInt(id, 10), "--json")
	require.Error(t, err)
	top := coachJSONObject(t, out)
	assert.JSONEq(t, `"dirty"`, string(top["code"]))
	assert.NotContains(t, out, repo, "the folder is never named")

	id2 := insertRepoProposal(t, d, wbPlain, "repo2")
	out, err = runCoach(t, "", "accept", strconv.FormatInt(id2, 10), "--json")
	require.Error(t, err)
	assert.JSONEq(t, `"not_git"`, string(coachJSONObject(t, out)["code"]))

	require.NoError(t, os.Remove(filepath.Join(repo, "CLAUDE.md")))
	out, err = runCoach(t, "", "accept", strconv.FormatInt(id, 10), "--json")
	require.NoError(t, err, out)
	top = coachJSONObject(t, out)
	var got []string
	for k := range top {
		got = append(got, k)
	}
	assert.ElementsMatch(t, []string{"ok", "id", "status", "pack_copies_updated", "pack_copies_drifted",
		"written_path", "written_branch"}, got)
	assert.JSONEq(t, `"CLAUDE.md"`, string(top["written_path"]))
	assert.JSONEq(t, `"main"`, string(top["written_branch"]))
	p, err := d.GetCoachProposal(id)
	require.NoError(t, err)
	assert.Equal(t, "main", p.WrittenBranch)
	raw, err := os.ReadFile(filepath.Join(repo, "CLAUDE.md"))
	require.NoError(t, err)
	assert.Equal(t, "Run tests.\n", string(raw))
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

	// A failed suggestion fold does not stop the run: it is logged and the
	// proposals are still made.
	prevImport := coachImportSuggestions
	coachImportSuggestions = func(*db.DB, string, time.Time) (int, error) { return 0, errors.New("fold boom") }
	t.Cleanup(func() { coachImportSuggestions = prevImport })
	stdout, stderr, err := runCoachSplit(t, "run", "--json")
	require.NoError(t, err, stderr)
	assert.Contains(t, stderr, "fold boom")
	assert.JSONEq(t, `true`, string(coachJSONObject(t, stdout)["ok"]))
	all, err = d.ListCoachProposals()
	require.NoError(t, err)
	assert.Len(t, all, 1, "the run went on to propose")
	coachImportSuggestions = prevImport

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
	coachFlagAgent = agentreport.AgentAll
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

// seedCoachAgentSession stores one session of agent an hour ago on target
// tid of workbench wb, with interrupts interrupts.
func seedCoachAgentSession(t *testing.T, al *agentlogdb.DB, agent, uuid string, wb, tid int64, interrupts int) {
	t.Helper()
	const layout = "2006-01-02T15:04:05Z"
	start := time.Now().UTC().Add(-time.Hour)
	at := func(s int) string { return start.Add(time.Duration(s) * time.Second).Format(layout) }
	path := "/w/" + uuid + ".jsonl"
	var evs []agentlogdb.AgentLogEvent
	add := func(e agentlogdb.AgentLogEvent, s int) {
		e.SessionUUID, e.TS, e.SrcPath, e.SrcOffset = uuid, at(s), path, int64(len(evs))
		e.Key = fmt.Sprintf("%s:%d", uuid, len(evs))
		evs = append(evs, e)
	}
	add(agentlogdb.AgentLogEvent{Kind: "owner_turn", Trigger: "owner"}, 0)
	add(agentlogdb.AgentLogEvent{Kind: "tool", Name: "mcp__watchtower-workbench__update_target", Target: fmt.Sprintf("#%d", tid), Outcome: "ok"}, 10)
	for i := range interrupts {
		add(agentlogdb.AgentLogEvent{Kind: "owner_turn", Trigger: "interrupt"}, 20+i)
	}
	add(agentlogdb.AgentLogEvent{Kind: "api_call", Name: "model-x", InputTokens: 10, OutputTokens: 5}, 60)
	_, err := al.ApplyAgentLogBatch(agentlogdb.AgentLogBatch{
		File: agentlogdb.AgentLogFile{Path: path, Agent: agent, ReadOffset: 10, ParserVersion: 4}, ExpectOffset: -1,
		Sessions: []agentlogdb.AgentLogSession{{SessionUUID: uuid, Agent: agent, ProjectID: &wb, FolderPath: "/w", HomeCWD: "/w",
			SourcePath: path, StartedAt: at(0), EndedAt: at(60), Model: "model-x"}},
		Events: evs,
	})
	require.NoError(t, err)
}

func TestCoachStatus_AgentFlag(t *testing.T) {
	d := coachSetup(t)
	cfg, err := workspaceConfigFromFlags()
	require.NoError(t, err)
	alPath := agentlogdb.PathFor(cfg.DBPath())
	al, err := agentlogdb.Open(alPath)
	require.NoError(t, err)
	t.Cleanup(func() { _ = al.Close() })
	_, err = agentlogdb.MoveFromMain(context.Background(), d, al, agentlogdb.MoveLockPath(alPath))
	require.NoError(t, err)
	wb, err := d.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err)
	require.NoError(t, d.SetWorkbenchAgentAnalytics(wb, true))
	res, err := d.Exec(`INSERT INTO targets (text, period_start, period_end, project_id, status)
		VALUES ('goal', '2026-01-01', '2099-12-31', ?, 'in_progress')`, wb)
	require.NoError(t, err)
	tid, err := res.LastInsertId()
	require.NoError(t, err)
	seedCoachAgentSession(t, al, "claude", "sc", wb, tid, 2)
	seedCoachAgentSession(t, al, "codex", "sx", wb, tid, 0)

	corrections := func(args ...string) *float64 {
		out, err := runCoach(t, "", append([]string{"status", "--json"}, args...)...)
		require.NoError(t, err, out)
		var st coachStatusJSON
		require.NoError(t, json.Unmarshal([]byte(out), &st))
		return st.Metrics.Corrections.Value
	}
	all, claude, codex := corrections(), corrections("--agent", "claude"), corrections("--agent", "codex")
	require.NotNil(t, all)
	require.NotNil(t, claude)
	require.NotNil(t, codex)
	assert.InDelta(t, 2.0, *all, 1e-9)
	assert.InDelta(t, 2.0, *claude, 1e-9)
	assert.InDelta(t, 0.0, *codex, 1e-9, "Codex sessions only")
	assert.Equal(t, all, corrections("--agent", "all"))

	for _, bad := range []string{"gemini", ""} {
		_, err := runCoach(t, "", "status", "--agent", bad)
		require.Error(t, err, bad)
		assert.Contains(t, err.Error(), "--agent must be all, claude or codex")
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

// `coach run` folds the open instruction suggestions in before proposing;
// --dry-run folds nothing.
func TestCoachRun_ImportsSuggestions(t *testing.T) {
	d := coachSetup(t)
	require.NoError(t, d.UpsertInstructionSuggestion(db.InstructionSuggestion{Text: "Run the linter first",
		Field: db.InstructionSession, SessionCount: 3, Fingerprint: "fp"}, time.Now()))
	gen := &scriptedGen{out: `{"proposals":[]}`}
	prev := coachGeneratorFactory
	coachGeneratorFactory = func(*config.Config) digest.Generator { return gen }
	t.Cleanup(func() { coachGeneratorFactory = prev })

	_, err := runCoach(t, "", "run", "--dry-run", "--json")
	require.NoError(t, err)
	open, err := d.ListOpenInstructionSuggestions()
	require.NoError(t, err)
	assert.Len(t, open, 1, "a dry run folds nothing")

	out, err := runCoach(t, "", "run", "--json")
	require.NoError(t, err, out)
	var res struct {
		Proposals []struct {
			Title string `json:"title"`
		} `json:"proposals"`
	}
	require.NoError(t, json.Unmarshal([]byte(out), &res))
	require.Len(t, res.Proposals, 1)
	assert.Equal(t, "Run the linter first", res.Proposals[0].Title)
	open, err = d.ListOpenInstructionSuggestions()
	require.NoError(t, err)
	assert.Empty(t, open, "the row moved to the coach")
}

// A failed agentlog.db open or a busy coach.lock at daemon start leaves the
// one-time re-measure for later instead of marking it done.
func TestRemeasureCoachBaselines_SkipsWithoutAgentLogOrLock(t *testing.T) {
	d := coachSetup(t)
	cfg, err := workspaceConfigFromFlags()
	require.NoError(t, err)
	var logs bytes.Buffer
	remeasureCoachBaselines(cfg, d, nil, log.New(&logs, "", 0))
	done, err := d.CoachBaselinesPerAgentDone()
	require.NoError(t, err)
	assert.False(t, done)
	assert.Empty(t, logs.String())

	// A coach pass holding coach.lock: skipped, the key stays unwritten.
	alPath := agentlogdb.PathFor(cfg.DBPath())
	al, err := agentlogdb.Open(alPath)
	require.NoError(t, err)
	t.Cleanup(func() { _ = al.Close() })
	_, err = agentlogdb.MoveFromMain(context.Background(), d, al, agentlogdb.MoveLockPath(alPath))
	require.NoError(t, err)
	unlock, ok, err := fsutil.TryLockFile(coach.LockPath(cfg.WorkspaceDir()))
	require.NoError(t, err)
	require.True(t, ok)
	remeasureCoachBaselines(cfg, d, al, log.New(&logs, "", 0))
	done, err = d.CoachBaselinesPerAgentDone()
	require.NoError(t, err)
	assert.False(t, done, "busy lock: left for the next Judge")
	unlock()
	remeasureCoachBaselines(cfg, d, al, log.New(&logs, "", 0))
	done, err = d.CoachBaselinesPerAgentDone()
	require.NoError(t, err)
	assert.True(t, done)
}

// coachProposalItems runs `coach proposals --json` with args and returns the rows.
func coachProposalItems(t *testing.T, args ...string) []map[string]json.RawMessage {
	t.Helper()
	out, err := runCoach(t, "", append([]string{"proposals", "--json"}, args...)...)
	require.NoError(t, err, out)
	var items []map[string]json.RawMessage
	require.NoError(t, json.Unmarshal(coachJSONObject(t, out)["proposals"], &items))
	return items
}

func coachItemByID(t *testing.T, items []map[string]json.RawMessage, id int64) map[string]json.RawMessage {
	t.Helper()
	for _, it := range items {
		if string(it["id"]) == strconv.FormatInt(id, 10) {
			return it
		}
	}
	t.Fatalf("proposal %d not listed", id)
	return nil
}

// Spec §4.3a (D68): an open repository proposal names the branch checked out
// in its workbench folder now, read once per workbench per call.
func TestCoachProposals_FolderBranch(t *testing.T) {
	d := coachSetup(t)
	repo := gitBranchRepo(t)
	wb, err := d.CreateWorkbench("acme", repo)
	require.NoError(t, err)
	plain, err := filepath.EvalSymlinks(t.TempDir())
	require.NoError(t, err)
	wbPlain, err := d.CreateWorkbench("acme-plain", plain)
	require.NoError(t, err)
	reads := 0
	prev := coachFolderStatus
	coachFolderStatus = func(ctx context.Context, folder string) workbenchgit.Status {
		reads++
		return prev(ctx, folder)
	}
	t.Cleanup(func() { coachFolderStatus = prev })
	gitIn := func(args ...string) {
		c := exec.Command("git", args...)
		c.Dir = repo
		out, err := c.CombinedOutput()
		require.NoError(t, err, "git %v: %s", args, out)
	}

	gitIn("switch", "-q", "-c", "topic/x")
	accepted := insertRepoProposal(t, d, wb, "repo4")
	require.NoError(t, d.MarkCoachAccepted(accepted, "Run tests.\n", "main", nil, 0, time.Now()))
	open1 := insertRepoProposal(t, d, wb, "repo1")
	open2, err := d.InsertChatCoachProposal(db.CoachProposal{Fingerprint: "repo2", Kind: "add",
		Destination: coach.DestRepoAgentsMD, WorkbenchID: wb, Title: "Lint", Why: "Asked.",
		Metric: "corrections", AfterText: "Run lint.\n", Sources: 1}, nil, time.Now())
	require.NoError(t, err)
	inPlain := insertRepoProposal(t, d, wbPlain, "repo3")
	global := insertCoachProposal(t, d, "fp-global", "Be brief.")

	items := coachProposalItems(t, "--status", "all")
	assert.Equal(t, 2, reads, "one read per workbench, not per proposal")
	assert.JSONEq(t, `"topic/x"`, string(coachItemByID(t, items, open1)["folder_branch"]))
	assert.JSONEq(t, `"topic/x"`, string(coachItemByID(t, items, open2)["folder_branch"]))
	assert.JSONEq(t, `""`, string(coachItemByID(t, items, inPlain)["folder_branch"]), "the key is there, empty")
	assert.NotContains(t, coachItemByID(t, items, global), "folder_branch")
	acc := coachItemByID(t, items, accepted)
	assert.NotContains(t, acc, "folder_branch")
	assert.JSONEq(t, `"main"`, string(acc["written_branch"]))

	gitIn("switch", "-q", "--detach")
	c := exec.Command("git", "rev-parse", "--short=7", "HEAD")
	c.Dir = repo
	sha, err := c.Output()
	require.NoError(t, err)
	items = coachProposalItems(t)
	assert.JSONEq(t, `"detached:`+strings.TrimSpace(string(sha))+`"`, string(coachItemByID(t, items, open1)["folder_branch"]))

	out, err := runCoach(t, "", "proposals")
	require.NoError(t, err)
	assert.Contains(t, out, "  where: "+coach.DestRepoClaudeMD+fmt.Sprintf(" (workbench %d) on detached:", wb))
	assert.Contains(t, out, "  where: "+coach.DestRepoClaudeMD+fmt.Sprintf(" (workbench %d)\n", wbPlain), "no branch, no suffix")
}
