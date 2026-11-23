package daemon

import (
	"bytes"
	"context"
	"log"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"

	"watchtower/internal/db"
	"watchtower/internal/policy/policytest"
	"watchtower/internal/purge"
)

// TestAccountPolicy_StopsOneAccountKeepsOthers (#1887 D24, POLICY-03): an
// account the per-account verdict refuses (an own Google project under
// AllowOwnGoogleProject = false) is skipped by the Gmail phase and left out
// of the history backfill, its purge leases held; the other account of the
// same source syncs. The skip is logged once per change, and the next cycle
// after the verdict flips syncs it again — its syncer stayed wired.
func TestAccountPolicy_StopsOneAccountKeepsOthers(t *testing.T) {
	d, _, _ := newJiraTestDaemon(t)
	policytest.Set(t, nil)
	setPurge(d, true)
	var logs bytes.Buffer
	d.SetLogger(log.New(&logs, "", 0))
	var own, work int
	d.gmailSyncers = []mailSyncer{policyMailSyncer{id: 1, calls: &own}, policyMailSyncer{id: 2, calls: &work}}
	stopped := true
	d.SetAccountSyncAllowed(func(source string, id int64) bool { return !(stopped && source == "google" && id == 1) })

	d.phaseGmailSync(context.Background())
	d.phaseGmailSync(context.Background())
	assert.Equal(t, []int{0, 2}, []int{own, work})
	assert.Equal(t, 1, strings.Count(logs.String(), "policy: google account 1 sync stopped by your organization's policy"))
	var ids []int64
	for _, s := range d.historyBackfillSources() {
		if s.Kind() == "gmail" {
			ids = append(ids, s.AccountID())
		}
	}
	assert.Equal(t, []int64{2}, ids, "the stopped account's backfill waits")

	rules := d.purgeRules()
	assert.Equal(t, purge.RuleRevokedAndRemoved, rules(db.PurgeAccount{Source: "google", ID: 1, Status: "ok"}), "the lease is held")
	assert.Equal(t, purge.RuleNone, rules(db.PurgeAccount{Source: "google", ID: 1, Status: "removed"}))
	assert.Equal(t, purge.AccountRules(true, nil)(db.PurgeAccount{Source: "google", ID: 2, Status: "ok"}),
		rules(db.PurgeAccount{Source: "google", ID: 2, Status: "ok"}), "the other account's rule is unchanged")

	stopped = false
	d.phaseGmailSync(context.Background())
	assert.Equal(t, []int{1, 3}, []int{own, work})
	assert.Contains(t, logs.String(), "policy: google account 1 sync allowed again")
}

// No verdict installed allows every account.
func TestAccountPolicy_NilAllowsEveryAccount(t *testing.T) {
	d, _, _ := newJiraTestDaemon(t)
	assert.True(t, d.accountPhaseAllowed("google", 1))
	assert.True(t, d.accountAllowedQuiet("jira", 2))
}
