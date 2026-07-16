package memory

import (
	"context"
	"encoding/json"
	"fmt"
	"reflect"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// createChatTables mirrors the Swift-owned chat tables into a memory-package
// test DB (see the db package's createChatTablesForTest — the same DDL the
// Desktop GRDB ensureTable helpers run). Absent from Go's goose schema, so a
// test that needs owner Discuss turns must create them explicitly.
func createChatTables(t *testing.T, d *db.DB) {
	t.Helper()
	stmts := []string{
		`CREATE TABLE chat_conversations (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			title TEXT NOT NULL DEFAULT '',
			session_id TEXT,
			context_type TEXT,
			context_id TEXT,
			created_at REAL NOT NULL,
			updated_at REAL NOT NULL)`,
		`CREATE TABLE chat_messages (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			conversation_id INTEGER NOT NULL REFERENCES chat_conversations(id) ON DELETE CASCADE,
			role TEXT NOT NULL,
			text TEXT NOT NULL,
			created_at REAL NOT NULL)`,
	}
	for _, s := range stmts {
		_, err := d.Exec(s)
		require.NoError(t, err)
	}
}

func seedChatConversation(t *testing.T, d *db.DB, contextType, contextID string) int64 {
	t.Helper()
	res, err := d.Exec(`INSERT INTO chat_conversations (title, context_type, context_id, created_at, updated_at)
		VALUES ('', ?, ?, 0, 0)`, contextType, contextID)
	require.NoError(t, err)
	id, err := res.LastInsertId()
	require.NoError(t, err)
	return id
}

func seedChatMessage(t *testing.T, d *db.DB, convID int64, role, text string, createdAt float64) int64 {
	t.Helper()
	res, err := d.Exec(`INSERT INTO chat_messages (conversation_id, role, text, created_at)
		VALUES (?, ?, ?, ?)`, convID, role, text, createdAt)
	require.NoError(t, err)
	id, err := res.LastInsertId()
	require.NoError(t, err)
	return id
}

// TestChatEvidenceLineRoundTrips: the canonical evidence line renders and
// parses a chat: channel ref through the existing 4-field grammar without a
// parser change — "- owner for chat:42 1720000000" round-trips as
// {rankOwner, for, chat:42, 1720000000} and weighs at owner rank.
func TestChatEvidenceLineRoundTrips(t *testing.T) {
	e := beliefEvidence{Rank: rankOwner, Support: true, ChannelID: "chat:42", TS: "1720000000"}
	line := e.render()
	assert.Equal(t, "- owner for chat:42 1720000000\n", line)

	ev := parseBeliefEvidence("# B\n\n## Evidence\n"+line, t.Logf)
	require.Len(t, ev, 1, "the chat line parses as one canonical evidence line")
	assert.Equal(t, rankOwner, ev[0].Rank)
	assert.True(t, ev[0].Support)
	assert.Equal(t, "chat:42", ev[0].ChannelID)
	assert.Equal(t, "1720000000", ev[0].TS)

	w := ev[0].weigh(beliefNow)
	assert.Equal(t, rankOwner, w.Rank, "a chat owner line weighs at owner rank")
}

// TestValidateChatRefsOwnerTurn: a chat: ref resolving to a role='user'
// situation turn survives validation and is minted at owner rank; the support
// direction follows the op.
func TestValidateChatRefsOwnerTurn(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	createChatTables(t, d)
	conv := seedChatConversation(t, d, "situation", "7")
	seedChatMessage(t, d, conv, "user", "alice is unreliable", 1720000000.0)
	p := NewPipeline(d, v, &fakeGen{}, pipelineTestConfig(), t.Logf)

	refs := []episodeRef{{ChannelID: fmt.Sprintf("chat:%d", conv), TS: "1720000000"}}
	kept, dropped := p.validateChatRefs(refs)
	require.Len(t, kept, 1, "an owner turn resolves")
	assert.Zero(t, dropped)

	ev := newEvidenceLines(kept, opRetire)
	require.Len(t, ev, 1)
	assert.Equal(t, rankOwner, ev[0].Rank, "MEM-09: code elevates a validated chat ref to owner rank")
	assert.False(t, ev[0].Support, "a retire op weighs the evidence against the belief")
}

// TestValidateChatRefsDropsNonOwner: an assistant turn, a wrong ts, and a
// non-situation conversation all fail the owner check and are dropped+counted
// like a hallucinated ref.
func TestValidateChatRefsDropsNonOwner(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	createChatTables(t, d)
	conv := seedChatConversation(t, d, "situation", "7")
	other := seedChatConversation(t, d, "track", "9")
	seedChatMessage(t, d, conv, "assistant", "secretary said", 1720000000.0)
	seedChatMessage(t, d, other, "user", "in a track chat", 1720000100.0)
	p := NewPipeline(d, v, &fakeGen{}, pipelineTestConfig(), t.Logf)

	refs := []episodeRef{
		{ChannelID: fmt.Sprintf("chat:%d", conv), TS: "1720000000"},  // assistant, not owner
		{ChannelID: fmt.Sprintf("chat:%d", conv), TS: "9999999999"},  // wrong ts
		{ChannelID: fmt.Sprintf("chat:%d", other), TS: "1720000100"}, // non-situation conversation
		{ChannelID: "chat:999", TS: "1720000000"},                    // unknown conversation
	}
	kept, dropped := p.validateChatRefs(refs)
	assert.Empty(t, kept, "no non-owner chat ref survives")
	assert.Equal(t, 4, dropped)
}

// TestValidateChatRefsTablesAbsent: with the Swift chat tables absent (headless
// daemon), a chat: ref is dropped-and-counted, never an error that fails the
// pass.
func TestValidateChatRefsTablesAbsent(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t) // no chat tables
	p := NewPipeline(d, v, &fakeGen{}, pipelineTestConfig(), t.Logf)

	refs := []episodeRef{{ChannelID: "chat:42", TS: "1720000000"}}
	kept, dropped := p.validateChatRefs(refs)
	assert.Empty(t, kept, "absent tables → chat ref unresolved")
	assert.Equal(t, 1, dropped)
}

