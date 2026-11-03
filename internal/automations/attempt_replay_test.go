package automations_test

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/require"

	"watchtower/internal/automations"
	"watchtower/internal/db"
	"watchtower/internal/digest"
)

func TestRoutingUnknownUsageSurvivesPersistedReplay(t *testing.T) {
	for _, kind := range []string{"failed_unknown", "successful_estimate", "schema_invalid_known", "corrupt_metadata"} {
		t.Run(kind, func(t *testing.T) {
			p, r := routedLeaves(kind != "schema_invalid_known")
			script := `try{llm("first")}catch(e){};`
			perms := []string{"ask:owner", "llm:light"}
			switch kind {
			case "successful_estimate", "corrupt_metadata":
				p.fail = false
			case "schema_invalid_known":
				p.fail = false
				p.usage = &digest.Usage{InputTokens: 10, OutputTokens: 5}
				p.replies = []string{"invalid", "invalid", "done"}
				script = `try{llm("first",{schema:{type:"object"}})}catch(e){};`
			}
			gen := routedSDKGenerator(t, p, r, false)
			w := newWriteFixtureOpts(t, exOpts{gen: gen})
			script += resumeAskCall + `;try{return llm("after resume")}catch(e){return e.name}`
			a := w.seedWorkbenchOutput(t, "unknown-replay", perms, "inbox", script)
			id := w.enqueue(t, a, db.TriggerManual)
			w.stopWhileWaiting(t, id)
			before := w.run(t, id)
			require.False(t, before.NotResumable)
			records, err := w.d.ListAutomationRunReplay(id)
			require.NoError(t, err)
			require.Len(t, records, 2)
			unknown := kind == "failed_unknown"
			require.Equal(t, unknown, strings.Contains(records[0].ClockJSON, `"unknown_model_usage":true`))
			if !unknown {
				require.True(t, strings.HasPrefix(records[0].ClockJSON, "["), "normal legacy clock records keep array format")
			}
			if kind == "corrupt_metadata" {
				_, err = w.d.Exec(`UPDATE automation_run_replay SET clock_json=? WHERE run_id=? AND seq=1`, `{"version":99,"reads":[],"unknown_model_usage":true}`, id)
				require.NoError(t, err)
			}
			// Close the physical DB and reopen it. Fixture backends share this small
			// handle wrapper, so replacing it updates every registry/executor reference.
			var path string
			require.NoError(t, w.d.QueryRow(`SELECT file FROM pragma_database_list WHERE name='main'`).Scan(&path))
			require.NoError(t, w.d.Close())
			reopened, err := db.Open(path)
			require.NoError(t, err)
			*w.d = *reopened
			w.restart()
			stop := runExecutor(t, w.exFixture)
			defer stop()
			if kind == "corrupt_metadata" {
				run := w.waitEnded(t, id)
				require.Equal(t, db.RunFailed, run.Status)
				require.Equal(t, db.ErrKindInterrupted, run.ErrorKind)
				require.Equal(t, 1, p.calls)
				require.Zero(t, r.calls)
				return
			}
			w.waitStatus(t, id, db.RunWaiting)
			w.answerAsk(t, w.onlyAsk(t, a.ProjectID).ID)
			w.e.Wake()
			run := w.waitEnded(t, id)
			require.Equal(t, db.RunSucceeded, run.Status, run.Error)
			if unknown {
				require.Equal(t, automations.ErrNameBudget, run.Summary)
				require.Equal(t, 1, p.calls)
				require.Zero(t, r.calls)
				require.Equal(t, before.InputTokens, run.InputTokens)
				require.Equal(t, before.OutputTokens, run.OutputTokens)
			} else {
				require.Equal(t, "done", run.Summary)
				if kind == "successful_estimate" {
					require.Equal(t, 2, p.calls)
				} else {
					require.Equal(t, 3, p.calls)
				}
			}
			steps := w.steps(t, id)
			require.Len(t, steps, 3)
			require.Equal(t, automations.StepKindLLM, steps[0].Kind)
			require.Equal(t, automations.StepKindAsk, steps[1].Kind)
		})
	}
}
