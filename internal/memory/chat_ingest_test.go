package memory

import (
	"context"
	"fmt"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
)

// chatIngestConfig is a semantic-enabled config with the chat surface on. The
// non-chat strong step (rewrite) is neutralized in these tests by giving the
// subject entity no linked episodes, so the belief pass is the only AI call.
func chatIngestConfig() config.MemoryConfig {
	cfg := pipelineTestConfig()
	cfg.Semantic.Enabled = true
	cfg.Surfaces.Chat = true
	return cfg
}

// bareEntity is an entity page with NO linked episodes (empty ## Links), so
// RewriteEntityPages skips it — the belief pass is then the run's only AI call.
func bareEntity(id, alias string) Node {
	body := "# " + alias + "\n\n## What\nx\n\n## Current\n\n## Facts\n\n## Links\n\n## Open loops\n"
	return Node{ID: id, Type: "entity", Tier: "long", Status: "active", Title: alias, Aliases: []string{alias}, Body: body}
}

// seedSituationForChannel creates a situation with one signal in channelID
// (member userID), returning the situation id — the join target for
// situationSubjects (channel/member → entity via memory_aliases).
func seedSituationForChannel(t *testing.T, d *db.DB, channelID, userID string) int {
	t.Helper()
	sigID, err := d.CreateInboxItem(db.InboxItem{ChannelID: channelID, MessageTS: "1.1", SenderUserID: userID, TriggerType: "stream"})
	require.NoError(t, err)
	sitID, err := d.CreateSituation(db.DashboardSituation{Title: "situation", Kind: "external", Priority: "medium", Rank: 0.5, AIReason: "x"})
	require.NoError(t, err)
	require.NoError(t, d.AddSituationSignals(int(sitID), []int{int(sigID)}))
	return int(sitID)
}

// TestIngestChatStatementsStages: a role='user' turn in a situation whose
// channel aliases an entity is staged as an owner statement with that entity as
// subject; assistant turns are ignored; the floor advances to the max scanned id.
func TestIngestChatStatementsStages(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	createChatTables(t, d)
	seedWorkspaceRow(t, d)
	entID := "ent_00000000000000000000000001"
	writeAndIndex(t, v, d, bareEntity(entID, "C1GEN"))
	sitID := seedSituationForChannel(t, d, "C1GEN", "U2BOB")

	conv := seedChatConversation(t, d, "situation", fmt.Sprintf("%d", sitID))
	seedChatMessage(t, d, conv, "assistant", "secretary reply", 1720000000.0)
	uID := seedChatMessage(t, d, conv, "user", "alice keeps  missing   deadlines", 1720000100.0)

	p := NewPipeline(d, v, &fakeGen{}, chatIngestConfig(), t.Logf)
	staged, newFloor, err := p.ingestChatStatements(0)
	require.NoError(t, err)
	require.NotNil(t, staged)
	require.Len(t, staged.statements, 1, "only the role='user' turn is staged")
	st := staged.statements[0]
	assert.Equal(t, conv, st.conversationID)
	assert.Equal(t, int64(1720000100), st.turnTS)
	assert.Equal(t, "alice keeps missing deadlines", st.text, "text is whitespace-normalized verbatim")
	assert.Equal(t, []string{entID}, st.subjects, "the situation channel resolves to its entity")
	assert.True(t, staged.refs[fmt.Sprintf("chat:%d 1720000100", conv)], "the chat ref is in the staged set")
	assert.True(t, staged.subjects[entID])
	assert.Equal(t, uID, newFloor, "floor advances to the max scanned chat_messages.id")
}

// TestIngestChatStatementsAbsentTablesNoop: with the Swift chat tables absent,
// ingest is a clean no-op — nil staged, floor unchanged.
func TestIngestChatStatementsAbsentTablesNoop(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t) // no chat tables
	p := NewPipeline(d, v, &fakeGen{}, chatIngestConfig(), t.Logf)

	staged, newFloor, err := p.ingestChatStatements(5)
	require.NoError(t, err)
	assert.Nil(t, staged)
	assert.Equal(t, int64(5), newFloor, "floor unchanged when there is nothing to scan")
}

// TestIngestChatStatementsBelowFloorSkipped: a turn at or below the floor is not
// re-scanned; a turn whose situation maps to no entity still advances the floor
// but stages nothing.
func TestIngestChatStatementsBelowFloorSkipped(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	createChatTables(t, d)
	seedWorkspaceRow(t, d)
	// A situation whose channel resolves to NO entity (no entity aliased C9UNK).
	sitID := seedSituationForChannel(t, d, "C9UNK", "U9UNK")
	conv := seedChatConversation(t, d, "situation", fmt.Sprintf("%d", sitID))
	below := seedChatMessage(t, d, conv, "user", "old turn", 1720000000.0)
	above := seedChatMessage(t, d, conv, "user", "new turn", 1720000100.0)

	p := NewPipeline(d, v, &fakeGen{}, chatIngestConfig(), t.Logf)
	staged, newFloor, err := p.ingestChatStatements(below)
	require.NoError(t, err)
	assert.Nil(t, staged, "the situation maps to no entity — nothing staged")
	assert.Equal(t, above, newFloor, "the above-floor turn is still consumed (floor advances past it)")
}