// TestValidateChatRefsEpisodeUntouched: an episode ref passes validateChatRefs
// unchanged and is minted at observed rank — only chat: refs become owner rank.
func TestValidateChatRefsEpisodeUntouched(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	p := NewPipeline(d, v, &fakeGen{}, pipelineTestConfig(), t.Logf)

	refs := []episodeRef{{ChannelID: "C1CHAN", TS: "100.000100"}}
	kept, dropped := p.validateChatRefs(refs)
	require.Len(t, kept, 1)
	assert.Zero(t, dropped, "an episode ref needs no chat validation and is never dropped here")

	ev := newEvidenceLines(kept, opConfirm)
	require.Len(t, ev, 1)
	assert.Equal(t, rankObserved, ev[0].Rank, "episode refs stay observed rank")
	assert.True(t, ev[0].Support)
}

// TestMemory09_OwnerRankOnlyFromAuthoredTurns is the MEM-09 formal guard: owner
// rank is authored by code from role='user' Discuss turns only — never from
// model output. The model op JSON carries no rank field, a chat ref absent from
// the belief pass's input is dropped as invented (never owner-minted), and a
// chat ref that resolves to a non-owner turn is dropped.
func TestMemory09_OwnerRankOnlyFromAuthoredTurns(t *testing.T) {
	t.Run("belief-op JSON schema carries no rank field", func(t *testing.T) {
		// The model never names a rank: beliefOpJSON has no rank field, so a
		// model-supplied "rank":"owner" cannot deserialize into anything the
		// applier reads. Rank is minted exclusively by newEvidenceLines.
		typ := reflect.TypeOf(beliefOpJSON{})
		for i := 0; i < typ.NumField(); i++ {
			assert.NotEqual(t, "rank", typ.Field(i).Tag.Get("json"),
				"beliefOpJSON must not carry a model-settable rank field")
		}
		raw := `{"op":"confirm","belief_id":"b","rank":"owner","evidence":[]}`
		var op beliefOpJSON
		require.NoError(t, json.Unmarshal([]byte(raw), &op))
		// A JSON round-trip of the parsed op contains no "rank" key.
		out, err := json.Marshal(op)
		require.NoError(t, err)
		assert.NotContains(t, string(out), `"rank"`, "a model-supplied rank is discarded on parse")
	})

	t.Run("episode ref never becomes owner rank", func(t *testing.T) {
		ev := newEvidenceLines([]episodeRef{{ChannelID: "C1CHAN", TS: "100"}}, opConfirm)
		require.Len(t, ev, 1)
		assert.Equal(t, rankObserved, ev[0].Rank)
	})

	t.Run("chat ref absent from the belief-pass input is dropped as invented", func(t *testing.T) {
		v, d := newTestVault(t), newTestDB(t)
		createChatTables(t, d)
		conv := seedChatConversation(t, d, "situation", "7")
		seedChatMessage(t, d, conv, "user", "alice is unreliable", 1720000000.0)
		subjectID := "ent_00000000000000000000000001"
		epID := "ep_00000000000000000000000001"
		tsRef := fmt.Sprintf("%d.000100", beliefNow.AddDate(0, 0, -5).Unix())
		writeAndIndex(t, v, d, rewriteEpisodeNode(epID, "C1CHAN", tsRef))
		writeAndIndex(t, v, d, beliefSubjectEntity(subjectID, epID))
		bel := beliefTestNode("bel_00000000000000000000000001", "Alice is reliable", subjectID, 0.5, 0, "active")
		writeAndIndex(t, v, d, bel)
		p := NewPipeline(d, v, &fakeGen{}, pipelineTestConfig(), t.Logf)

		// The model cites the real owner turn, but it was NOT staged into the
		// belief pass input (p.chat is nil), so validateMarkers drops it before
		// any owner minting can happen — DB existence alone never mints owner rank.
		candidates := map[string]Node{bel.ID: bel}
		inputSet := map[string]bool{} // nothing staged
		op := beliefOpJSON{BeliefID: bel.ID, Op: "retire",
			Evidence: []episodeRef{{ChannelID: fmt.Sprintf("chat:%d", conv), TS: "1720000000"}}}
		_, applied, mathRejected := p.applyBeliefOp(op, candidates, inputSet, beliefNow)
		assert.False(t, applied, "an unstaged chat ref is invented evidence — the op is a no-op")
		assert.False(t, mathRejected)
	})

	t.Run("chat ref resolving to a non-owner turn is dropped", func(t *testing.T) {
		v, d := newTestVault(t), newTestDB(t)
		createChatTables(t, d)
		conv := seedChatConversation(t, d, "situation", "7")
		seedChatMessage(t, d, conv, "assistant", "secretary said", 1720000000.0)
		p := NewPipeline(d, v, &fakeGen{}, pipelineTestConfig(), t.Logf)

		ref := episodeRef{ChannelID: fmt.Sprintf("chat:%d", conv), TS: "1720000000"}
		// Even staged (in the input set), an assistant turn fails the owner check.
		inputSet := map[string]bool{ref.ChannelID + " " + ref.TS: true}
		kept, dropped := validateMarkers(inputSet, []episodeRef{ref})
		require.Len(t, kept, 1, "the ref is in the model's input")
		assert.Zero(t, dropped)
		kept2, chatDropped := p.validateChatRefs(kept)
		assert.Empty(t, kept2, "an assistant turn is never owner rank (MEM-09)")
		assert.Equal(t, 1, chatDropped)
	})
}

