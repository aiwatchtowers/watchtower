package reactioncmd

import (
	"context"
	"errors"
	"testing"

	"github.com/slack-go/slack"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// seedFixture is the history an owner has already accumulated before the
// feature is enabled: 5 reactions across 2 channels and 4 emoji, including an
// execute-trust dictionary emoji (bulb -> create_idea, which Propose applies
// INLINE) and a non-dictionary one (+1). A one- or two-reaction fixture cannot
// tell "seeded the first candidate" from "seeded all of them", which is the
// trap this fixture exists to avoid.
func seedFixture() []slack.ReactedItem {
	return []slack.ReactedItem{
		msgItem("C1", "111.1", "UAUTHOR", "please handle the deploy", "",
			slack.ItemReaction{Name: "white_check_mark", Users: []string{"UOWNER"}},
			slack.ItemReaction{Name: "+1", Users: []string{"UOWNER"}}),
		msgItem("C1", "222.2", "UAUTHOR", "an idea worth keeping", "",
			slack.ItemReaction{Name: "bulb", Users: []string{"UOWNER"}}),
		msgItem("C2", "333.3", "UAUTHOR", "we should ticket this", "",
			slack.ItemReaction{Name: "ticket", Users: []string{"UOWNER"}}),
		msgItem("C2", "444.4", "UAUTHOR", "someone else's reaction", "",
			slack.ItemReaction{Name: "white_check_mark", Users: []string{"UOWNER"}},
			// Not the owner's: must never be seeded, and must stay dispatchable
			// for the owner if they ever place it themselves.
			slack.ItemReaction{Name: "eyes", Users: []string{"USOMEONE"}}),
	}
}

type ledgerRow struct {
	channelID string
	messageTS string
	emoji     string
	status    string
	detail    string
}

func readLedger(t *testing.T, database *db.DB) []ledgerRow {
	t.Helper()
	rows, err := database.Query(`SELECT channel_id, message_ts, emoji, status, error FROM reaction_commands`)
	require.NoError(t, err)
	defer rows.Close()
	var out []ledgerRow
	for rows.Next() {
		var r ledgerRow
		require.NoError(t, rows.Scan(&r.channelID, &r.messageTS, &r.emoji, &r.status, &r.detail))
		out = append(out, r)
	}
	require.NoError(t, rows.Err())
	return out
}

func ledgerKeys(rows []ledgerRow) []string {
	out := make([]string, 0, len(rows))
	for _, r := range rows {
		out = append(out, ledgerKey(r.channelID, r.messageTS, r.emoji))
	}
	return out
}

func countRows(t *testing.T, database *db.DB, table string) int {
	t.Helper()
	var n int
	require.NoError(t, database.QueryRow(`SELECT COUNT(*) FROM `+table).Scan(&n))
	return n
}

// seedAccountsFn returns the accountsFn shape SeedLedger consumes, backed by a
// stub lister and matching the single enabled Slack account seeded below.
func seedAccountsFn(items []slack.ReactedItem) func(context.Context) ([]Account, error) {
	return func(context.Context) ([]Account, error) {
		return []Account{{AccountID: 1, OwnerID: "1:UOWNER", Lister: stubLister{items: items}}}, nil
	}
}

// seedTestDB seeds the enabled slack_accounts rows SeedLedger cross-checks the
// resolved accounts against (fail-closed: an account it cannot reach must fail
// the hook rather than be silently left unseeded).
func seedTestDB(t *testing.T, accountIDs ...int64) *db.DB {
	t.Helper()
	database := db.OpenTestDB(t)
	for _, id := range accountIDs {
		_, err := database.Exec(`INSERT INTO slack_accounts (id, team_id, team_name, current_user_id, enabled, status)
			VALUES (?, ?, ?, ?, 1, 'ok')`, id, "T", "team", "1:UOWNER")
		require.NoError(t, err)
	}
	return database
}

// TestReactionCmd_SeedRecordsHistoryWithoutDispatching pins the FEAT-03 hook:
// enabling the feature records every pre-existing owner reaction in the ledger
// as seen-but-never-run, so the FIRST poll after the enable replays nothing.
// The generator output is create_idea's shape on purpose: bulb is execute-trust,
// so an unseeded history would not merely propose — it would create an idea
// inline, which is why zero `ideas` rows is asserted alongside zero
// `agent_actions` (counting proposals alone would miss that side effect).
func TestReactionCmd_SeedRecordsHistoryWithoutDispatching(t *testing.T) {
	database := seedTestDB(t, 1)
	items := seedFixture()

	n, err := SeedLedger(context.Background(), database, seedAccountsFn(items))
	require.NoError(t, err)
	assert.Equal(t, 5, n)

	rows := readLedger(t, database)
	assert.ElementsMatch(t, []string{
		ledgerKey("1:C1", "111.1", "white_check_mark"),
		ledgerKey("1:C1", "111.1", "+1"),
		ledgerKey("1:C1", "222.2", "bulb"),
		ledgerKey("1:C2", "333.3", "ticket"),
		ledgerKey("1:C2", "444.4", "white_check_mark"),
	}, ledgerKeys(rows), "every owner reaction is seeded, dictionary or not")
	for _, r := range rows {
		assert.Equal(t, "skipped", r.status, "seeded rows are recorded, never dispatched")
		assert.Contains(t, r.detail, "seeded on enable")
	}

	// The daemon's first poll over the very same history: nothing left to do.
	gen := &mockGenerator{out: `{"essence":"an idea worth keeping","reason":"owner flagged it"}`}
	p := newTestPipeline(t, database, gen, items)
	dispatched, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Zero(t, dispatched)
	assert.Equal(t, 0, gen.calls, "the first poll after a seed makes no AI call")
	assert.Equal(t, 0, countRows(t, database, "agent_actions"), "history proposes nothing")
	assert.Equal(t, 0, countRows(t, database, "ideas"), "an execute-trust emoji creates nothing either")
	assert.Len(t, readLedger(t, database), 5, "the poll adds no ledger rows of its own")
}

// TestReactionCmd_NewReactionAfterSeedDispatchesExactlyOne pins the other half:
// the seed closes history, it does not deafen the feature. One reaction placed
// after the seed dispatches, exactly once, and nothing already seeded re-fires.
func TestReactionCmd_NewReactionAfterSeedDispatchesExactlyOne(t *testing.T) {
	database := seedTestDB(t, 1)
	items := seedFixture()
	_, err := SeedLedger(context.Background(), database, seedAccountsFn(items))
	require.NoError(t, err)

	fresh := append(append([]slack.ReactedItem{}, items...),
		msgItem("C1", "555.5", "UAUTHOR", "handle the new deploy", "",
			slack.ItemReaction{Name: "white_check_mark", Users: []string{"UOWNER"}}))
	gen := &mockGenerator{out: `{"text":"Handle the new deploy","reason":"owner flagged it"}`}
	p := newTestPipeline(t, database, gen, fresh)

	n, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 1, n, "only the post-seed reaction dispatches")
	assert.Equal(t, 1, gen.calls, "exactly one compose call")
	assert.Equal(t, 1, countRows(t, database, "agent_actions"))
	assert.Equal(t, 6, countRows(t, database, "reaction_commands"), "the seeded rows are not re-written")
}

