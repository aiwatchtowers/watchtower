package cmd

import (
	"context"
	"encoding/json"
	"fmt"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/tower"
	"watchtower/internal/tower/api"
	"watchtower/internal/tower/commands"
)

// inbox.act writes approvals itself (a reminder's Done and Snooze, a stuck
// target's Try again), outside the tools registry. They are covered because
// towerActDeps builds the registry with buildToolRegistry on the tower's own
// handle, which installs the approval hook: each write queues the
// Needs approval run through the hook (inbox.act's own fallback Fire runs
// only on a handle without one).
func TestTowerActDeps_ApprovalWritersFireTheHook(t *testing.T) {
	cases := []struct {
		name   string
		seed   string
		target string
		verb   api.ActVerb
		params api.ActParams
	}{
		{"reminder done", `INSERT INTO reminders (id, note, remind_at) VALUES (1, 'Call back', '2026-11-16T09:00:00Z')`,
			"r1", api.ActRef, api.ActParams{RefKind: "reminder", RefID: 1, RefVerb: api.RefDone}},
		{"reminder snooze", `INSERT INTO reminders (id, note, remind_at) VALUES (1, 'Call back', '2026-11-16T09:00:00Z')`,
			"r1", api.ActRef, api.ActParams{RefKind: "reminder", RefID: 1, RefVerb: api.RefSnooze, Until: "2026-11-16T11:00:00Z"}},
		// executing since long past targetStuckAfter: Try again first moves
		// it to failed (inbox.act's own TransitionAgentAction).
		{"stuck target retry", `INSERT INTO agent_actions (id, tool, args_json, context_type, context_id, status, decided_at)
			VALUES (1, 'no_such_tool', '{}', '` + db.InboxButtonContextType + `', '1', 'executing', '2000-01-01T00:00:00Z')`,
			"a1", api.ActApproval, api.ActParams{ApprovalVerb: api.ApprovalRetry}},
	}
	for i, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			d := writeActionsConfig(t)
			cfg, err := workspaceConfigFromFlags()
			require.NoError(t, err)
			id := seedRunnableNeedsApproval(t, d)
			_, err = d.Exec(c.seed)
			require.NoError(t, err)
			require.False(t, d.HasApprovalHook())

			var r tower.Registry
			commands.RegisterAll(&r, commands.Deps{Act: towerActDeps(cfg, d, func() {})})
			require.True(t, d.HasApprovalHook(), "towerActDeps hooks the tower's handle")
			tw := tower.New(d, tower.Options{Registry: &r})

			params, err := json.Marshal(api.ActRequest{
				WriteParams: api.WriteParams{RequestID: fmt.Sprintf("00000000-0000-4000-8000-%012d", 800000+i)},
				Target:      c.target, Verb: c.verb, Params: c.params})
			require.NoError(t, err)
			desktop := tower.Origin{Transport: "socket", Desktop: func(context.Context) error { return nil }}
			resp := tw.Call(context.Background(),
				api.Request{V: api.EnvelopeVersion, ID: "1", Command: "inbox.act", Params: params}, desktop)
			require.Equal(t, api.StatusOK, resp.Status, "%+v", resp.Refusal)
			assert.Equal(t, 1, eventRunCount(t, d, id), "the write queued the Needs approval run")
		})
	}
}
