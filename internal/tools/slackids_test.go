package tools

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/slack"
)

// Since migration 00048 every Slack id the DB stores is namespaced
// "<account>:<raw>". These tests pin that the read tools accept either the raw
// form (what an LLM copies out of Slack text or a permalink) or the namespaced
// form (what find_experts and other tools return), and that a raw id present in
// two connected Slack accounts resolves to BOTH accounts' rows.

const (
	rawAlice   = "UALICE001"
	rawBob     = "UBOBBY002"
	rawGeneral = "CGENERAL1"
)

// seedSlackAccounts creates n Slack accounts and returns their ids in order.
func seedSlackAccounts(t *testing.T, d *db.DB, n int) []int64 {
	t.Helper()
	ids := make([]int64, 0, n)
	for i := 0; i < n; i++ {
		id, err := d.CreateSlackAccount(db.SlackAccount{TeamID: "T" + string(rune('A'+i)), TeamName: "acme"})
		require.NoError(t, err)
		ids = append(ids, id)
	}
	return ids
}

// seedAccountSlack seeds, under one account, alice + bob, a #general channel
// and one message by each, with text tagged by the account id.
func seedAccountSlack(t *testing.T, d *db.DB, acct int64, tag string) {
	t.Helper()
	alice, bob, general := slack.Namespace(acct, rawAlice), slack.Namespace(acct, rawBob), slack.Namespace(acct, rawGeneral)
	require.NoError(t, d.UpsertUser(db.User{ID: alice, Name: "alice", RealName: "Alice Smith"}))
	require.NoError(t, d.UpsertUser(db.User{ID: bob, Name: "bob", RealName: "Bob Jones"}))
	require.NoError(t, d.UpsertChannel(db.Channel{ID: general, Name: "general", Type: "public"}))
	require.NoError(t, d.UpsertMessage(db.Message{ChannelID: general, TS: "1700000001.0001", UserID: alice, Text: "alice says " + tag, RawJSON: "{}"}))
	require.NoError(t, d.UpsertMessage(db.Message{ChannelID: general, TS: "1700000002.0001", UserID: bob, Text: "bob says " + tag, RawJSON: "{}"}))
}

func TestListMessages_PersonRawIDMatchesNamespacedRows(t *testing.T) {
	d := openDB(t)
	acct := seedSlackAccounts(t, d, 1)[0]
	seedAccountSlack(t, d, acct, "in-one")

	got := callReadString(t, messagesRegistry(t, d), "list_messages", `{"person":"`+rawAlice+`"}`)
	assert.Contains(t, got, "alice says in-one")
	assert.NotContains(t, got, "bob says")
}

func TestListMessages_PersonNamespacedID(t *testing.T) {
	d := openDB(t)
	acct := seedSlackAccounts(t, d, 1)[0]
	seedAccountSlack(t, d, acct, "in-one")

	got := callReadString(t, messagesRegistry(t, d), "list_messages", `{"person":"`+slack.Namespace(acct, rawAlice)+`"}`)
	assert.Contains(t, got, "alice says in-one")
	assert.NotContains(t, got, "bob says")
}

// A namespaced id pins one account; a raw id present in two accounts returns
// both accounts' messages.
func TestListMessages_PersonRawIDAcrossTwoAccounts(t *testing.T) {
	d := openDB(t)
	accts := seedSlackAccounts(t, d, 2)
	seedAccountSlack(t, d, accts[0], "in-first")
	seedAccountSlack(t, d, accts[1], "in-second")
	reg := messagesRegistry(t, d)

	got := callReadString(t, reg, "list_messages", `{"person":"`+rawAlice+`"}`)
	assert.Contains(t, got, "alice says in-first")
	assert.Contains(t, got, "alice says in-second")
	assert.NotContains(t, got, "bob says")

	got = callReadString(t, reg, "list_messages", `{"person":"`+slack.Namespace(accts[1], rawAlice)+`"}`)
	assert.Contains(t, got, "alice says in-second")
	assert.NotContains(t, got, "in-first")
}

func TestListMessages_ChannelRawAndNamespacedID(t *testing.T) {
	d := openDB(t)
	accts := seedSlackAccounts(t, d, 2)
	seedAccountSlack(t, d, accts[0], "in-first")
	seedAccountSlack(t, d, accts[1], "in-second")
	reg := messagesRegistry(t, d)

	got := callReadString(t, reg, "list_messages", `{"channel":"`+rawGeneral+`"}`)
	assert.Contains(t, got, "in-first")
	assert.Contains(t, got, "in-second")

	got = callReadString(t, reg, "list_messages", `{"channel":"`+slack.Namespace(accts[0], rawGeneral)+`"}`)
	assert.Contains(t, got, "in-first")
	assert.NotContains(t, got, "in-second")
}