// TestReviseBeliefsOwnerChatRetires drives the full belief pass: a staged owner
// chat turn cited by the model as retire evidence is minted owner-against and
// retires an unprotected belief per the rank math.
func TestReviseBeliefsOwnerChatRetires(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	createChatTables(t, d)
	conv := seedChatConversation(t, d, "situation", "7")
	seedChatMessage(t, d, conv, "user", "alice keeps missing deadlines", 1720000000.0)

	subjectID := "ent_00000000000000000000000001"
	epID := "ep_00000000000000000000000001"
	tsRef := fmt.Sprintf("%d.000100", beliefNow.AddDate(0, 0, -5).Unix())
	writeAndIndex(t, v, d, rewriteEpisodeNode(epID, "C1CHAN", tsRef))
	writeAndIndex(t, v, d, beliefSubjectEntity(subjectID, epID))
	bel := beliefTestNode("bel_00000000000000000000000001", "Alice is reliable", subjectID, 0.5, 0, "active")
	writeAndIndex(t, v, d, bel)

	chatRef := fmt.Sprintf("chat:%d", conv)
	gen := &fakeGen{reply: func(string) (string, error) {
		return opsJSON(t, beliefOpJSON{BeliefID: bel.ID, Op: "retire",
			Evidence: []episodeRef{{ChannelID: chatRef, TS: "1720000000"}}, Rationale: "owner says so"}), nil
	}}
	p := NewPipeline(d, v, gen, pipelineTestConfig(), t.Logf)
	// Stage the owner turn exactly as ingestChatStatements would.
	p.chat = &stagedChat{
		statements: []ownerStatement{{conversationID: conv, turnTS: 1720000000, text: "alice keeps missing deadlines", subjects: []string{subjectID}}},
		refs:       map[string]bool{chatRef + " 1720000000": true},
		subjects:   map[string]bool{subjectID: true},
	}

	touched, _, _, err := p.ReviseBeliefs(context.Background(), nil, 20, beliefNow)
	require.NoError(t, err)
	require.Equal(t, 1, touched, "the owner chat op applied")

	got, err := v.ReadNode(bel.ID)
	require.NoError(t, err)
	assert.Equal(t, statusRetired, got.Status, "owner-against evidence with no owner support retires the belief")
	assert.Contains(t, got.Body, "- owner against "+chatRef+" 1720000000", "the owner-rank chat evidence line is written")
}
