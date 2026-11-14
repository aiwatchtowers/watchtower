package slackmode

import (
	"encoding/json"
	"os"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestSlackMode_SharedFixture(t *testing.T) {
	raw, err := os.ReadFile("testdata/slack_mode_cases.json")
	require.NoError(t, err)
	var cases []struct {
		Name string   `json:"name"`
		Full bool     `json:"full"`
		Live []string `json:"live"`
		Want Mode     `json:"want"`
	}
	require.NoError(t, json.Unmarshal(raw, &cases))
	require.NotEmpty(t, cases)
	for _, c := range cases {
		t.Run(c.Name, func(t *testing.T) {
			require.Equal(t, c.Want, Derive(c.Full, c.Live))
		})
	}
}
