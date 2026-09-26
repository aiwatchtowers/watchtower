package cmd

import (
	"bytes"
	"context"
	"os"
	"testing"

	"github.com/spf13/cobra"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// TestOwner02_UserTriggeredCommandsFailWithoutOwner pins OWNER-02: every
// user-triggered owner-scoped command, run against a workspace with no
// connected account, fails with db.ErrNoOwner — never a stdout note and
// exit 0 (the Desktop's CLI runner only surfaces a non-zero exit).
func TestOwner02_UserTriggeredCommandsFailWithoutOwner(t *testing.T) {
	cases := []struct {
		name string
		cmd  *cobra.Command
		args []string
		prep func(t *testing.T)
	}{
		{name: "day-plan generate", cmd: dayPlanGenerateCmd},
		{name: "day-plan show", cmd: dayPlanShowCmd, args: []string{"2026-04-23"}},
		{name: "day-plan list", cmd: dayPlanListCmd},
		{name: "day-plan reset", cmd: dayPlanResetCmd, args: []string{"2026-04-23"}},
		{name: "day-plan check-conflicts", cmd: dayPlanCheckConflictsCmd, args: []string{"2026-04-23"}},
		{name: "briefing generate", cmd: briefingGenerateCmd},
		{name: "briefing show", cmd: briefingCmd},
		{name: "briefing list", cmd: briefingListCmd},
		{name: "tracks create", cmd: tracksCreateCmd, prep: func(t *testing.T) {
			prev := tracksCreateFlagText
			tracksCreateFlagText = "watch the release"
			t.Cleanup(func() { tracksCreateFlagText = prev })
		}},
		{name: "profile", cmd: profileCmd},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			setupTempWorkspace(t)
			// A dead ollama endpoint: a command that reached its AI call
			// before the owner check fails fast with a non-ErrNoOwner error
			// instead of spawning a real provider.
			require.NoError(t, os.WriteFile(flagConfig, []byte(
				"active_workspace: test\nai:\n  provider: ollama\n  ollama_url: http://127.0.0.1:1\n  models:\n    strong: none\n"), 0o600))
			if tc.prep != nil {
				tc.prep(t)
			}
			var buf bytes.Buffer
			tc.cmd.SetOut(&buf)
			tc.cmd.SetErr(&buf)
			tc.cmd.SetContext(context.Background())
			t.Cleanup(func() {
				tc.cmd.SetOut(nil)
				tc.cmd.SetErr(nil)
			})

			err := tc.cmd.RunE(tc.cmd, tc.args)
			require.Error(t, err, "no owner must be a visible error, not exit 0 (output: %q)", buf.String())
			assert.ErrorIs(t, err, db.ErrNoOwner)
		})
	}
}
