package reactioncmd

import (
	"context"
	"errors"
	"fmt"
	"testing"

	"github.com/slack-go/slack"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// seedFixture is the history an owner has already accumulated before the
// feature is enabled: 6 reactions across 2 channels and 4 emoji, including an
// execute-trust dictionary emoji (bulb -> create_idea, which Propose applies
// INLINE), a non-dictionary one (+1), and an in-THREAD reply — the poll
// dispatches those happily (candidate.ThreadTS exists for them), so a seed that
// skipped them would re-open the replay for every reaction the owner ever
// placed inside a thread. A one- or two-reaction fixture cannot tell "seeded
// the first candidate" from "seeded all of them", which is the other trap this
// fixture exists to avoid.
func seedFixture() []slack.ReactedItem {
	return []slack.ReactedItem{
		msgItem("C1", "111.1", "UAUTHOR", "please handle the deploy", "",
			slack.ItemReaction{Name: "white_check_mark", Users: []string{"UOWNER"}},
			slack.ItemReaction{Name: "+1", Users: []string{"UOWNER"}}),
		msgItem("C1", "222.2", "UAUTHOR", "an idea worth keeping", "",
			slack.ItemReaction{Name: "bulb", Users: []string{"UOWNER"}}),
		msgItem("C1", "666.6", "UAUTHOR", "a reply inside a thread", "111.1",
			slack.ItemReaction{Name: "white_check_mark", Users: []string{"UOWNER"}}),
		msgItem("C2", "333.3", "UAUTHOR", "we should ticket this", "",
			slack.ItemReaction{Name: "ticket", Users: []string{"UOWNER"}}),
		msgItem("C2", "444.4", "UAUTHOR", "someone else's reaction", "",
			slack.ItemReaction{Name: "white_check_mark", Users: []string{"UOWNER"}},
			// Not the owner's: must never be seeded, and must stay dispatchable
			// for the owner if they ever place it themselves.
			slack.ItemReaction{Name: "eyes", Users: []string{"USOMEONE"}}),
		// A file reaction: neither the poll nor the seed can address it (the
		// ledger key is a message key), so it must be skipped by both.
		fileItem("C2", "555.5", slack.ItemReaction{Name: "bulb", Users: []string{"UOWNER"}}),
	}
}

// seedFixtureKeys is the ledger key set seedFixture must produce: every owner
// reaction on a message item, thread replies included, the foreign `eyes` and
// the file item excluded.
func seedFixtureKeys() []string {
	return []string{
		ledgerKey("1:C1", "111.1", "white_check_mark"),
		ledgerKey("1:C1", "111.1", "+1"),
		ledgerKey("1:C1", "222.2", "bulb"),
		ledgerKey("1:C1", "666.6", "white_check_mark"),
		ledgerKey("1:C2", "333.3", "ticket"),
		ledgerKey("1:C2", "444.4", "white_check_mark"),
	}
}

// fileItem is a non-message reacted item (reactions.list returns file and
// file_comment items too).
func fileItem(channel, ts string, reactions ...slack.ItemReaction) slack.ReactedItem {
	return slack.ReactedItem{
		Item:      slack.Item{Type: "file", Channel: channel, Timestamp: ts},
		Reactions: reactions,
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
		insertSlackAccount(t, database, id, 1, "ok")
	}
	return database
}

func insertSlackAccount(t *testing.T, database *db.DB, id int64, enabled int, status string) {
	t.Helper()
	_, err := database.Exec(`INSERT INTO slack_accounts (id, team_id, team_name, current_user_id, enabled, status)
		VALUES (?, ?, ?, ?, ?, ?)`, id, fmt.Sprintf("T%d", id), "team", "1:UOWNER", enabled, status)
	require.NoError(t, err)
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
	assert.Equal(t, 6, n)

	rows := readLedger(t, database)
	assert.ElementsMatch(t, seedFixtureKeys(), ledgerKeys(rows),
		"every owner reaction on a message is seeded — dictionary or not, thread replies included")
	for _, r := range rows {
		assert.Equal(t, "skipped", r.status, "seeded rows are recorded, never dispatched")
		assert.Contains(t, r.detail, "seeded as pre-existing reaction history")
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
	assert.Len(t, readLedger(t, database), 6, "the poll adds no ledger rows of its own")
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
	assert.Equal(t, 7, countRows(t, database, "reaction_commands"), "the seeded rows are not re-written")
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

// TestReactionCmd_SeedCoversEverythingThePollCanDispatch is the equivalence pin
// between the seed's eligibility predicate (ownerReactionKeys) and the poll's
// (extractOwnerReactions) — two hand-written copies of the same prelude in one
// package, the StreamingTranscriber/WindowedTranscriber precedent. The
// invariant is one-directional on purpose: the seed may cover MORE than the
// poll can dispatch (a non-dictionary row is inert), but never less, or the
// uncovered shape replays on the first poll.
func TestReactionCmd_SeedCoversEverythingThePollCanDispatch(t *testing.T) {
	items := seedFixture()
	// Map every emoji present, so extractOwnerReactions yields the widest set it
	// ever could for this fixture — a narrower dictionary would let a narrowed
	// seed pass by accident.
	dict := map[string]db.ReactionCommandMapping{}
	for _, name := range []string{"white_check_mark", "+1", "bulb", "ticket", "eyes"} {
		dict[name] = db.ReactionCommandMapping{Emoji: name, Kind: "builtin_tool", Tool: "create_target", Enabled: true}
	}

	seeded := map[string]bool{}
	for _, r := range ownerReactionKeys(items, "UOWNER", 1) {
		seeded[ledgerKey(r.ChannelID, r.MessageTS, r.Emoji)] = true
	}
	dispatchable := extractOwnerReactions(items, "UOWNER", dict, 1)
	require.NotEmpty(t, dispatchable, "the fixture must actually produce dispatchable candidates")
	for _, c := range dispatchable {
		key := ledgerKey(c.ChannelID, c.MessageTS, c.Emoji)
		assert.True(t, seeded[key], "the poll can dispatch %q but the seed does not record it", key)
	}
}

// TestReactionCmd_SeedIgnoresDisabledAndRemovedAccounts pins which account list
// the fail-closed cross-check reads: only ENABLED, non-removed accounts must be
// required. An owner who disabled or removed an organization must still be able
// to enable the feature — a drift to ListSlackAccounts would lock them out
// permanently, with no other symptom.
func TestReactionCmd_SeedIgnoresDisabledAndRemovedAccounts(t *testing.T) {
	database := seedTestDB(t, 1)
	insertSlackAccount(t, database, 2, 0, "ok")      // soft-disabled
	insertSlackAccount(t, database, 3, 1, "removed") // removed
	insertSlackAccount(t, database, 4, 0, "removed") // both

	n, err := SeedLedger(context.Background(), database, seedAccountsFn(seedFixture()))
	require.NoError(t, err)
	assert.Equal(t, 6, n, "only the enabled account is seeded, and nothing blocks the enable")
	assert.ElementsMatch(t, seedFixtureKeys(), ledgerKeys(readLedger(t, database)))
}

// TestReactionCmd_FirstPollOfUnseededAccountSeedsInsteadOfDispatching pins
// the poll-side half of FEAT-03 that lets the feature default to on: an
// account whose slack_accounts.reaction_commands_seeded_at is empty — an
// existing install that never ran `features enable`, or a Slack account added
// after the enable — is seeded by its FIRST poll (every owner reaction ->
// `skipped`, no AI call, no proposal, no inline idea) and stamped, so the
// history can never replay as commands.
func TestReactionCmd_FirstPollOfUnseededAccountSeedsInsteadOfDispatching(t *testing.T) {
	database := seedTestDB(t, 1) // no seed stamp
	items := seedFixture()
	gen := &mockGenerator{out: `{"essence":"an idea worth keeping","reason":"owner flagged it"}`}
	p := newTestPipeline(t, database, gen, items)

	dispatched, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Zero(t, dispatched)
	assert.Equal(t, 0, gen.calls, "the seeding poll makes no AI call")
	assert.Equal(t, 0, countRows(t, database, "agent_actions"))
	assert.Equal(t, 0, countRows(t, database, "ideas"), "an execute-trust emoji creates nothing")

	rows := readLedger(t, database)
	assert.ElementsMatch(t, seedFixtureKeys(), ledgerKeys(rows), "the whole history is recorded as seen")
	for _, r := range rows {
		assert.Equal(t, "skipped", r.status)
	}
	seeded, err := database.ReactionCommandsSeeded(1)
	require.NoError(t, err)
	assert.True(t, seeded, "the first poll stamps the account")
}

// TestReactionCmd_PollAfterFirstPollSeedDispatchesOnlyNewReactions pins that
// the first-poll seed closes history without deafening the feature: the next
// poll dispatches a reaction placed since, exactly once.
func TestReactionCmd_PollAfterFirstPollSeedDispatchesOnlyNewReactions(t *testing.T) {
	database := seedTestDB(t, 1)
	items := seedFixture()
	gen := &mockGenerator{out: `{"text":"Handle the new deploy","reason":"owner flagged it"}`}
	_, err := newTestPipeline(t, database, gen, items).Run(context.Background())
	require.NoError(t, err)

	fresh := append(append([]slack.ReactedItem{}, items...),
		msgItem("C1", "555.5", "UAUTHOR", "handle the new deploy", "",
			slack.ItemReaction{Name: "white_check_mark", Users: []string{"UOWNER"}}))
	n, err := newTestPipeline(t, database, gen, fresh).Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 1, n, "only the post-seed reaction dispatches")
	assert.Equal(t, 1, gen.calls)
	assert.Equal(t, 1, countRows(t, database, "agent_actions"))
	assert.Equal(t, 7, countRows(t, database, "reaction_commands"))
}

// TestReactionCmd_NeverReactedOwnerKeepsTheirFirstReaction is why the seed is a
// stamp and not "the ledger is empty": an owner with no reaction history at
// all is seeded (with nothing) on the first poll, and their first real
// reaction — arriving on the second poll into a still-empty ledger — must
// dispatch rather than be swallowed as history.
func TestReactionCmd_NeverReactedOwnerKeepsTheirFirstReaction(t *testing.T) {
	database := seedTestDB(t, 1)
	gen := &mockGenerator{out: `{"text":"Handle the deploy","reason":"owner flagged it"}`}
	_, err := newTestPipeline(t, database, gen, nil).Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 0, countRows(t, database, "reaction_commands"), "nothing to seed")

	first := []slack.ReactedItem{msgItem("C1", "111.1", "UAUTHOR", "please handle the deploy", "",
		slack.ItemReaction{Name: "white_check_mark", Users: []string{"UOWNER"}})}
	n, err := newTestPipeline(t, database, gen, first).Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 1, n, "the owner's first-ever reaction is a command, not history")
	assert.Equal(t, 1, gen.calls)
}

