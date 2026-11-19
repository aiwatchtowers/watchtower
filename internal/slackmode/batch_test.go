package slackmode

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"

	"watchtower/internal/db"
)

func TestNewestBatches_VerdictRowPerProvider(t *testing.T) {
	t0 := time.Date(2026, 11, 18, 10, 0, 0, 0, time.UTC)
	rows := []db.SlackLiveStatus{
		{Provider: "codex", TeamID: "", Status: "not_connected", CheckedAt: t0},
		{Provider: "codex", TeamID: "T2", Status: "ok", ConnectorID: "connector_abc", CheckedAt: t0},
		{Provider: "codex", TeamID: "T1", Status: "ok", ConnectorID: "connector_abc", CheckedAt: t0},
		{Provider: "codex", TeamID: "T0", Status: "ok", CheckedAt: t0.Add(-time.Hour)},
		{Provider: "claude", TeamID: "T1", Status: "ok", CheckedAt: t0.Add(-time.Hour)},
		{Provider: "claude", TeamID: "", Status: "needs_admin", CheckedAt: t0},
		{Provider: "claude", TeamID: "T1", Status: "needs_admin", CheckedAt: t0},
	}
	got := NewestBatches(rows)
	assert.Len(t, got, 2)
	assert.Equal(t, db.SlackLiveStatus{Provider: "claude", TeamID: "", Status: "needs_admin", CheckedAt: t0}, got[0],
		"a failed batch: its first row by team")
	assert.Equal(t, db.SlackLiveStatus{Provider: "codex", TeamID: "T1", Status: "ok", ConnectorID: "connector_abc", CheckedAt: t0}, got[1],
		"an ok batch: its first ok row by team")
	assert.Equal(t, []string{"needs_admin", "ok"}, LiveVerdicts(rows))
	assert.Empty(t, NewestBatches(nil))
}