func TestListMessages_UnknownChannelIDErrors(t *testing.T) {
	d := openDB(t)
	seedAccountSlack(t, d, seedSlackAccounts(t, d, 1)[0], "x")
	_, err := messagesRegistry(t, d).CallRead(context.Background(), "list_messages", json.RawMessage(`{"channel":"CNOPE0001"}`), Binding{})
	var verr *ValidationError
	require.ErrorAs(t, err, &verr)
	assert.Contains(t, verr.Msg, "no channel matches")
}

func TestListDigests_ChannelRawAndNamespacedID(t *testing.T) {
	d := openDB(t)
	accts := seedSlackAccounts(t, d, 2)
	for i, acct := range accts {
		_, err := d.UpsertDigest(db.Digest{ChannelID: slack.Namespace(acct, rawGeneral), Type: "channel", Summary: []string{"first digest", "second digest"}[i], PeriodFrom: 1, PeriodTo: 2})
		require.NoError(t, err)
	}
	_, err := d.UpsertDigest(db.Digest{ChannelID: slack.Namespace(accts[0], "COTHER001"), Type: "channel", Summary: "other channel digest", PeriodFrom: 1, PeriodTo: 2})
	require.NoError(t, err)
	reg := digestsRegistry(t, d)

	got := callReadString(t, reg, "list_digests", `{"channel":"`+rawGeneral+`"}`)
	assert.Contains(t, got, "first digest")
	assert.Contains(t, got, "second digest")
	assert.NotContains(t, got, "other channel digest")

	got = callReadString(t, reg, "list_digests", `{"channel":"`+slack.Namespace(accts[1], rawGeneral)+`"}`)
	assert.Contains(t, got, "second digest")
	assert.NotContains(t, got, "first digest")
}

func TestGetPerson_RawAndNamespacedID(t *testing.T) {
	d := openDB(t)
	acct := seedSlackAccounts(t, d, 1)[0]
	seedPersonCard(t, d, slack.Namespace(acct, rawAlice), "alice", "Alice Smith", "drives launches")
	reg := peopleRegistry(t, d)

	assert.Contains(t, callReadString(t, reg, "get_person", `{"query":"`+rawAlice+`"}`), "drives launches")
	assert.Contains(t, callReadString(t, reg, "get_person", `{"query":"`+slack.Namespace(acct, rawAlice)+`"}`), "drives launches")
}

// get_person returns one card, so a raw id with a people card in two accounts is an
// ambiguity error naming each namespaced id (the same shape as an ambiguous
// name), while a namespaced id picks one account's card.
func TestGetPerson_RawIDAcrossTwoAccountsIsAmbiguous(t *testing.T) {
	d := openDB(t)
	accts := seedSlackAccounts(t, d, 2)
	seedPersonCard(t, d, slack.Namespace(accts[0], rawAlice), "alice", "Alice Smith", "first card")
	seedPersonCard(t, d, slack.Namespace(accts[1], rawAlice), "alice", "Alice Smith", "second card")
	reg := peopleRegistry(t, d)

	_, err := reg.CallRead(context.Background(), "get_person", json.RawMessage(`{"query":"`+rawAlice+`"}`), Binding{})
	require.Error(t, err)
	assert.Contains(t, err.Error(), slack.Namespace(accts[0], rawAlice))
	assert.Contains(t, err.Error(), slack.Namespace(accts[1], rawAlice))

	assert.Contains(t, callReadString(t, reg, "get_person", `{"query":"`+slack.Namespace(accts[1], rawAlice)+`"}`), "second card")
}

// A disabled or removed Slack account keeps its synced data queryable, so a
// raw id must still resolve to that account's rows.
func TestListMessages_RawIDResolvesDisabledAndRemovedAccounts(t *testing.T) {
	d := openDB(t)
	accts := seedSlackAccounts(t, d, 2)
	seedAccountSlack(t, d, accts[0], "in-disabled")
	seedAccountSlack(t, d, accts[1], "in-removed")
	require.NoError(t, d.SetSlackAccountEnabled(accts[0], false))
	require.NoError(t, d.SetSlackAccountRemoved(accts[1]))

	got := callReadString(t, messagesRegistry(t, d), "list_messages", `{"person":"`+rawAlice+`"}`)
	assert.Contains(t, got, "alice says in-disabled")
	assert.Contains(t, got, "alice says in-removed")
}
