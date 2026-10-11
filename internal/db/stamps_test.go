package db

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// stampFixture is testdata/stamps/stamps.json, shared with the Desktop's
// stamp parser tests (see its README).
type stampFixture struct {
	Layout  string   `json:"layout"`
	Columns []string `json:"columns"`
	Valid   []struct {
		Stamp  string `json:"stamp"`
		UnixMS int64  `json:"unix_ms"`
	} `json:"valid"`
	Invalid []string `json:"invalid"`
}

func TestStampFixtureRoundTrips(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("testdata", "stamps", "stamps.json"))
	require.NoError(t, err)
	var f stampFixture
	require.NoError(t, json.Unmarshal(raw, &f))
	assert.Equal(t, agentStateAtLayout, f.Layout, "the fixture's layout is the one Go writes")
	require.NotEmpty(t, f.Valid)
	require.NotEmpty(t, f.Invalid)

	for _, v := range f.Valid {
		at := time.UnixMilli(v.UnixMS)
		assert.Equal(t, v.Stamp, AgentStateStamp(at), "Go writes unix_ms %d as the fixture's stamp", v.UnixMS)
		parsed, err := time.Parse(agentStateAtLayout, v.Stamp)
		if assert.NoError(t, err, v.Stamp) {
			assert.Equal(t, v.UnixMS, parsed.UnixMilli(), v.Stamp)
		}
	}
	for _, s := range f.Invalid {
		_, err := time.Parse(agentStateAtLayout, s)
		assert.Error(t, err, "%q must not parse", s)
	}

	// Every column the fixture names exists, so a renamed column fails here.
	d := openTestDB(t)
	for _, c := range f.Columns {
		table, col, ok := strings.Cut(c, ".")
		require.True(t, ok, c)
		has, err := d.HasColumns(table, col)
		require.NoError(t, err)
		assert.True(t, has, c)
	}
}

// ParseAgentStateStamp agrees with the fixture: every valid stamp parses to
// its instant, every invalid one is refused.
func TestParseAgentStateStampOverTheFixture(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("testdata", "stamps", "stamps.json"))
	require.NoError(t, err)
	var f stampFixture
	require.NoError(t, json.Unmarshal(raw, &f))
	for _, v := range f.Valid {
		at, ok := ParseAgentStateStamp(v.Stamp)
		assert.True(t, ok, v.Stamp)
		assert.Equal(t, v.UnixMS, at.UnixMilli(), v.Stamp)
	}
	for _, s := range f.Invalid {
		_, ok := ParseAgentStateStamp(s)
		assert.False(t, ok, "%q must not parse", s)
	}
}
