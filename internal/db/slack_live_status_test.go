package db

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

func slackLiveAt(h, m int) time.Time { return time.Date(2026, 11, 14, h, m, 0, 0, time.UTC) }

func TestUpsertSlackLiveStatus_NewestWins(t *testing.T) {
	d, err := Open(":memory:")
	require.NoError(t, err)
	defer d.Close()

	require.NoError(t, d.UpsertSlackLiveStatus(SlackLiveStatus{TeamID: "T1", Provider: "claude", Status: "ok", CheckedAt: slackLiveAt(10, 0)}))
	require.NoError(t, d.UpsertSlackLiveStatus(SlackLiveStatus{TeamID: "T1", Provider: "claude", Status: "not_connected", CheckedAt: slackLiveAt(9, 0)}))
	got, err := d.ListSlackLiveStatus()
	require.NoError(t, err)
	require.Len(t, got, 1)
	require.Equal(t, "ok", got[0].Status)
	require.True(t, slackLiveAt(10, 0).Equal(got[0].CheckedAt))

	require.NoError(t, d.UpsertSlackLiveStatus(SlackLiveStatus{TeamID: "T1", Provider: "claude", Status: "unavailable", ErrorClass: "timeout", CheckedAt: slackLiveAt(11, 0)}))
	got, err = d.ListSlackLiveStatus()
	require.NoError(t, err)
	require.Len(t, got, 1)
	require.Equal(t, "unavailable", got[0].Status)
	require.Equal(t, "timeout", got[0].ErrorClass)
}

func TestUpsertSlackLiveStatus_KeepsConnectorID(t *testing.T) {
	d, err := Open(":memory:")
	require.NoError(t, err)
	defer d.Close()

	require.NoError(t, d.UpsertSlackLiveStatus(SlackLiveStatus{TeamID: "", Provider: "codex", Status: "ok", ConnectorID: "app_X", CheckedAt: slackLiveAt(10, 0)}))
	require.NoError(t, d.UpsertSlackLiveStatus(SlackLiveStatus{TeamID: "", Provider: "codex", Status: "ok", CheckedAt: slackLiveAt(11, 0)}))
	got, err := d.ListSlackLiveStatus()
	require.NoError(t, err)
	require.Len(t, got, 1)
	require.Equal(t, "app_X", got[0].ConnectorID)
	require.True(t, slackLiveAt(11, 0).Equal(got[0].CheckedAt))
}

func TestListSlackLiveStatus_NewestFirst(t *testing.T) {
	d, err := Open(":memory:")
	require.NoError(t, err)
	defer d.Close()

	require.NoError(t, d.UpsertSlackLiveStatus(SlackLiveStatus{TeamID: "T1", Provider: "claude", Status: "ok", CheckedAt: slackLiveAt(8, 0)}))
	require.NoError(t, d.UpsertSlackLiveStatus(SlackLiveStatus{TeamID: "T2", Provider: "claude", Status: "no_plan", CheckedAt: slackLiveAt(12, 0)}))
	got, err := d.ListSlackLiveStatus()
	require.NoError(t, err)
	require.Len(t, got, 2)
	require.Equal(t, "T2", got[0].TeamID)
}

// A row whose checked_at does not parse is skipped, never the whole read.
func TestListSlackLiveStatusContext_SkipsUnreadableCheckedAt(t *testing.T) {
	d, err := Open(":memory:")
	require.NoError(t, err)
	defer d.Close()

	require.NoError(t, d.UpsertSlackLiveStatus(SlackLiveStatus{TeamID: "T1", Provider: "claude", Status: "ok", CheckedAt: slackLiveAt(8, 0)}))
	_, err = d.Exec(`INSERT INTO slack_live_status (team_id, provider, status, error_class, connector_id, checked_at)
VALUES ('', 'codex', 'ok', '', '', 'yesterday')`)
	require.NoError(t, err)
	got, err := d.ListSlackLiveStatusContext(context.Background())
	require.NoError(t, err)
	require.Len(t, got, 1)
	require.Equal(t, "claude", got[0].Provider)
}

func TestListSlackLiveStatusContext_HonoursCancel(t *testing.T) {
	d, err := Open(":memory:")
	require.NoError(t, err)
	defer d.Close()

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err = d.ListSlackLiveStatusContext(ctx)
	require.ErrorIs(t, err, context.Canceled)
}
