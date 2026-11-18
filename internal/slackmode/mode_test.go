package slackmode

import (
	"encoding/json"
	"os"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// TestSlackMode_SharedFixture runs every case of the fixture the Swift twin
// (SlackModeFixtureTests) reads. A case gives either "live" (the verdicts
// themselves) or "probes" (slack_live_status rows, reduced to each
// provider's newest batch by LiveVerdicts first).
func TestSlackMode_SharedFixture(t *testing.T) {
	raw, err := os.ReadFile("testdata/slack_mode_cases.json")
	require.NoError(t, err)
	var cases []struct {
		Name   string   `json:"name"`
		Full   bool     `json:"full"`
		Live   []string `json:"live"`
		Probes []struct {
			Provider  string `json:"provider"`
			Team      string `json:"team"`
			Status    string `json:"status"`
			CheckedAt string `json:"checked_at"`
		} `json:"probes"`
		Want Mode `json:"want"`
	}
	require.NoError(t, json.Unmarshal(raw, &cases))
	require.NotEmpty(t, cases)
	for _, c := range cases {
		t.Run(c.Name, func(t *testing.T) {
			live := c.Live
			if c.Probes != nil {
				require.Nil(t, c.Live, "a case gives live or probes, not both")
				rows := make([]db.SlackLiveStatus, 0, len(c.Probes))
				for _, p := range c.Probes {
					at, err := time.Parse(time.RFC3339Nano, p.CheckedAt)
					require.NoError(t, err)
					rows = append(rows, db.SlackLiveStatus{Provider: p.Provider, TeamID: p.Team, Status: p.Status, CheckedAt: at})
				}
				live = LiveVerdicts(rows)
			}
			require.Equal(t, c.Want, Derive(c.Full, live))
		})
	}
}
