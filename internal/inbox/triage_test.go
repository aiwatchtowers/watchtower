package inbox

import (
	"context"
	"fmt"
	"log"
	"testing"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// seqGenerator returns queued responses in order; an entry of "" simulates an AI error.
type seqGenerator struct {
	responses []string
	calls     int
	prompts   []string
}

func (g *seqGenerator) Generate(_ context.Context, system, user, _ string) (string, *digest.Usage, string, error) {
	g.prompts = append(g.prompts, system+"\n"+user)
	if g.calls >= len(g.responses) {
		return "", nil, "", fmt.Errorf("unexpected extra call")
	}
	r := g.responses[g.calls]
	g.calls++
	if r == "" {
		return "", nil, "", fmt.Errorf("ai down")
	}
	return r, &digest.Usage{}, "", nil
}

// insertChannel is a local fixture helper (package db has its own private
// copy; this package needs one too).
func insertChannel(t *testing.T, d *db.DB, id, chType string) {
	t.Helper()
	_, err := d.Exec(`INSERT INTO channels (id, name, type) VALUES (?, ?, ?)`, id, id, chType)
	require.NoError(t, err)
}

// insertMessage is a local fixture helper mirroring internal/db's test helper.
func insertMessage(t *testing.T, d *db.DB, channelID, ts, userID, text string) {
	t.Helper()
	_, err := d.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES (?, ?, ?, ?)`, channelID, ts, userID, text)
	require.NoError(t, err)
}

// mustCreateInboxItem is a local fixture helper wrapping CreateInboxItem.
func mustCreateInboxItem(t *testing.T, d *db.DB, it db.InboxItem) int64 {
	t.Helper()
	id, err := d.CreateInboxItem(it)
	require.NoError(t, err)
	return id
}

// newTriagePipeline creates a test DB seeded with a workspace + current user
// "U1", wired to a Pipeline backed by a seqGenerator so tests can queue
// per-call AI responses.
func newTriagePipeline(t *testing.T) (*db.DB, *Pipeline, *seqGenerator) {
	t.Helper()
	d := newTestDB(t)
	seedWorkspaceAndUser(t, d, "U1")
	cfg := testConfig()
	cfg.Inbox.MaxTriageMessages = config.DefaultInboxMaxTriageMessages
	cfg.Inbox.MaxAwarenessCards = config.DefaultInboxMaxAwarenessCards
	gen := &seqGenerator{}
	p := New(d, cfg, gen, log.Default())
	p.SetCurrentUser("U1", "u1@test.com")
	return d, p, gen
}

func TestTriage_StreamCandidateBecomesItem(t *testing.T) {
	d, p, gen := newTriagePipeline(t)
	insertChannel(t, d, "C1", "public")
	insertMessage(t, d, "C1", "100.1", "U2", "prod is on fire, need direction owner")
	gen.responses = []string{`{"verdicts":[{"key":"msg:C1:100.1","tier":"action","priority":"high","reason":"prod incident in your area"}]}`}

	out, err := p.runTriage(context.Background(), "U1", nil, 0)
	if err != nil || out.Created != 1 {
		t.Fatalf("created=%d err=%v", out.Created, err)
	}
	it, _ := d.GetInboxItemByMessage("C1", "100.1")
	if it == nil || it.TriggerType != "stream" || it.ItemClass != "actionable" || it.Priority != "high" {
		t.Fatalf("stream item wrong: %+v", it)
	}
	if it.AIReason != "prod incident in your area" {
		t.Fatalf("ai_reason = %q", it.AIReason)
	}
}

func TestTriage_IgnoreVerdictCreatesNothing(t *testing.T) {
	d, p, gen := newTriagePipeline(t)
	insertChannel(t, d, "C1", "public")
	insertMessage(t, d, "C1", "100.1", "U2", "someone joined the project channel")
	gen.responses = []string{`{"verdicts":[{"key":"msg:C1:100.1","tier":"ignore","priority":"low","reason":"noise"}]}`}

	out, err := p.runTriage(context.Background(), "U1", nil, 0)
	require.NoError(t, err)
	assert.Equal(t, 0, out.Created)

	it, _ := d.GetInboxItemByMessage("C1", "100.1")
	assert.Nil(t, it, "ignored stream candidate must not create an inbox item")
}

func TestInbox01_TriggerNeverIgnored(t *testing.T) {
	// A mention item sent to triage with verdict tier=ignore must remain
	// pending with item_class demoted at most to 'ambient'.
	d, p, gen := newTriagePipeline(t)
	id := mustCreateInboxItem(t, d, db.InboxItem{ChannelID: "C1", MessageTS: "1.1", SenderUserID: "U2", TriggerType: "mention"})
	gen.responses = []string{fmt.Sprintf(`{"verdicts":[{"key":"item:%d","tier":"ignore","priority":"low","reason":"bot noise"}]}`, id)}
	items, err := d.GetInboxItems(db.InboxFilter{Status: "pending"})
	require.NoError(t, err)
	if _, err := p.runTriage(context.Background(), "U1", items, 0); err != nil {
		t.Fatal(err)
	}
	it, err := d.GetInboxItem(id)
	require.NoError(t, err)
	if it.Status != "pending" || it.ItemClass != "ambient" {
		t.Fatalf("trigger item must be demoted, never dropped: %+v", it)
	}
}

func TestInbox01_TriageNeverUpgrades(t *testing.T) {
	// An item already 'ambient' getting tier=action keeps class 'ambient'
	// (priority/reason still update).
	d, p, gen := newTriagePipeline(t)
	id := mustCreateInboxItem(t, d, db.InboxItem{ChannelID: "C1", MessageTS: "1.1", SenderUserID: "U2", TriggerType: "decision_made", ItemClass: "ambient"})
	gen.responses = []string{fmt.Sprintf(`{"verdicts":[{"key":"item:%d","tier":"action","priority":"high","reason":"looks urgent now"}]}`, id)}
	items, err := d.GetInboxItems(db.InboxFilter{Status: "pending"})
	require.NoError(t, err)

	_, err = p.runTriage(context.Background(), "U1", items, 0)
	require.NoError(t, err)

	it, err := d.GetInboxItem(id)
	require.NoError(t, err)
	assert.Equal(t, "ambient", it.ItemClass, "AI must never upgrade ambient to actionable")
	assert.Equal(t, "high", it.Priority, "priority should still update on an ambient item")
	assert.Equal(t, "looks urgent now", it.AIReason)
}

func TestTriage_HardMutedStreamCandidateSkipped(t *testing.T) {
	d, p, gen := newTriagePipeline(t)
	insertChannel(t, d, "C9", "public")
	insertMessage(t, d, "C9", "100.1", "U2", "noise in muted channel")
	require.NoError(t, d.UpsertLearnedRule(db.InboxLearnedRule{RuleType: "source_mute", ScopeKey: "channel:C9", Weight: -1.0, Source: "user_rule"}))

	out, err := p.runTriage(context.Background(), "U1", nil, 0)
	require.NoError(t, err)
	assert.Equal(t, 0, gen.calls, "muted candidate must never reach the generator")
	assert.Equal(t, 0, out.Created)
	// ts "100.1" → ts_unix 100 (generated column truncates at the dot).
	assert.Equal(t, float64(100), out.MaxProcessedTS,
		"a muted-only cycle must still advance the watermark over the muted candidate")
}

func TestTriage_MutedBeyondFailedChunkDoesNotAdvanceWatermark(t *testing.T) {
	// INBOX-09: a muted candidate's ts may advance MaxProcessedTS only if
	// every unmuted stream candidate with a smaller ts was successfully
	// triaged. Here the unmuted ts=10 chunk fails, so the muted ts=20 must
	// not push the watermark past the lost message.
	d, p, gen := newTriagePipeline(t)
	insertChannel(t, d, "C1", "public")
	insertChannel(t, d, "C9", "public")
	insertMessage(t, d, "C1", "10.0", "U2", "important unmuted message")
	insertMessage(t, d, "C9", "20.0", "U2", "noise in muted channel")
	require.NoError(t, d.UpsertLearnedRule(db.InboxLearnedRule{RuleType: "source_mute", ScopeKey: "channel:C9", Weight: -1.0, Source: "user_rule"}))
	gen.responses = []string{""} // the single chunk (containing ts=10) errors

	out, err := p.runTriage(context.Background(), "U1", nil, 0)
	require.Error(t, err)
	assert.Equal(t, float64(0), out.MaxProcessedTS,
		"muted ts=20 must not advance the watermark past the untriaged ts=10 message")
}

func TestTriage_ChunkingAndPartialFailure(t *testing.T) {
	d, p, gen := newTriagePipeline(t)
	insertChannel(t, d, "C1", "public")
	total := maxTriagePerCall + 1
	for i := 1; i <= total; i++ {
		insertMessage(t, d, "C1", fmt.Sprintf("%d.0", i), "U2", "channel chatter")
	}
	// Chunk 1 (150 candidates): all ignored. Chunk 2 (1 candidate): AI error.
	gen.responses = []string{`{"verdicts":[]}`, ""}

	out, err := p.runTriage(context.Background(), "U1", nil, 0)
	require.Error(t, err)
	assert.Equal(t, 2, gen.calls, "both chunks must be attempted")
	assert.Equal(t, 0, out.Created)
	assert.Equal(t, float64(maxTriagePerCall), out.MaxProcessedTS,
		"watermark must freeze at the last message of the last fully-triaged chunk")
}

func TestInbox07_InvalidJSONLeavesStateUntouched(t *testing.T) {
	d, p, gen := newTriagePipeline(t)
	insertChannel(t, d, "C1", "public")
	insertMessage(t, d, "C1", "100.1", "U2", "prod is on fire")
	gen.responses = []string{"not json"}

	out, err := p.runTriage(context.Background(), "U1", nil, 0)
	require.Error(t, err)
	assert.Equal(t, 0, out.Created)
	assert.Equal(t, float64(0), out.MaxProcessedTS, "a failing first chunk must not advance the watermark")

	it, _ := d.GetInboxItemByMessage("C1", "100.1")
	assert.Nil(t, it, "invalid JSON must not create any inbox item")
}