// TestRunSemanticChatOwnerEvidence is the end-to-end Task-4 contract: an owner
// Discuss turn contradicting a belief whose subject aliases the situation's
// channel lands as an owner-against evidence line after the belief pass, the
// belief updates per rank math, and the chat-turn floor advances.
func TestRunSemanticChatOwnerEvidence(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	createChatTables(t, d)
	seedWorkspaceRow(t, d)
	entID := "ent_00000000000000000000000001"
	writeAndIndex(t, v, d, bareEntity(entID, "C1GEN"))
	bel := beliefTestNode("bel_00000000000000000000000001", "Alice is reliable", entID, 0.5, 0, "active")
	writeAndIndex(t, v, d, bel)
	sitID := seedSituationForChannel(t, d, "C1GEN", "U2BOB")
	conv := seedChatConversation(t, d, "situation", fmt.Sprintf("%d", sitID))
	turnID := seedChatMessage(t, d, conv, "user", "alice keeps missing deadlines", 1720000000.0)

	chatRef := fmt.Sprintf("chat:%d", conv)
	gen := &fakeGen{reply: func(string) (string, error) {
		return opsJSON(t, beliefOpJSON{BeliefID: bel.ID, Op: "retire",
			Evidence: []episodeRef{{ChannelID: chatRef, TS: "1720000000"}}, Rationale: "owner says so"}), nil
	}}
	p := NewPipeline(d, v, gen, chatIngestConfig(), t.Logf)

	// Snapshot the inbox/situation state for the MEM-05 read-only check.
	before := dumpInboxSituationState(t, d)

	var stats RunStats
	p.runSemantic(context.Background(), 0, 0, &usageAccumulator{}, &stats)
	assert.Equal(t, 1, stats.ChatTurnsIngested)

	got, err := v.ReadNode(bel.ID)
	require.NoError(t, err)
	assert.Equal(t, statusRetired, got.Status, "owner-against chat evidence retires the belief per rank math")
	assert.Contains(t, got.Body, "- owner against "+chatRef+" 1720000000")

	floor, err := d.MemoryChatTurnFloor()
	require.NoError(t, err)
	assert.Equal(t, turnID, floor, "the floor advances after the belief pass commits")

	assert.Equal(t, before, dumpInboxSituationState(t, d), "MEM-05: memory never mutates inbox/situation tables")
}

// TestRunSemanticChatFloorHeldOnBeliefError: a belief-pass failure leaves the
// chat-turn floor unmoved so the same owner turns are re-staged next run.
func TestRunSemanticChatFloorHeldOnBeliefError(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	createChatTables(t, d)
	seedWorkspaceRow(t, d)
	entID := "ent_00000000000000000000000001"
	writeAndIndex(t, v, d, bareEntity(entID, "C1GEN"))
	bel := beliefTestNode("bel_00000000000000000000000001", "Alice is reliable", entID, 0.5, 0, "active")
	writeAndIndex(t, v, d, bel)
	sitID := seedSituationForChannel(t, d, "C1GEN", "U2BOB")
	conv := seedChatConversation(t, d, "situation", fmt.Sprintf("%d", sitID))
	seedChatMessage(t, d, conv, "user", "alice keeps missing deadlines", 1720000000.0)

	// The model returns unparseable JSON → ReviseBeliefs errors.
	gen := &fakeGen{reply: func(string) (string, error) { return "not json", nil }}
	p := NewPipeline(d, v, gen, chatIngestConfig(), t.Logf)

	var stats RunStats
	p.runSemantic(context.Background(), 0, 0, &usageAccumulator{}, &stats)

	floor, err := d.MemoryChatTurnFloor()
	require.NoError(t, err)
	assert.Equal(t, int64(0), floor, "a belief-pass error must not advance the chat-turn floor")

	got, err := v.ReadNode(bel.ID)
	require.NoError(t, err)
	assert.Equal(t, "active", got.Status, "the belief is untouched when the pass failed")
}

