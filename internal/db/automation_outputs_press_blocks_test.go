package db

import (
	"encoding/json"
	"errors"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// blocksWithRowReply is a stored document whose list row carries a Link and
// a Reply, followed by an actions block with one Reply: with one card action
// the flattened list is [card link, row link, row reply, block reply].
const blocksWithRowReply = `{"v":1,"blocks":[` +
	`{"type":"heading","text":"Bugs","level":2},` +
	`{"type":"table","columns":[{"title":"A","align":"left"}],"rows":[[{"text":"x"}]]},` +
	`{"type":"list","rows":[{"title":"A-1","actions":[` +
	`{"label":"Open","kind":"link","open":"https://example.com/a-1"},` +
	`{"label":"Backlog","kind":"reply","reply":"backlog","data":{"row":1}}]}],"empty":""},` +
	`{"type":"actions","actions":[{"label":"All later","kind":"reply","reply":"later"}]}]}`

const cardLinkJSON = `[{"label":"Board","kind":"link","open":"https://example.com/board","primary":true}]`

// seedBlocksCard is seedInboxCard with a block document and a content hash.
func seedBlocksCard(t *testing.T, d *DB, a int64, actions, blocks, hash string) int64 {
	t.Helper()
	out := seedInboxCard(t, d, a, "Bugs", "", actions)
	_, err := d.Exec(`UPDATE automation_outputs SET blocks_json = ?, content_hash = ? WHERE id = ?`, blocks, hash, out)
	require.NoError(t, err)
	return out
}

func replyPayloadOf(t *testing.T, d *DB, runID int64) ReplyTrigger {
	t.Helper()
	var p ReplyPayload
	require.NoError(t, json.Unmarshal([]byte(mustGetAutomationRun(t, d, runID).EventJSON), &p))
	return p.Reply
}

func TestFlattenStoredInboxActions_Order(t *testing.T) {
	card, err := decodeInboxActions(cardLinkJSON)
	require.NoError(t, err)
	got, err := FlattenStoredInboxActions(card, blocksWithRowReply)
	require.NoError(t, err)
	labels := make([]string, len(got))
	for i, a := range got {
		labels[i] = a.Label
	}
	assert.Equal(t, []string{"Board", "Open", "Backlog", "All later"}, labels)

	none, err := FlattenStoredInboxActions(nil, "")
	require.NoError(t, err)
	assert.NotNil(t, none, "never nil")
	assert.Empty(t, none)

	for name, doc := range map[string]string{
		"not JSON":   `{`,
		"no version": `{"blocks":[]}`,
		"version 2":  `{"v":2,"blocks":[]}`,
		"bad rows":   `{"v":1,"blocks":[{"type":"list","rows":{}}]}`,
	} {
		_, err := FlattenStoredInboxActions(card, doc)
		assert.Error(t, err, name)
	}
}

func TestPressInboxOutputAction_ReplyInListRowByFlattenedIndex(t *testing.T) {
	d := openTestDB(t)
	a := seedRunnableAutomation(t, d, "triage")
	out := seedBlocksCard(t, d, a, cardLinkJSON, blocksWithRowReply, "h1")

	runID, err := d.PressInboxOutputAction(out, 2, "h1", runTestNow)
	require.NoError(t, err)
	wantAutomationRun(t, d, runID, RunQueued, "")
	got := replyPayloadOf(t, d, runID)
	assert.Equal(t, 2, got.Action)
	assert.Equal(t, "backlog", got.Value)
	assert.JSONEq(t, `{"row":1}`, string(got.Data))
	assert.Equal(t, "h1", got.ContentHash, "the payload carries the hash the press was checked against")
	p := readPress(t, d, out)
	require.NotNil(t, p.action)
	assert.EqualValues(t, 2, *p.action)
	assert.Equal(t, 1, countReplyRuns(t, d))
}

func TestPressInboxOutputAction_FlattenedIndexRefusals(t *testing.T) {
	d := openTestDB(t)
	a := seedRunnableAutomation(t, d, "triage")
	out := seedBlocksCard(t, d, a, cardLinkJSON, blocksWithRowReply, "h1")
	for _, i := range []int{0, 1} { // the card's link, the row's link
		_, err := d.PressInboxOutputAction(out, i, "h1", runTestNow)
		wantErrIs(t, "a link action", err, ErrNotAReplyAction)
	}
	_, err := d.PressInboxOutputAction(out, 4, "h1", runTestNow)
	wantErrIs(t, "an index past the flattened list", err, ErrNotAReplyAction)

	broken := seedBlocksCard(t, d, a, cardLinkJSON, `{"v":2,"blocks":[]}`, "h2")
	_, err = d.PressInboxOutputAction(broken, 0, "", runTestNow)
	require.Error(t, err, "an unreadable document refuses the press")
	assert.Equal(t, 0, countReplyRuns(t, d))
}

func TestPressInboxOutputAction_ContentHash(t *testing.T) {
	d := openTestDB(t)
	a := seedRunnableAutomation(t, d, "triage")
	out := seedBlocksCard(t, d, a, cardLinkJSON, blocksWithRowReply, "h1")

	_, err := d.PressInboxOutputAction(out, 3, "h0", runTestNow)
	wantErrIs(t, "a stale hash", err, ErrOutputChanged)
	assert.Equal(t, "inbox card "+jsonInt(out)+": This card changed — look again", err.Error())
	assert.Equal(t, 0, countReplyRuns(t, d), "nothing queued")
	p := readPress(t, d, out)
	assert.Nil(t, p.at, "no press recorded")

	// The changed check comes before closed: a stale view says look again.
	_, err = d.Exec(`UPDATE automation_outputs SET done_at = ? WHERE id = ?`, formatAutomationTime(runTestNow), out)
	require.NoError(t, err)
	_, err = d.PressInboxOutputAction(out, 3, "h0", runTestNow)
	wantErrIs(t, "a stale hash on a done card", err, ErrOutputChanged)
	_, err = d.Exec(`UPDATE automation_outputs SET done_at = NULL WHERE id = ?`, out)
	require.NoError(t, err)

	runID, err := d.PressInboxOutputAction(out, 3, "h1", runTestNow)
	require.NoError(t, err, "a matching hash queues")
	assert.Equal(t, "later", replyPayloadOf(t, d, runID).Value)

	_, err = d.PressInboxOutputAction(out, 2, "h1", runTestNow.Add(time.Second))
	var already *AlreadyPressedError
	require.True(t, errors.As(err, &already), "second press = %v", err)
	assert.Equal(t, runID, already.RunID)
}

func TestPressInboxOutputAction_NoHashOnACardWithoutOne(t *testing.T) {
	d := openTestDB(t)
	a := seedRunnableAutomation(t, d, "triage")
	out := seedInboxCard(t, d, a, "Bug", "", replyActionsJSON)
	runID, err := d.PressInboxOutputAction(out, 0, "", runTestNow)
	require.NoError(t, err)
	var raw map[string]map[string]json.RawMessage
	require.NoError(t, json.Unmarshal([]byte(mustGetAutomationRun(t, d, runID).EventJSON), &raw))
	_, has := raw["reply"]["content_hash"]
	assert.False(t, has, "a card without a hash writes no content_hash key")
}

func TestPressInboxOutputAction_NoFlagWritesTheRowHash(t *testing.T) {
	d := openTestDB(t)
	a := seedRunnableAutomation(t, d, "triage")
	out := seedBlocksCard(t, d, a, cardLinkJSON, blocksWithRowReply, "h1")
	runID, err := d.PressInboxOutputAction(out, 3, "", runTestNow)
	require.NoError(t, err)
	assert.Equal(t, "h1", replyPayloadOf(t, d, runID).ContentHash)
}

func TestPressInboxOutputAction_ChangedLivingRewriteIsPressableAgain(t *testing.T) {
	d := openTestDB(t)
	a := seedRunnableAutomation(t, d, "triage")
	actions := []InboxAction{{Label: "Later", Kind: InboxActionReply, Reply: "later"}}
	v1 := livingOut("bugs", "Bugs", "h1")
	v1.Actions = actions
	runOnce(t, d, a, runTestNow, &RunCommit{Outputs: []AutomationOutput{v1}})
	out := outputByKey(t, d, a, "bugs").ID

	first, err := d.PressInboxOutputAction(out, 0, "h1", runTestNow.Add(time.Minute))
	require.NoError(t, err)
	// Finish the queued reply run so the next run can take the slot.
	require.True(t, mustClaimAutomationRun(t, d, first))
	mustFinishAutomationRun(t, d, first, RunFinish{Status: RunSucceeded, Now: runTestNow.Add(2 * time.Minute)}, nil)

	v2 := livingOut("bugs", "Bugs v2", "h2")
	v2.Actions = actions
	runOnce(t, d, a, runTestNow.Add(time.Hour), &RunCommit{Outputs: []AutomationOutput{v2}})

	_, err = d.PressInboxOutputAction(out, 0, "h1", runTestNow.Add(2*time.Hour))
	wantErrIs(t, "the old version's hash", err, ErrOutputChanged)
	second, err := d.PressInboxOutputAction(out, 0, "h2", runTestNow.Add(2*time.Hour))
	require.NoError(t, err, "a changed rewrite cleared the press")
	assert.NotEqual(t, first, second)
	assert.Equal(t, "h2", replyPayloadOf(t, d, second).ContentHash)
}