// TestReactionCmd_SeedLedgerStampsTheAccount pins that the explicit enable-time
// seed and the first-poll seed share one stamp: after SeedLedger, the poll
// treats the account as seeded and dispatches new reactions straight away.
func TestReactionCmd_SeedLedgerStampsTheAccount(t *testing.T) {
	database := seedTestDB(t, 1)
	_, err := SeedLedger(context.Background(), database, seedAccountsFn(nil))
	require.NoError(t, err)

	seeded, err := database.ReactionCommandsSeeded(1)
	require.NoError(t, err)
	assert.True(t, seeded)
}

// seededPipelineDB is the poll tests' DB: the given Slack accounts exist and
// are already stamped as seeded, so a poll dispatches rather than seeds — the
// steady state every pre-existing pipeline test was written against.
func seededPipelineDB(t *testing.T, accountIDs ...int64) *db.DB {
	t.Helper()
	database := seedTestDB(t, accountIDs...)
	for _, id := range accountIDs {
		require.NoError(t, database.MarkReactionCommandsSeeded(id))
	}
	return database
}

// TestReactionCmd_PartWaySeedFailureLeavesAccountUnstampedAndReseeds pins the
// "stamp is written LAST" claim on the poll path: a ledger write that fails
// part-way through the first-poll seed (injected with a SQLite trigger that
// aborts the third insert) leaves the account unstamped, so the NEXT poll seeds
// the rest (no AI call, no dispatch) instead of treating the account as seeded
// and dispatching the un-recorded remainder of its history. Moving the stamp
// above the insert loop fails this test.
func TestReactionCmd_PartWaySeedFailureLeavesAccountUnstampedAndReseeds(t *testing.T) {
	database := seedTestDB(t, 1)
	items := seedFixture()
	gen := &mockGenerator{out: `{"essence":"an idea worth keeping","reason":"owner flagged it"}`}

	_, err := database.Exec(`CREATE TRIGGER fail_third BEFORE INSERT ON reaction_commands
		WHEN (SELECT COUNT(*) FROM reaction_commands) >= 2
		BEGIN SELECT RAISE(ABORT, 'injected ledger write failure'); END`)
	require.NoError(t, err)

	_, err = newTestPipeline(t, database, gen, items).Run(context.Background())
	require.Error(t, err, "the failed seed is reported")
	assert.Equal(t, 2, countRows(t, database, "reaction_commands"), "the writes before the failure landed")
	seeded, err := database.ReactionCommandsSeeded(1)
	require.NoError(t, err)
	assert.False(t, seeded, "a part-way seed must not stamp the account")

	_, err = database.Exec(`DROP TRIGGER fail_third`)
	require.NoError(t, err)

	dispatched, err := newTestPipeline(t, database, gen, items).Run(context.Background())
	require.NoError(t, err)
	assert.Zero(t, dispatched, "the next poll finishes the seed, it does not dispatch the remainder")
	assert.Equal(t, 0, gen.calls)
	assert.Equal(t, 0, countRows(t, database, "agent_actions"))
	assert.ElementsMatch(t, seedFixtureKeys(), ledgerKeys(readLedger(t, database)))
	seeded, err = database.ReactionCommandsSeeded(1)
	require.NoError(t, err)
	assert.True(t, seeded)
}

