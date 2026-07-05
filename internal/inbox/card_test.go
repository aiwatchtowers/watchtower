package inbox

import (
	"context"
	"fmt"
	"testing"

	"watchtower/internal/db"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestRunCards_GeneratesAndPersists(t *testing.T) {
	d, p, gen := newTriagePipeline(t)
	id := mustCreateInboxItem(t, d, db.InboxItem{ChannelID: "C1", MessageTS: "1.1", SenderUserID: "U2", TriggerType: "mention", Snippet: "need your sign-off"})
	gen.responses = []string{`{"why_matters":"CEO is waiting","thread_digest":"Thread about the Q3 launch sign-off.","draft_reply":"Approved, ship it."}`}

	n, err := p.runCards(context.Background(), "U1")
	if err != nil || n != 1 {
		t.Fatalf("n=%d err=%v", n, err)
	}
	it, _ := d.GetInboxItem(id)
	if it.CardStatus != "ready" || it.DraftReply != "Approved, ship it." {
		t.Fatalf("card not persisted: %+v", it)
	}
}

func TestInbox07_CardFailureMarksFailedAndContinues(t *testing.T) {
	// Two items; first Generate errors, second succeeds.
	// Expect: item1 card_status=failed, item2 ready, err == nil, n == 1.
	d, p, gen := newTriagePipeline(t)
	id1 := mustCreateInboxItem(t, d, db.InboxItem{ChannelID: "C1", MessageTS: "1.1", SenderUserID: "U2", TriggerType: "mention", Snippet: "first item"})
	id2 := mustCreateInboxItem(t, d, db.InboxItem{ChannelID: "C2", MessageTS: "2.1", SenderUserID: "U3", TriggerType: "mention", Snippet: "second item"})
	// ListItemsNeedingCards orders by created_at DESC; both items would
	// otherwise share the same second-precision created_at timestamp, so
	// pin explicit values to make processing order (id1 then id2)
	// deterministic.
	_, err := d.Exec(`UPDATE inbox_items SET created_at = '2026-01-01T00:00:02Z' WHERE id = ?`, id1)
	require.NoError(t, err)
	_, err = d.Exec(`UPDATE inbox_items SET created_at = '2026-01-01T00:00:01Z' WHERE id = ?`, id2)
	require.NoError(t, err)

	gen.responses = []string{"", `{"why_matters":"escalation","thread_digest":"digest","draft_reply":"reply"}`}

	n, err := p.runCards(context.Background(), "U1")
	require.NoError(t, err)
	assert.Equal(t, 1, n)

	it1, err := d.GetInboxItem(id1)
	require.NoError(t, err)
	assert.Equal(t, "failed", it1.CardStatus)

	it2, err := d.GetInboxItem(id2)
	require.NoError(t, err)
	assert.Equal(t, "ready", it2.CardStatus)
}

func TestRunCards_InvalidJSONMarksFailed(t *testing.T) {
	// Response "oops" → card_status=failed, snippet/status untouched.
	d, p, gen := newTriagePipeline(t)
	id := mustCreateInboxItem(t, d, db.InboxItem{ChannelID: "C1", MessageTS: "1.1", SenderUserID: "U2", TriggerType: "mention", Snippet: "original snippet"})
	gen.responses = []string{"oops"}

	n, err := p.runCards(context.Background(), "U1")
	require.NoError(t, err)
	assert.Equal(t, 0, n)

	it, err := d.GetInboxItem(id)
	require.NoError(t, err)
	assert.Equal(t, "failed", it.CardStatus)
	assert.Equal(t, "pending", it.Status)
	assert.Equal(t, "original snippet", it.Snippet)
}

func TestRunCards_AwarenessCapRespected(t *testing.T) {
	// 3 ambient items, cfg.Inbox.MaxAwarenessCards=1 → exactly 1 Generate call.
	d, p, gen := newTriagePipeline(t)
	p.cfg.Inbox.MaxAwarenessCards = 1
	for i := 0; i < 3; i++ {
		mustCreateInboxItem(t, d, db.InboxItem{
			ChannelID:    "C1",
			MessageTS:    fmt.Sprintf("%d.1", i+1),
			SenderUserID: "U2",
			TriggerType:  "stream",
			ItemClass:    "ambient",
			Snippet:      "ambient item",
		})
	}
	gen.responses = []string{`{"why_matters":"w","thread_digest":"d","draft_reply":"r"}`}

	n, err := p.runCards(context.Background(), "U1")
	require.NoError(t, err)
	assert.Equal(t, 1, n)
	assert.Equal(t, 1, gen.calls, "awareness cap must limit AI calls to MaxAwarenessCards")
}