// TestRunSemanticChatGateOffNoop: with memory.surfaces.chat off, owner turns are
// never scanned even when the tables are populated — the floor stays and no
// chat evidence reaches the belief pass.
func TestRunSemanticChatGateOffNoop(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	createChatTables(t, d)
	seedWorkspaceRow(t, d)
	entID := "ent_00000000000000000000000001"
	writeAndIndex(t, v, d, bareEntity(entID, "C1GEN"))
	bel := beliefTestNode("bel_00000000000000000000000001", "Alice is reliable", entID, 0.5, 0, "active")
	writeAndIndex(t, v, d, bel)
	sitID := seedSituationForChannel(t, d, "C1GEN", "U2BOB")
	conv := seedChatConversation(t, d, "situation", fmt.Sprintf("%d", sitID))
	seedChatMessage(t, d, conv, "user", "alice keeps missing deadlines", 1720000000.0)

	cfg := chatIngestConfig()
	cfg.Surfaces.Chat = false
	// If the belief pass were somehow called on this belief it would need the
	// gen; return a no-op empty ops so a stray call cannot mutate anything.
	gen := &fakeGen{reply: func(string) (string, error) { return `{"ops":[]}`, nil }}
	p := NewPipeline(d, v, gen, cfg, t.Logf)

	var stats RunStats
	p.runSemantic(context.Background(), 0, 0, &usageAccumulator{}, &stats)
	assert.Zero(t, stats.ChatTurnsIngested, "gate off → nothing ingested")

	floor, err := d.MemoryChatTurnFloor()
	require.NoError(t, err)
	assert.Equal(t, int64(0), floor, "gate off → floor untouched")

	got, err := v.ReadNode(bel.ID)
	require.NoError(t, err)
	assert.Equal(t, "active", got.Status, "gate off → belief untouched")
}

// TestReviseBeliefsModelCannotMintUnstagedOwnerRank: even when a role='user'
// turn exists in the DB, a model op citing it is a no-op unless the turn was
// STAGED into the belief pass input (p.chat) — DB existence alone never mints
// owner rank (MEM-09 defense in depth).
func TestReviseBeliefsModelCannotMintUnstagedOwnerRank(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	createChatTables(t, d)
	entID := "ent_00000000000000000000000001"
	epID := "ep_00000000000000000000000001"
	tsRef := fmt.Sprintf("%d.000100", beliefNow.AddDate(0, 0, -5).Unix())
	writeAndIndex(t, v, d, rewriteEpisodeNode(epID, "C1CHAN", tsRef))
	writeAndIndex(t, v, d, beliefSubjectEntity(entID, epID))
	bel := beliefTestNode("bel_00000000000000000000000001", "Alice is reliable", entID, 0.5, 0, "active")
	writeAndIndex(t, v, d, bel)
	conv := seedChatConversation(t, d, "situation", "7")
	seedChatMessage(t, d, conv, "user", "alice is unreliable", 1720000000.0)

	chatRef := fmt.Sprintf("chat:%d", conv)
	gen := &fakeGen{reply: func(string) (string, error) {
		return opsJSON(t, beliefOpJSON{BeliefID: bel.ID, Op: "retire",
			Evidence: []episodeRef{{ChannelID: chatRef, TS: "1720000000"}}, Rationale: "unstaged"}), nil
	}}
	p := NewPipeline(d, v, gen, pipelineTestConfig(), t.Logf)
	// p.chat is nil — nothing was staged, so the cited ref is invented input.

	touched, _, _, err := p.ReviseBeliefs(context.Background(), []string{entID}, 20, beliefNow)
	require.NoError(t, err)
	assert.Zero(t, touched, "an unstaged chat ref never mints owner rank — the op is dropped")

	got, err := v.ReadNode(bel.ID)
	require.NoError(t, err)
	assert.Equal(t, "active", got.Status)
	assert.NotContains(t, got.Body, "owner", "no owner evidence line was written")
}

// dumpInboxSituationState snapshots the inbox_items + situations +
// situation_signals rows as an ordered string, for MEM-05 byte-identity checks.
func dumpInboxSituationState(t *testing.T, d *db.DB) string {
	t.Helper()
	var out string
	for _, q := range []string{
		`SELECT COALESCE(GROUP_CONCAT(id || ':' || channel_id || ':' || COALESCE(snippet,'')), '') FROM (SELECT * FROM inbox_items ORDER BY id)`,
		`SELECT COALESCE(GROUP_CONCAT(id || ':' || title || ':' || status), '') FROM (SELECT * FROM situations ORDER BY id)`,
		`SELECT COALESCE(GROUP_CONCAT(situation_id || ':' || inbox_item_id), '') FROM (SELECT * FROM situation_signals ORDER BY situation_id, inbox_item_id)`,
	} {
		var s string
		require.NoError(t, d.QueryRow(q).Scan(&s))
		out += s + "|"
	}
	return out
}
