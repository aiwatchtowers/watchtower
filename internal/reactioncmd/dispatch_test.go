package reactioncmd

import (
	"bytes"
	"context"
	"sync"
	"testing"

	"github.com/slack-go/slack"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/prompts"
)

// recordingDispatcher records every Dispatch it is handed and returns out.
type recordingDispatcher struct {
	mu   sync.Mutex
	seen []Dispatch
	out  Outcome
}

func (r *recordingDispatcher) dispatch(_ context.Context, d Dispatch) Outcome {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.seen = append(r.seen, d)
	return r.out
}

// systemCapturingGenerator records the system prompt of every call.
type systemCapturingGenerator struct {
	mu      sync.Mutex
	out     string
	systems []string
}

func (g *systemCapturingGenerator) Generate(_ context.Context, system, _, _ string) (string, *digest.Usage, string, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.systems = append(g.systems, system)
	return g.out, &digest.Usage{}, "", nil
}

func checkReaction() []slack.ReactedItem {
	return []slack.ReactedItem{msgItem("C1", "111.1", "UAUTHOR", "please handle the deploy", "",
		slack.ItemReaction{Name: "white_check_mark", Users: []string{"UOWNER"}})}
}

// A custom dispatcher is handed the routed tool: a :ticket: (create_jira_issue
// in the dictionary) in a Linear-keyed channel arrives as create_linear_issue.
func TestReactionCmd_CustomDispatcherSeesRoutedTool(t *testing.T) {
	database := seededPipelineDB(t, 1)
	connectJira(t, database, "ABC")
	connectLinear(t, database, "ENG")
	addChannelMessage(t, database, "1:C1", "400.1", "ENG-41 is still open")
	gen := &mockGenerator{out: `{"reason":"x"}`}
	var logs bytes.Buffer
	p := routingPipeline(t, database, gen, []string{"main", "target", "reaction"}, ticketReaction("login is broken again"), &logs)
	rec := &recordingDispatcher{out: Outcome{Status: "dispatched", Step: StepFinalize}}
	p.SetDispatcher(rec.dispatch)

	n, err := p.Run(context.Background(), nil)
	require.NoError(t, err)
	assert.Equal(t, 1, n)
	require.Len(t, rec.seen, 1)
	d := rec.seen[0]
	assert.Equal(t, toolLinearIssue, d.Tool)
	assert.Equal(t, int64(1), d.AccountID)
	assert.Equal(t, "1:C1", d.ChannelID)
	assert.Equal(t, "500.1", d.MessageTS)
	assert.Equal(t, "ticket", d.Emoji)
	assert.Equal(t, 0, gen.calls, "a custom dispatcher replaces the built-in compose")
	assert.Equal(t, 0, countAllAgentActions(t, database))
}

// The dispatcher's Outcome drives the ledger exactly as the built-in dispatch
// did: release deletes the provisional row, strand leaves it provisional, and
// finalize records the status, action id and detail.
func TestReactionCmd_DispatcherOutcomeDrivesLedger(t *testing.T) {
	cases := []struct {
		name       string
		out        Outcome
		wantRows   int
		wantStatus string
		wantErr    string
		wantN      int
	}{
		{name: "release", out: Outcome{Step: StepRelease}, wantRows: 0},
		{name: "strand", out: Outcome{Status: "dispatched", Step: StepStrand}, wantRows: 1, wantStatus: db.ReactionCommandProvisional},
		{name: "finalize failed", out: Outcome{Status: "failed", Detail: "compose: nope", Step: StepFinalize},
			wantRows: 1, wantStatus: "failed", wantErr: "compose: nope"},
		{name: "finalize dispatched", out: Outcome{Status: "dispatched", ActionID: 42, Step: StepFinalize},
			wantRows: 1, wantStatus: "dispatched", wantN: 1},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			database := seededPipelineDB(t, 1)
			p := newTestPipeline(t, database, &mockGenerator{}, checkReaction())
			rec := &recordingDispatcher{out: tc.out}
			p.SetDispatcher(rec.dispatch)

			n, err := p.Run(context.Background(), nil)
			require.NoError(t, err)
			assert.Equal(t, tc.wantN, n)
			require.Len(t, rec.seen, 1)
			require.Equal(t, tc.wantRows, countRows(t, database, "reaction_commands"))
			if tc.wantRows == 0 {
				// Released: the next poll hands the same command over again.
				_, err := p.Run(context.Background(), nil)
				require.NoError(t, err)
				assert.Len(t, rec.seen, 2, "a released command retries")
				return
			}
			var status, errText string
			var actionID int64
			require.NoError(t, database.QueryRow(
				`SELECT status, COALESCE(action_id, 0), COALESCE(error, '') FROM reaction_commands`).Scan(&status, &actionID, &errText))
			assert.Equal(t, tc.wantStatus, status)
			assert.Equal(t, tc.out.ActionID, actionID)
			assert.Equal(t, tc.wantErr, errText)
			_, err = p.Run(context.Background(), nil)
			require.NoError(t, err)
			assert.Len(t, rec.seen, 1, "a held row is never handed over again")
		})
	}
}

