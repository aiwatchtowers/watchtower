package sessionstart

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/devpack"
)

// launchCase is one entry of testdata/launch_cases.json, written from the
// Swift TerminalLaunch by TerminalLaunchFixtureTests (WT_E2E_REGENERATE=1).
type launchCase struct {
	Name  string `json:"name"`
	Shell string `json:"shell"`
	Dir   string `json:"folder"`
	Row   int64  `json:"row"`
	Mode  struct {
		Agent     string  `json:"agent"`
		SessionID string  `json:"session_id"`
		Prompt    *string `json:"prompt"`
		Resume    bool    `json:"resume"`
	} `json:"mode"`
	Codex           *devpack.LaunchArgs `json:"codex"`
	Setup           string              `json:"setup"`
	AutomationRunID int64               `json:"automation_run_id"`
	Want            struct {
		Executable string   `json:"executable"`
		Args       []string `json:"args"`
		Dir        string   `json:"dir"`
		Env        []string `json:"env"`
		Row        int64    `json:"row"`
	} `json:"want"`
}

func readCases[T any](t *testing.T, name string) []T {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("testdata", name))
	require.NoError(t, err)
	var cases []T
	require.NoError(t, json.Unmarshal(data, &cases))
	require.NotEmpty(t, cases)
	return cases
}

func TestLaunchFixtures(t *testing.T) {
	cases := readCases[launchCase](t, "launch_cases.json")
	assert.GreaterOrEqual(t, len(cases), 26)
	for _, c := range cases {
		m := Mode{
			Agent: c.Mode.Agent, SessionID: c.Mode.SessionID, Prompt: c.Mode.Prompt,
			Resume: c.Mode.Resume, AutomationRunID: c.AutomationRunID,
		}
		got, err := Launch(m, c.Row, c.Dir, c.Shell, c.Codex, c.Setup)
		require.NoError(t, err, c.Name)
		assert.Equal(t, c.Want.Executable, got.Executable, c.Name)
		assert.Equal(t, c.Want.Args, got.Args, c.Name)
		assert.Equal(t, c.Want.Dir, got.Dir, c.Name)
		assert.Equal(t, c.Want.Env, nonNil(got.Env), c.Name)
		assert.Equal(t, c.Want.Row, got.Row, c.Name)
	}
}

func nonNil(s []string) []string {
	if s == nil {
		return []string{}
	}
	return s
}

func TestLaunchRefusesWhatCouldReachTheShell(t *testing.T) {
	const id = "0e5c5d2a-1b3c-4d5e-8f90-a1b2c3d4e5f6"
	bad := map[string]Mode{
		"unknown agent":            {Agent: "bash", SessionID: id},
		"agent kind is exact":      {Agent: "Claude", SessionID: id},
		"claude without an id":     {Agent: "claude"},
		"claude with a shell word": {Agent: "claude", SessionID: id + ";rm"},
		"resume with an upper id":  {Agent: "claude", SessionID: "0E5C5D2A-1B3C-4D5E-8F90-A1B2C3D4E5F6", Resume: true},
		"codex resume without id":  {Agent: "codex", Resume: true},
		"codex new with a bad id":  {Agent: "codex", SessionID: "$(id)"},
		"shell resume":             {Resume: true},
		"shell with an id":         {SessionID: id},
		"shell with a prompt":      {Prompt: new("x")},
	}
	for name, m := range bad {
		_, err := Launch(m, 1, "/work", "/bin/zsh", nil, "")
		assert.Error(t, err, name)
	}
}

func TestIsValidSessionID(t *testing.T) {
	for _, id := range []string{"0e5c5d2a-1b3c-4d5e-8f90-a1b2c3d4e5f6", "019a1b2c-3d4e-7f50-8a6b-7c8d9e0f1a2b"} {
		assert.True(t, IsValidSessionID(id), id)
	}
	for _, id := range []string{
		"", "0e5c5d2a1b3c4d5e8f90a1b2c3d4e5f6", "0E5C5D2A-1B3C-4D5E-8F90-A1B2C3D4E5F6",
		"0e5c5d2a-1b3c-4d5e-8f90-a1b2c3d4e5f", "0e5c5d2a-1b3c-4d5e-8f90-a1b2c3d4e5f6a",
		"0e5c5d2a_1b3c-4d5e-8f90-a1b2c3d4e5f6", "ge5c5d2a-1b3c-4d5e-8f90-a1b2c3d4e5f6",
		"0e5c5d2a-1b3c-4d5e-8f90-a1b2c3d4e5é",
	} {
		assert.False(t, IsValidSessionID(id), id)
	}
}
