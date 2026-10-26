package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/specreview"
)

// runCoach runs `watchtower coach <args>` with stdin and returns its output.
func runCoach(t *testing.T, stdin string, args ...string) (string, error) {
	t.Helper()
	var out bytes.Buffer
	rootCmd.SetOut(&out)
	rootCmd.SetErr(&out)
	rootCmd.SetIn(strings.NewReader(stdin))
	rootCmd.SetArgs(append([]string{"coach"}, args...))
	err := rootCmd.Execute()
	rootCmd.SetArgs(nil)
	rootCmd.SetIn(nil)
	coachFlagJSON, coachFlagWorkbench, coachFlagStatus = false, 0, "open"
	coachFlagStdin, coachFlagForce, coachFlagDryRun = false, false, false
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
		"verdict", "verdict_value", "verdict_at", "reverts_id"}, got)
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

	all, err := d.ListCoachProposals()
	require.NoError(t, err)
	assert.Empty(t, all, "a dry run stores nothing")
	_, statErr := os.Stat(coachStampPathForTest(t))
	assert.True(t, os.IsNotExist(statErr), "and does not touch the weekly stamp")

	out, err = runCoach(t, "", "run", "--json")
	require.NoError(t, err, out)
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
