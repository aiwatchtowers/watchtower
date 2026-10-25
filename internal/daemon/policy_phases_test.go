package daemon

import (
	"bytes"
	"context"
	"log"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"

	"watchtower/internal/caldav"
	"watchtower/internal/calendar"
	"watchtower/internal/db"
	"watchtower/internal/extsync"
	"watchtower/internal/policy/policytest"
	"watchtower/internal/sync"
)

type countingExternalSync struct{ runs, checks int }

func (c *countingExternalSync) Run(context.Context) (extsync.Stats, error) {
	c.runs++
	return extsync.Stats{}, nil
}

func (c *countingExternalSync) HasRunnable([]db.ExtSource) bool {
	c.checks++
	return true
}

// TestPolicySync_EveryPhaseReturnsBeforeAnyAccount covers the phases whose
// syncers are concrete types: zero-value syncers panic if touched, so a
// forbidden source must return before reaching them (Slack, Calendar,
// CalDAV), and Confluence must not even ask its runner (#608).
func TestPolicySync_EveryPhaseReturnsBeforeAnyAccount(t *testing.T) {
	d, _, _ := newJiraTestDaemon(t)
	var logs bytes.Buffer
	d.SetLogger(log.New(&logs, "", 0))
	d.orchestrators = []*sync.Orchestrator{{}}
	d.calendarSyncers = []*calendar.Syncer{{}}
	d.calDAVSyncers = []*caldav.Syncer{{}}
	ext := &countingExternalSync{}
	d.externalSync = ext
	d.config.Knowledge.Connectors.Enabled = true

	policytest.Set(t, map[string]any{"AllowedSources": []any{"linear"}})
	ctx := context.Background()
	syncErr, inboxErr := d.phaseSlackSync(ctx)
	assert.NoError(t, syncErr)
	assert.NoError(t, inboxErr)
	d.phaseCalendarSync(ctx)
	d.phaseCalDAVSync(ctx)
	d.phaseExternalSync(ctx)

	assert.Zero(t, ext.checks+ext.runs, "Confluence is not asked")
	for _, src := range []string{"slack", "google", "caldav", "jira"} {
		assert.Equal(t, 1, strings.Count(logs.String(), "policy: "+src+" sync skipped"), src)
	}
}
