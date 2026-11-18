package daemon

import (
	"bytes"
	"go/parser"
	"go/token"
	"log"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/company"
	"watchtower/internal/companybundle"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/policy/policytest"
)

// forcedAcme is a forced bundle of made-up ids with Atlassian clientID.
func forcedAcme(t *testing.T, clientID string) string {
	t.Helper()
	w, err := companybundle.Encode(companybundle.Bundle{
		V: 1, Company: "Acme",
		Google:    &companybundle.Google{ClientID: "1234-abcd.apps.googleusercontent.com", ClientSecret: "sample-secret"},
		Atlassian: &companybundle.Atlassian{ClientID: clientID, ClientSecret: "acme-secret", Site: "https://acme.atlassian.net"},
	})
	require.NoError(t, err)
	return w
}

// TestDaemonRun_AppliesForcedChangesBeforeFirstCycle: a forced Acme whose
// Atlassian client differs from the last forced bundle seen marks Acme's
// Atlassian accounts Re-login when the daemon starts, before anything syncs
// (Run calls applyForcedCompany ahead of automations, the startup calendar
// sync and runLoop's first cycle — pinned statically, as
// TestDaemon_Run_SyncsCalendarsBeforeFirstCycle does), and once per start:
// no cycle calls it.
func TestDaemonRun_AppliesForcedChangesBeforeFirstCycle(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	d := newQuietDaemon(t)
	d.db = db.OpenTestDB(t)
	jira, err := d.db.CreateJiraAccount(db.JiraAccount{CloudID: "c1", SiteURL: "https://acme.atlassian.net", CompanySlug: "acme"})
	require.NoError(t, err)
	google, err := d.db.CreateGoogleAccount(db.GoogleAccount{Email: "a@example.com", CompanySlug: "acme"})
	require.NoError(t, err)
	// The last start saw client 01.
	_, err = company.ApplyForcedChanges(d.db, company.NewStore(d.config.WorkspaceDir()), forcedAcme(t, "acmeClientId01"))
	require.NoError(t, err)

	policytest.Set(t, map[string]any{"CompanyBundle": forcedAcme(t, "acmeClientId02")})
	d.applyForcedCompany()

	j, err := d.db.GetJiraAccount(jira)
	require.NoError(t, err)
	assert.Equal(t, "error", j.Status)
	assert.Equal(t, company.ChangedAppCode, j.Error)
	g, err := d.db.GetGoogleAccount(google)
	require.NoError(t, err)
	assert.Equal(t, "ok", g.Status, "an unchanged vendor is untouched")

	file, err := parser.ParseFile(token.NewFileSet(), "daemon.go", nil, 0)
	require.NoError(t, err)
	order := topLevelCallOrder(daemonFunc(t, file, "Run", true))
	at, ok := order["applyForcedCompany"]
	require.True(t, ok, "Run must call applyForcedCompany")
	for _, later := range []string{"startAutomations", "startupCalendarSync", "runLoop"} {
		assert.Less(t, at, order[later], "applyForcedCompany must run before %s", later)
	}
	for _, fn := range []string{"runSync", "runLoop"} {
		f := file
		if fn == "runLoop" {
			f, err = parser.ParseFile(token.NewFileSet(), "cycle.go", nil, 0)
			require.NoError(t, err)
		}
		assert.False(t, calledMethods(daemonFunc(t, f, fn, true))["applyForcedCompany"], "%s must not apply the forced bundle (once per start)", fn)
	}
}

// TestDaemonRun_ForcedChangesErrorDoesNotStopDaemon: a forced bundle that
// cannot be applied (the company directory unreadable) is logged and the
// daemon still runs its cycles.
func TestDaemonRun_ForcedChangesErrorDoesNotStopDaemon(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	var syncCount atomic.Int32
	orch, _ := newTestOrchestrator(t, &syncCount)
	cfg := &config.Config{Sync: config.SyncConfig{PollInterval: 10 * time.Second}}
	d := newDaemon(orch, cfg)
	var logs bytes.Buffer
	d.SetLogger(log.New(&logs, "", 0))
	d.SetDB(db.OpenTestDB(t))

	// A file where the company directory belongs: the store cannot read it.
	ws := cfg.WorkspaceDir()
	require.NoError(t, os.MkdirAll(ws, 0o700))
	require.NoError(t, os.WriteFile(filepath.Join(ws, "company"), []byte("x"), 0o600))
	policytest.Set(t, map[string]any{"CompanyBundle": forcedAcme(t, "acmeClientId02")})

	require.NoError(t, runDaemonCycles(t, d, 1))
	assert.GreaterOrEqual(t, syncCount.Load(), int32(1), "the daemon still syncs")
	assert.Contains(t, logs.String(), "company: applying the forced bundle:")
}