// A dispatcher that calls DispatchWith with its own prompt reaches the
// generator with that system prompt; "" keeps the prompt store's prompt.
func TestReactionCmd_DispatchWithPromptReachesGenerator(t *testing.T) {
	database := seededPipelineDB(t, 1)
	gen := &systemCapturingGenerator{out: `{"text":"Handle the deploy","reason":"owner flagged it"}`}
	p := newTestPipeline(t, database, gen, checkReaction())
	var prompt string
	p.SetDispatcher(func(ctx context.Context, d Dispatch) Outcome {
		return p.DispatchWith(ctx, d, prompt)
	})
	prompt = "RECIPE SYSTEM PROMPT"

	n, err := p.Run(context.Background(), nil)
	require.NoError(t, err)
	require.Equal(t, 1, n)
	require.Len(t, gen.systems, 1)
	assert.Equal(t, "RECIPE SYSTEM PROMPT", gen.systems[0])
	tool, status := dispatchedTool(t, database)
	assert.Equal(t, "create_target", tool)
	assert.Equal(t, "pending", status)
	var contextID string
	require.NoError(t, database.QueryRow(`SELECT context_id FROM agent_actions`).Scan(&contextID))
	assert.Equal(t, "1:C1@111.1", contextID, "REACT-02: the binding carries the real message ref")

	// The default ("") resolves the prompt store's reaction-command prompt.
	database2 := seededPipelineDB(t, 1)
	gen2 := &systemCapturingGenerator{out: gen.out}
	p2 := newTestPipeline(t, database2, gen2, checkReaction())
	_, err = p2.Run(context.Background(), nil)
	require.NoError(t, err)
	require.Len(t, gen2.systems, 1)
	want, _ := p2.getPrompt(prompts.ReactionCommand)
	assert.NotEmpty(t, want)
	assert.Equal(t, want, gen2.systems[0])
}

// The 25-per-run cap holds for a custom dispatcher too: it is never called
// for a command past the cap, and the overflow stays unrecorded.
func TestReactionCmd_DispatcherNotCalledPastTheCap(t *testing.T) {
	database := seededPipelineDB(t, 1)
	p := newTestPipeline(t, database, &mockGenerator{}, dictionaryReactions("C1", maxDispatchPerRun+2))
	rec := &recordingDispatcher{out: Outcome{Status: "dispatched", Step: StepFinalize}}
	p.SetDispatcher(rec.dispatch)

	n, err := p.Run(context.Background(), nil)
	require.NoError(t, err)
	assert.Equal(t, maxDispatchPerRun, n)
	assert.Len(t, rec.seen, maxDispatchPerRun)
	assert.Equal(t, maxDispatchPerRun, countRows(t, database, "reaction_commands"))

	n, err = p.Run(context.Background(), nil)
	require.NoError(t, err)
	assert.Equal(t, 2, n, "the deferred remainder drains on the next poll")
	assert.Len(t, rec.seen, maxDispatchPerRun+2)
}

// A paused pipeline still seeds and publishes reaction events, but claims
// nothing — not even a free skip — and spends nothing; resuming dispatches
// what was placed meanwhile.
func TestReactionCmd_PausedClaimsNothingButPublishes(t *testing.T) {
	lister := &countingLister{}
	gen := &mockGenerator{out: `{"text":"Handle the deploy","reason":"owner flagged it"}`}
	p, database := eventTestPipeline(t, lister, gen)
	sink := &recordingSink{wants: true}
	seedEvents(t, p)
	p.SetDispatchPaused(true)

	freeSkipReaction(t, database) // maps no_entry to an unregistered tool
	lister.set(
		msgItem("C1", ts1, "UAUTHOR", "please handle the deploy", "",
			slack.ItemReaction{Name: "white_check_mark", Users: []string{"UOWNER"}}),
		msgItem("C9", ts2, "UAUTHOR", "unmapped", "",
			slack.ItemReaction{Name: "no_entry", Users: []string{"UOWNER"}}),
	)
	n, err := p.Run(context.Background(), sink)
	require.NoError(t, err)
	assert.Equal(t, 0, n)
	assert.Equal(t, 0, gen.calls, "no AI call while paused")
	assert.Equal(t, 0, countRows(t, database, "reaction_commands"), "no ledger row, not even a skip")
	assert.Len(t, sink.events, 2, "events still publish while paused")

	// A paused poll still seeds an account it has never seen.
	_, err = database.Exec(`UPDATE slack_accounts SET reaction_commands_seeded_at = '' WHERE id = 1`)
	require.NoError(t, err)
	_, err = p.Run(context.Background(), sink)
	require.NoError(t, err)
	seeded, err := database.ReactionCommandsSeeded(1)
	require.NoError(t, err)
	assert.True(t, seeded, "seeding runs while paused")
	assert.Equal(t, 0, gen.calls)
}