// TestReactionCmd_SeedingOneAccountLeavesTheOthersBudgetIntact pins the mixed
// case one Run can meet after a Slack account is added: the unseeded account
// (first by id, so it is processed first) is seeded without touching the
// shared dispatch budget or the returned total, and the already-seeded account
// still dispatches its full cap.
func TestReactionCmd_SeedingOneAccountLeavesTheOthersBudgetIntact(t *testing.T) {
	database := seedTestDB(t, 1, 2)
	require.NoError(t, database.MarkReactionCommandsSeeded(2))
	gen := &mockGenerator{out: `{"text":"Handle this","reason":"owner flagged it"}`}
	p := newCappedTestPipeline(t, database, gen, map[int64][]slack.ReactedItem{
		1: dictionaryReactions("C1", 3), // unseeded: becomes history
		2: dictionaryReactions("C2", maxDispatchPerRun),
	})

	n, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, maxDispatchPerRun, n, "seeding account 1 costs account 2 nothing")
	assert.Equal(t, maxDispatchPerRun, gen.calls)
	var seededRows int
	require.NoError(t, database.QueryRow(`SELECT COUNT(*) FROM reaction_commands WHERE account_id = 1 AND status = 'skipped'`).Scan(&seededRows))
	assert.Equal(t, 3, seededRows)
	seeded, err := database.ReactionCommandsSeeded(1)
	require.NoError(t, err)
	assert.True(t, seeded)
}
