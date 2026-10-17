package kb

import (
	"context"
	"database/sql"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/db/lockmetrics"
)

// A KB-index transaction's lock-metrics site names kb.withTx's caller, not
// the helper alone: the helper is in lockmetrics' genericHelpers.
func TestWithTx_LockMetricsSiteNamesTheCaller(t *testing.T) {
	if v := os.Getenv("WATCHTOWER_DBLOCK_THRESHOLD_MS"); v != "" {
		t.Skipf("WATCHTOWER_DBLOCK_THRESHOLD_MS=%q overrides the default threshold", v)
	}
	path := filepath.Join(t.TempDir(), "watchtower.db")
	d, err := db.Open(path)
	require.NoError(t, err)
	t.Cleanup(func() { _ = d.Close() })

	hold := lockmetrics.DefaultThreshold + 50*time.Millisecond
	require.NoError(t, withTx(context.Background(), d, func(*sql.Tx) error { time.Sleep(hold); return nil }))

	raw, err := os.ReadFile(filepath.Join(filepath.Dir(path), lockmetrics.FileName))
	require.NoError(t, err)
	const site = "internal/kb.withTx <- internal/kb.TestWithTx_LockMetricsSiteNamesTheCaller"
	var sites []string
	for line := range strings.SplitSeq(strings.TrimSpace(string(raw)), "\n") {
		var e lockmetrics.Event
		require.NoError(t, json.Unmarshal([]byte(line), &e), line)
		if e.Kind == lockmetrics.KindTx && e.Site == site {
			return
		}
		sites = append(sites, e.Kind+" "+e.Site)
	}
	t.Fatalf("no tx event with site %q; got %v", site, sites)
}
