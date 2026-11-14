package cmd

import (
	"encoding/json"
	"errors"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/coach"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
)

// `coach run` runs the context proposer for every workbench with analytics
// on: --dry-run lists its proposals (a global one once) and writes nothing; a
// real run files them and counts them in written; one workbench's failure is
// printed and the others go on.
func TestCoachRun_ContextProposer(t *testing.T) {
	d := coachSetup(t)
	var wbs []int64
	for _, name := range []string{"acme", "beta"} {
		wb, err := d.CreateWorkbench(name, t.TempDir())
		require.NoError(t, err)
		require.NoError(t, d.SetWorkbenchAgentAnalytics(wb, true))
		wbs = append(wbs, wb)
	}
	_, err := d.CreateWorkbench("off", t.TempDir())
	require.NoError(t, err)
	gen := &scriptedGen{out: `{"proposals":[]}`}
	prevGen, prevPreview, prevPropose := coachGeneratorFactory, coachContextPreview, coachContextPropose
	t.Cleanup(func() {
		coachGeneratorFactory, coachContextPreview, coachContextPropose = prevGen, prevPreview, prevPropose
	})
	coachGeneratorFactory = func(*config.Config) digest.Generator { return gen }
	global := db.CoachProposal{Fingerprint: "context|claude_plugin_off|0|alpha@example-market|true|false", Kind: "cut",
		Destination: coach.DestPluginOff, SourceKey: "alpha@example-market", Title: "Turn off the alpha plugin",
		Why: "unused", Metric: "start_tokens", BeforeText: "true", AfterText: "false", Sources: 6}
	var previewed []int64
	coachContextPreview = func(env coach.ContextEnv, wb int64) ([]db.CoachProposal, error) {
		assert.NotEmpty(t, env.Home)
		previewed = append(previewed, wb)
		return []db.CoachProposal{global}, nil
	}

	out, err := runCoach(t, "", "run", "--dry-run", "--json")
	require.NoError(t, err, out)
	assert.ElementsMatch(t, wbs, previewed, "every analytics workbench, none other")
	var res struct {
		Proposals []struct {
			Title string `json:"title"`
		} `json:"proposals"`
	}
	require.NoError(t, json.Unmarshal([]byte(out), &res))
	require.Len(t, res.Proposals, 1, "a global proposal is listed once")
	assert.Equal(t, "Turn off the alpha plugin", res.Proposals[0].Title)
	all, err := d.ListCoachProposals()
	require.NoError(t, err)
	assert.Empty(t, all, "a dry run stores nothing")

	var proposed []int64
	coachContextPropose = func(env coach.ContextEnv, wb int64) (int, error) {
		proposed = append(proposed, wb)
		if wb == wbs[0] {
			return 0, errors.New("context boom")
		}
		_, err := env.DB.InsertContextCoachProposal(global, time.Now())
		return 1, err
	}
	stdout, stderr, err := runCoachSplit(t, "run", "--json")
	require.NoError(t, err, stderr)
	assert.ElementsMatch(t, wbs, proposed)
	assert.Contains(t, stderr, "context boom")
	top := coachJSONObject(t, stdout)
	assert.JSONEq(t, `1`, string(top["written"]))
}
