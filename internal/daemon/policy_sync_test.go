package daemon

import (
	"bytes"
	"context"
	"log"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/policy"
	"watchtower/internal/policy/policytest"
	"watchtower/internal/reactioncmd"
)

type policyMailSyncer struct {
	id    int64
	calls *int
}

func (s policyMailSyncer) Sync(context.Context) (int, error) { *s.calls++; return 0, nil }
func (s policyMailSyncer) FetchRange(context.Context, time.Time, time.Time) (int, error) {
	return 0, nil
}
func (s policyMailSyncer) AccountID() int64                 { return s.id }
func (s policyMailSyncer) FirstSyncFrom() (time.Time, bool) { return time.Time{}, false }

type policyJiraSyncer struct {
	stubJiraSyncer
	calls *int
}

func (s *policyJiraSyncer) Sync(ctx context.Context) (int, error) {
	*s.calls++
	return s.stubJiraSyncer.Sync(ctx)
}

// TestPolicySync_PhaseSkipsDisallowedSource pins that a sync phase of a
// source the organization forbids fetches no account, its syncers stay
// wired, the skip is logged once per change, and dropping the policy lets
// the next cycle sync again (Review Focus 4).
func TestPolicySync_PhaseSkipsDisallowedSource(t *testing.T) {
	d, _, _ := newJiraTestDaemon(t)
	var logs bytes.Buffer
	d.SetLogger(log.New(&logs, "", 0))
	var gmail, imap, jira, linear int
	d.gmailSyncers = []mailSyncer{policyMailSyncer{id: 1, calls: &gmail}}
	d.imapSyncers = []mailSyncer{policyMailSyncer{id: 2, calls: &imap}}
	d.jiraSyncers = []jiraAccountSyncer{&policyJiraSyncer{stubJiraSyncer: stubJiraSyncer{accountID: 3}, calls: &jira}}
	d.linearSyncers = []linearAccountSyncer{fakeLinearSyncer{id: 4, ran: &linear}}
	cycle := func() {
		ctx := context.Background()
		d.phaseGmailSync(ctx)
		d.phaseImapSync(ctx)
		d.phaseJiraSync(ctx)
		d.phaseLinearSync(ctx)
	}

	policytest.Set(t, map[string]any{"AllowedSources": []any{"imap"}})
	cycle()
	cycle()
	assert.Equal(t, []int{0, 2, 0, 0}, []int{gmail, imap, jira, linear}, "only the allowed source syncs")
	assert.Equal(t, 1, strings.Count(logs.String(), "policy: google sync skipped by your organization's policy"), "logged once per change")
	assert.Equal(t, 1, strings.Count(logs.String(), "policy: jira sync skipped"))
	assert.Len(t, d.gmailSyncers, 1, "syncers stay wired")

	policytest.Set(t, nil)
	cycle()
	assert.Equal(t, []int{1, 3, 1, 1}, []int{gmail, imap, jira, linear}, "allowed again: the next cycle syncs every source")
	assert.Contains(t, logs.String(), "policy: google sync allowed again")
}

func TestPolicySync_SourceAllowedNoProfile(t *testing.T) {
	d, _, _ := newJiraTestDaemon(t)
	policytest.Set(t, nil)
	for _, src := range []string{"slack", "google", "imap", "caldav", "jira", "linear"} {
		assert.True(t, d.sourceAllowed(src), src)
	}
}

func TestProviderPolicy_InstructionMinerRefused(t *testing.T) {
	policytest.Set(t, map[string]any{"AllowedAIProviders": []any{"codex"}})
	_, _, _, err := instructionGeneratorFactory(&config.Config{}).Generate(context.Background(), "", "", "")
	assert.ErrorIs(t, err, policy.ErrNotAllowed)
}

// A forbidden Slack source (#608): the reaction poll lists nothing and
// leaves the event seed stamps alone (a forbidden period never reseeds).
func TestPolicySync_ReactionCommandsSkipForbiddenSlack(t *testing.T) {
	cfg := &config.Config{ReactionCommands: config.ReactionCommandsConfig{Enabled: true, IntervalHours: 1}}
	d, _ := newReactionTestDaemon(t, cfg)
	calls := 0
	accountsFn := func(context.Context) ([]reactioncmd.Account, error) {
		return []reactioncmd.Account{{AccountID: 1, OwnerID: "1:UOWNER", Lister: countingReactionLister{&calls}}}, nil
	}
	d.SetReactionCommandsPipeline(reactioncmd.New(d.db, cfg, nil, nil, accountsFn, nil))
	_, err := d.db.Exec(`UPDATE slack_accounts SET reaction_events_seeded_at = '2026-10-25T00:00:00Z'`)
	require.NoError(t, err)
	d.lastReactionCmd = time.Now() // a throttled cycle would reset the seeds

	policytest.Set(t, map[string]any{"AllowedSources": []any{"google"}})
	d.phaseReactionCommands(context.Background())

	assert.Zero(t, calls, "nothing is polled")
	var seeded string
	require.NoError(t, d.db.QueryRow(`SELECT reaction_events_seeded_at FROM slack_accounts WHERE id = 1`).Scan(&seeded))
	assert.Equal(t, "2026-10-25T00:00:00Z", seeded, "the seed stamps are untouched")
}