// TestReactionCmd_SeedFailsWhenAnAccountCannotBeReached pins the fail-closed
// half of FEAT-03 for this hook: an enabled Slack account the resolver dropped
// (no usable token) must fail the seed, so `features enable` leaves the feature
// off rather than arming an unseeded account that would replay its history.
func TestReactionCmd_SeedFailsWhenAnAccountCannotBeReached(t *testing.T) {
	database := seedTestDB(t, 1, 2)
	// The resolver returns only account 1 — account 2's token was unreadable.
	n, err := SeedLedger(context.Background(), database, seedAccountsFn(seedFixture()))
	require.Error(t, err)
	assert.Contains(t, err.Error(), "2")
	assert.Zero(t, n)
}

// TestReactionCmd_SeedPropagatesListerFailure pins that Slack being unreachable
// fails the hook too (and therefore the enable), never a partial seed.
func TestReactionCmd_SeedPropagatesListerFailure(t *testing.T) {
	database := seedTestDB(t, 1)
	accountsFn := func(context.Context) ([]Account, error) {
		return []Account{{AccountID: 1, OwnerID: "1:UOWNER", Lister: failingLister{}}}, nil
	}
	_, err := SeedLedger(context.Background(), database, accountsFn)
	require.Error(t, err)
	assert.Equal(t, 0, countRows(t, database, "reaction_commands"))
}

type failingLister struct{}

func (failingLister) ListUserReactions(context.Context, string) ([]slack.ReactedItem, error) {
	return nil, errors.New("slack unreachable")
}

// TestReactionCmd_SeedNoAccountsIsNoOp pins the degenerate clean exit: no
// connected Slack account means no history to close, not an error.
func TestReactionCmd_SeedNoAccountsIsNoOp(t *testing.T) {
	database := db.OpenTestDB(t)
	n, err := SeedLedger(context.Background(), database, func(context.Context) ([]Account, error) {
		return nil, nil
	})
	require.NoError(t, err)
	assert.Zero(t, n)
	assert.Equal(t, 0, countRows(t, database, "reaction_commands"))
}