// Resuming dispatches the commands placed while paused.
func TestReactionCmd_ResumeDispatchesWhatWasPlacedWhilePaused(t *testing.T) {
	database := seededPipelineDB(t, 1)
	gen := &mockGenerator{out: `{"text":"Handle the deploy","reason":"owner flagged it"}`}
	p := newTestPipeline(t, database, gen, checkReaction())
	p.SetDispatchPaused(true)
	n, err := p.Run(context.Background(), nil)
	require.NoError(t, err)
	assert.Equal(t, 0, n)

	p.SetDispatchPaused(false)
	n, err = p.Run(context.Background(), nil)
	require.NoError(t, err)
	assert.Equal(t, 1, n)
	assert.Equal(t, 1, gen.calls)
}

// An outcome the ledger cannot record becomes a failed finalize naming it.
func TestReactionCmd_InvalidDispatcherOutcomeFinalizesFailed(t *testing.T) {
	cases := []struct {
		name string
		out  Outcome
		want string
	}{
		{name: "zero outcome", out: Outcome{}, want: `dispatcher returned an invalid outcome (step 0, status "")`},
		{name: "pending status", out: Outcome{Status: "pending", Step: StepFinalize}, want: `dispatcher returned an invalid outcome (step 0, status "pending")`},
		{name: "unknown step", out: Outcome{Status: "dispatched", Step: Step(7)}, want: `dispatcher returned an invalid outcome (step 7, status "dispatched")`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			database := seededPipelineDB(t, 1)
			p := newTestPipeline(t, database, &mockGenerator{}, checkReaction())
			rec := &recordingDispatcher{out: tc.out}
			p.SetDispatcher(rec.dispatch)

			n, err := p.Run(context.Background(), nil)
			require.NoError(t, err)
			assert.Equal(t, 0, n)
			var status, errText string
			require.NoError(t, database.QueryRow(`SELECT status, error FROM reaction_commands`).Scan(&status, &errText))
			assert.Equal(t, "failed", status)
			assert.Equal(t, tc.want, errText)
		})
	}
}

// A panicking dispatcher fails its own row (logged) and the pass goes on to
// the next command.
func TestReactionCmd_DispatcherPanicFailsRowAndPassContinues(t *testing.T) {
	database := seededPipelineDB(t, 1)
	var logs bytes.Buffer
	p := newLoggingTestPipeline(t, database, &mockGenerator{}, dictionaryReactions("C1", 2), &logs)
	calls := 0
	p.SetDispatcher(func(context.Context, Dispatch) Outcome {
		calls++
		if calls == 1 {
			panic("boom")
		}
		return Outcome{Status: "dispatched", Step: StepFinalize}
	})

	n, err := p.Run(context.Background(), nil)
	require.NoError(t, err)
	assert.Equal(t, 1, n, "the second command still dispatches")
	assert.Equal(t, 2, calls)
	assert.ElementsMatch(t, []string{"dispatched", "failed"}, ledgerStatuses(t, database))
	var errText string
	require.NoError(t, database.QueryRow(`SELECT error FROM reaction_commands WHERE status = 'failed'`).Scan(&errText))
	assert.Equal(t, "dispatcher panic: boom", errText)
	assert.Contains(t, logs.String(), "dispatcher panicked")
}

// DispatchWith refuses a Dispatch the pipeline did not build (no resolved tool).
func TestReactionCmd_DispatchWithoutToolFails(t *testing.T) {
	database := seededPipelineDB(t, 1)
	gen := &mockGenerator{}
	p := newTestPipeline(t, database, gen, nil)
	out := p.DispatchWith(context.Background(), Dispatch{Tool: "create_target", ChannelID: "1:C1", MessageTS: "1.1"}, "")
	assert.Equal(t, Outcome{Status: "failed", Detail: "dispatch: no resolved tool", Step: StepFinalize}, out)
	assert.Equal(t, 0, gen.calls)
	assert.Equal(t, 0, countAllAgentActions(t, database))
}

// usageGenerator replies out with usage.
type usageGenerator struct {
	out   string
	usage digest.Usage
}

func (g *usageGenerator) Generate(context.Context, string, string, string) (string, *digest.Usage, string, error) {
	u := g.usage
	return g.out, &u, "", nil
}

// DispatchWith carries the compose call's usage on its Outcome, dispatched
// or failed, for the Reactions built-in to report.
func TestReactionCmd_DispatchWithCarriesComposeUsage(t *testing.T) {
	for name, reply := range map[string]string{
		"dispatched": `{"text":"Handle the deploy","reason":"owner flagged it"}`,
		"failed":     "no json here",
	} {
		t.Run(name, func(t *testing.T) {
			database := seededPipelineDB(t, 1)
			gen := &usageGenerator{out: reply, usage: digest.Usage{InputTokens: 120, OutputTokens: 30}}
			p := newTestPipeline(t, database, gen, checkReaction())
			var got []Outcome
			p.SetDispatcher(func(ctx context.Context, d Dispatch) Outcome {
				out := p.DispatchWith(ctx, d, "")
				got = append(got, out)
				return out
			})
			_, err := p.Run(context.Background(), nil)
			require.NoError(t, err)
			require.Len(t, got, 1)
			assert.Equal(t, name, got[0].Status)
			assert.Equal(t, 120, got[0].Usage.InputTokens)
			assert.Equal(t, 30, got[0].Usage.OutputTokens)
		})
	}
}
