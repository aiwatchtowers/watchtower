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
	staged, newFloor, err := p.ingestChatStatements(0, []string{"situation"})
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

	staged, newFloor, err := p.ingestChatStatements(5, []string{"situation"})
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
	staged, newFloor, err := p.ingestChatStatements(below, []string{"situation"})
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
	p.runSemantic(context.Background(), 0, 0, nil, &usageAccumulator{}, &stats)
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
	p.runSemantic(context.Background(), 0, 0, nil, &usageAccumulator{}, &stats)

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
	p.runSemantic(context.Background(), 0, 0, nil, &usageAccumulator{}, &stats)
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
// STAGED into the belief pass input (the staged param) — DB existence alone never mints
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
	// Nothing is staged (staged param nil), so the cited ref is invented input.

	touched, _, _, _, err := p.ReviseBeliefs(context.Background(), []string{entID}, nil, 20, beliefNow)
	require.NoError(t, err)
	assert.Zero(t, touched, "an unstaged chat ref never mints owner rank — the op is dropped")

	got, err := v.ReadNode(bel.ID)
	require.NoError(t, err)
	assert.Equal(t, "active", got.Status)
	assert.NotContains(t, got.Body, "owner", "no owner evidence line was written")
}

// TestIngestChatStatementsMappingErrorHoldsFloor: a genuine DB error mapping a
// turn's situation (M3a) is returned distinctly, and the erroring turn is NOT
// consumed — the floor holds so the turn is re-scanned next run rather than
// silently dropped.
func TestIngestChatStatementsMappingErrorHoldsFloor(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	createChatTables(t, d)
	seedWorkspaceRow(t, d)
	entID := "ent_00000000000000000000000001"
	writeAndIndex(t, v, d, bareEntity(entID, "C1GEN"))
	sitID := seedSituationForChannel(t, d, "C1GEN", "U2BOB")
	conv := seedChatConversation(t, d, "situation", fmt.Sprintf("%d", sitID))
	seedChatMessage(t, d, conv, "user", "alice keeps missing deadlines", 1720000000.0)

	// Force a DB read failure mapping the situation's signals.
	_, err := d.Exec(`DROP TABLE situation_signals`)
	require.NoError(t, err)

	p := NewPipeline(d, v, &fakeGen{}, chatIngestConfig(), t.Logf)
	staged, newFloor, err := p.ingestChatStatements(0, []string{"situation"})
	require.Error(t, err, "a DB error mapping a turn's situation is returned, not swallowed")
	assert.Nil(t, staged)
	assert.Equal(t, int64(0), newFloor, "the erroring turn is not consumed — the floor holds")
}

// TestRunSemanticChatFloorHeldOnCapBreak: when the belief pass hits beliefs_max
// with ops still unprocessed (staged owner refs may be uncited), the chat-turn
// floor is held for a re-scan and the turns are not counted as ingested (M3b/n8).
func TestRunSemanticChatFloorHeldOnCapBreak(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	createChatTables(t, d)
	seedWorkspaceRow(t, d)
	entID := "ent_00000000000000000000000001"
	writeAndIndex(t, v, d, bareEntity(entID, "C1GEN"))
	bel1 := beliefTestNode("bel_00000000000000000000000001", "Alice is reliable", entID, 0.5, 0, "active")
	bel2 := beliefTestNode("bel_00000000000000000000000002", "Bob is reliable", entID, 0.5, 0, "active")
	writeAndIndex(t, v, d, bel1)
	writeAndIndex(t, v, d, bel2)
	sitID := seedSituationForChannel(t, d, "C1GEN", "U2BOB")
	conv := seedChatConversation(t, d, "situation", fmt.Sprintf("%d", sitID))
	seedChatMessage(t, d, conv, "user", "alice keeps missing deadlines", 1720000000.0)

	chatRef := fmt.Sprintf("chat:%d", conv)
	gen := &fakeGen{reply: func(string) (string, error) {
		return opsJSON(t,
			beliefOpJSON{BeliefID: bel1.ID, Op: "shake", Evidence: []episodeRef{{ChannelID: chatRef, TS: "1720000000"}}, Rationale: "x"},
			beliefOpJSON{BeliefID: bel2.ID, Op: "shake", Evidence: []episodeRef{{ChannelID: chatRef, TS: "1720000000"}}, Rationale: "y"},
		), nil
	}}
	cfg := chatIngestConfig()
	cfg.Semantic.BeliefsMax = 1 // the second op is truncated → capHit
	p := NewPipeline(d, v, gen, cfg, t.Logf)

	var stats RunStats
	p.runSemantic(context.Background(), 0, 0, nil, &usageAccumulator{}, &stats)

	floor, err := d.MemoryChatTurnFloor()
	require.NoError(t, err)
	assert.Equal(t, int64(0), floor, "a belief-pass cap-break holds the chat-turn floor for re-scan")
	assert.Zero(t, stats.ChatTurnsIngested, "turns not consumed on a cap-break are not counted (n8)")
}

// TestRunSemanticChatFloorAdvancesWhenModelDeclinesToCite: a pass that completes
// WITHOUT a cap-break advances the floor even when the model cited no staged ref
// (by-design — the turns had their chance), and the consumed turns are counted.
func TestRunSemanticChatFloorAdvancesWhenModelDeclinesToCite(t *testing.T) {
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

	// The model declines to cite anything (empty ops) — a clean completed pass.
	gen := &fakeGen{reply: func(string) (string, error) { return `{"ops":[]}`, nil }}
	p := NewPipeline(d, v, gen, chatIngestConfig(), t.Logf)

	var stats RunStats
	p.runSemantic(context.Background(), 0, 0, nil, &usageAccumulator{}, &stats)

	floor, err := d.MemoryChatTurnFloor()
	require.NoError(t, err)
	assert.Equal(t, turnID, floor, "a completed pass advances the floor even with no citation (by-design)")
	assert.Equal(t, 1, stats.ChatTurnsIngested, "the consumed staged turn is counted")

	got, err := v.ReadNode(bel.ID)
	require.NoError(t, err)
	assert.Equal(t, "active", got.Status, "the belief is untouched when the model cited nothing")
}

// seedTrack inserts a tracks row with the given channels + participants +
// assignee, returning its id — the subject source for chatSubjects("track").
func seedTrack(t *testing.T, d *db.DB, channelIDsJSON, participantsJSON, assignee string) int {
	t.Helper()
	res, err := d.Exec(`INSERT INTO tracks (text, channel_ids, participants, assignee_user_id)
		VALUES ('a track', ?, ?, ?)`, channelIDsJSON, participantsJSON, assignee)
	require.NoError(t, err)
	id, err := res.LastInsertId()
	require.NoError(t, err)
	return int(id)
}

// TestChatSubjectsTrack: a track context maps to its channel_ids + participant
// user ids + assignee (each resolved to a memory entity, deduped).
func TestChatSubjectsTrack(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	chID := "ent_00000000000000000000000001"
	upID := "ent_00000000000000000000000002"
	writeAndIndex(t, v, d, bareEntity(chID, "C1TRACK"))
	writeAndIndex(t, v, d, bareEntity(upID, "U2BOB"))
	trackID := seedTrack(t, d, `["C1TRACK"]`, `[{"user_id":"U2BOB"}]`, "U2BOB")

	p := NewPipeline(d, v, &fakeGen{}, chatIngestConfig(), t.Logf)
	subjects, err := p.chatSubjects("track", fmt.Sprintf("%d", trackID))
	require.NoError(t, err)
	assert.ElementsMatch(t, []string{chID, upID}, subjects, "track channels + members resolve, deduped")
}

// TestChatSubjectsTargetViaLinkedTrack: a target context maps to the entities of
// its linked track(s).
func TestChatSubjectsTargetViaLinkedTrack(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	chID := "ent_00000000000000000000000001"
	writeAndIndex(t, v, d, bareEntity(chID, "C1TRACK"))
	tgtID, err := d.CreateTarget(db.Target{Text: "ship", Status: "todo", Priority: "medium", Ownership: "mine", SourceType: "manual"})
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO tracks (text, channel_ids, linked_target_id) VALUES ('t', ?, ?)`, `["C1TRACK"]`, tgtID)
	require.NoError(t, err)

	p := NewPipeline(d, v, &fakeGen{}, chatIngestConfig(), t.Logf)
	subjects, err := p.chatSubjects("target", fmt.Sprintf("%d", tgtID))
	require.NoError(t, err)
	assert.Equal(t, []string{chID}, subjects, "target maps through its linked track")
}

// TestChatSubjectsTargetNoLinkedTrackEmpty: a bare target with no linked track
// maps to no entity (the consumed-not-staged graceful path).
func TestChatSubjectsTargetNoLinkedTrackEmpty(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	tgtID, err := d.CreateTarget(db.Target{Text: "lonely", Status: "todo", Priority: "medium", Ownership: "mine", SourceType: "manual"})
	require.NoError(t, err)

	p := NewPipeline(d, v, &fakeGen{}, chatIngestConfig(), t.Logf)
	subjects, err := p.chatSubjects("target", fmt.Sprintf("%d", tgtID))
	require.NoError(t, err)
	assert.Empty(t, subjects, "a target with no linked track maps to no entity")
}

// TestChatSubjectsTrackIncludesMirror: a track chat's subjects include the
// track's OWN entity mirror (track:<id>, the 5C mirror alias) UNIONED with the
// existing channel/participant entities — Task 3.
func TestChatSubjectsTrackIncludesMirror(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	chID := "ent_00000000000000000000000001"
	upID := "ent_00000000000000000000000002"
	mirrorID := "ent_00000000000000000000000003"
	writeAndIndex(t, v, d, bareEntity(chID, "C1TRACK"))
	writeAndIndex(t, v, d, bareEntity(upID, "U2BOB"))
	trackID := seedTrack(t, d, `["C1TRACK"]`, `[{"user_id":"U2BOB"}]`, "U2BOB")
	writeAndIndex(t, v, d, bareEntity(mirrorID, trackMirrorAlias(trackID)))

	p := NewPipeline(d, v, &fakeGen{}, chatIngestConfig(), t.Logf)
	subjects, err := p.chatSubjects("track", fmt.Sprintf("%d", trackID))
	require.NoError(t, err)
	assert.ElementsMatch(t, []string{mirrorID, chID, upID}, subjects, "the track's own mirror plus its channel/participant entities")
}

// TestChatSubjectsTargetMirrorPresentMapsToMirror: with a target:<id> mirror
// present, a bare target with NO linked track maps to its own mirror entity —
// the slice-2 known-limitation ("a bare target chat maps to nothing") resolved
// once operational mirrors exist (Task 3).
func TestChatSubjectsTargetMirrorPresentMapsToMirror(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	mirrorID := "ent_00000000000000000000000001"
	tgtID, err := d.CreateTarget(db.Target{Text: "lonely", Status: "todo", Priority: "medium", Ownership: "mine", SourceType: "manual"})
	require.NoError(t, err)
	writeAndIndex(t, v, d, bareEntity(mirrorID, targetMirrorAlias(int(tgtID))))

	p := NewPipeline(d, v, &fakeGen{}, chatIngestConfig(), t.Logf)
	subjects, err := p.chatSubjects("target", fmt.Sprintf("%d", tgtID))
	require.NoError(t, err)
	assert.Equal(t, []string{mirrorID}, subjects, "a bare target maps to its own mirror when one exists")
}

// TestIngestChatStatementsTargetMirrorPresentStages is the Task-3 end-to-end
// contract: with a target:<id> mirror present, a "remember this:" turn in a
// bare-target Discuss chat (no linked track) stages owner-rank evidence
// subject-mapped to the mirror.
func TestIngestChatStatementsTargetMirrorPresentStages(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	createChatTables(t, d)
	seedWorkspaceRow(t, d)
	mirrorID := "ent_00000000000000000000000001"
	tgtID, err := d.CreateTarget(db.Target{Text: "lonely", Status: "todo", Priority: "medium", Ownership: "mine", SourceType: "manual"})
	require.NoError(t, err)
	writeAndIndex(t, v, d, bareEntity(mirrorID, targetMirrorAlias(int(tgtID))))
	conv := seedChatConversation(t, d, "target", fmt.Sprintf("%d", tgtID))
	turnID := seedChatMessage(t, d, conv, "user", "remember this: this needs a design doc first", 1720000100.0)

	types := []string{"situation", "target", "track"}
	p := NewPipeline(d, v, &fakeGen{}, chatIngestConfig(), t.Logf)
	staged, newFloor, err := p.ingestChatStatements(0, types)
	require.NoError(t, err)
	require.NotNil(t, staged, "with the mirror present, the bare-target turn stages")
	require.Len(t, staged.statements, 1)
	assert.Equal(t, "this needs a design doc first", staged.statements[0].text, "the command prefix is stripped")
	assert.Equal(t, []string{mirrorID}, staged.statements[0].subjects, "subject-mapped to the target's own mirror")
	assert.True(t, staged.subjects[mirrorID])
	assert.Equal(t, turnID, newFloor)
}

// TestIngestChatStatementsTargetNoMirrorNotStaged: without a target:<id>
// mirror, the same "remember this:" bare-target turn is consumed (the floor
// advances) but NOT staged — byte-unchanged slice-2 behavior (Task 3).
func TestIngestChatStatementsTargetNoMirrorNotStaged(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	createChatTables(t, d)
	seedWorkspaceRow(t, d)
	tgtID, err := d.CreateTarget(db.Target{Text: "lonely", Status: "todo", Priority: "medium", Ownership: "mine", SourceType: "manual"})
	require.NoError(t, err)
	conv := seedChatConversation(t, d, "target", fmt.Sprintf("%d", tgtID))
	turnID := seedChatMessage(t, d, conv, "user", "remember this: this needs a design doc first", 1720000100.0)

	types := []string{"situation", "target", "track"}
	p := NewPipeline(d, v, &fakeGen{}, chatIngestConfig(), t.Logf)
	staged, newFloor, err := p.ingestChatStatements(0, types)
	require.NoError(t, err)
	assert.Nil(t, staged, "no mirror — the turn maps to no entity, consumed-not-staged")
	assert.Equal(t, turnID, newFloor, "the turn is still consumed (floor advances past it)")
}

// TestParseRememberCommand pins the "remember this" prefix parser: case-
// insensitive "remember:" / "remember this:", the remainder returned verbatim
// (original case preserved), empty/prefix-only remainders and no-prefix text
// yielding ok=false.
func TestParseRememberCommand(t *testing.T) {
	cases := []struct {
		in       string
		wantStmt string
		wantOK   bool
	}{
		{"remember: alice owns billing", "alice owns billing", true},
		{"remember this: alice owns billing", "alice owns billing", true},
		{"Remember This: Alice Owns Billing", "Alice Owns Billing", true},
		{"  remember:   spaced fact  ", "spaced fact", true},
		{"REMEMBER: shouty", "shouty", true},
		{"just an ordinary drafting turn", "", false},
		{"remember:", "", false},
		{"remember this:", "", false},
		{"remembering things is hard", "", false},
	}
	for _, c := range cases {
		stmt, ok := parseRememberCommand(c.in)
		assert.Equal(t, c.wantOK, ok, "ok for %q", c.in)
		assert.Equal(t, c.wantStmt, stmt, "statement for %q", c.in)
	}
}

// TestIngestChatStatementsTrackRequiresCommand: a plain track owner turn is
// consumed by the floor but NOT staged; the same turn prefixed with
// "remember this:" stages the prefix-stripped fact about the track's subjects.
func TestIngestChatStatementsTrackRequiresCommand(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	createChatTables(t, d)
	seedWorkspaceRow(t, d)
	chID := "ent_00000000000000000000000001"
	writeAndIndex(t, v, d, bareEntity(chID, "C1TRACK"))
	trackID := seedTrack(t, d, `["C1TRACK"]`, `[]`, "")
	conv := seedChatConversation(t, d, "track", fmt.Sprintf("%d", trackID))
	// An ordinary drafting turn — must NOT stage.
	plain := seedChatMessage(t, d, conv, "user", "reword this to be firmer", 1720000000.0)

	types := []string{"situation", "target", "track"}
	p := NewPipeline(d, v, &fakeGen{}, chatIngestConfig(), t.Logf)
	staged, newFloor, err := p.ingestChatStatements(0, types)
	require.NoError(t, err)
	assert.Nil(t, staged, "an ordinary track drafting turn is not staged")
	assert.Equal(t, plain, newFloor, "the drafting turn is still consumed (floor advances past it)")

	// A "remember this:" turn stages the stripped fact.
	cmd := seedChatMessage(t, d, conv, "user", "remember this: this track is blocked on legal", 1720000100.0)
	staged, newFloor, err = p.ingestChatStatements(plain, types)
	require.NoError(t, err)
	require.NotNil(t, staged)
	require.Len(t, staged.statements, 1)
	assert.Equal(t, "this track is blocked on legal", staged.statements[0].text, "the prefix is stripped for the statement")
	assert.Equal(t, []string{chID}, staged.statements[0].subjects, "staged about the track's channel entity")
	assert.Equal(t, cmd, newFloor)
}

// TestIngestChatStatementsSituationStagesEitherWay: a situation owner turn stages
// with OR without the command (Phase-4 unchanged); when the command is present
// the prefix is stripped for the statement text.
func TestIngestChatStatementsSituationStagesEitherWay(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	createChatTables(t, d)
	seedWorkspaceRow(t, d)
	entID := "ent_00000000000000000000000001"
	writeAndIndex(t, v, d, bareEntity(entID, "C1GEN"))
	sitID := seedSituationForChannel(t, d, "C1GEN", "U2BOB")
	conv := seedChatConversation(t, d, "situation", fmt.Sprintf("%d", sitID))
	plain := seedChatMessage(t, d, conv, "user", "alice keeps missing deadlines", 1720000000.0)
	seedChatMessage(t, d, conv, "user", "remember this: bob owns releases", 1720000100.0)

	types := []string{"situation", "target", "track"}
	p := NewPipeline(d, v, &fakeGen{}, chatIngestConfig(), t.Logf)

	// The plain situation turn stages verbatim.
	staged, _, err := p.ingestChatStatements(0, types)
	require.NoError(t, err)
	require.NotNil(t, staged)
	require.Len(t, staged.statements, 2, "both situation turns stage")
	assert.Equal(t, "alice keeps missing deadlines", staged.statements[0].text)
	assert.Equal(t, "bob owns releases", staged.statements[1].text, "a command on a situation turn strips the prefix, harmlessly")
	_ = plain
}

// TestIngestChatStatementsOffIgnoresTrack: with only {"situation"} (flag off) a
// track owner turn is never scanned — MEM-09 byte-identical behavior.
func TestIngestChatStatementsOffIgnoresTrack(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	createChatTables(t, d)
	seedWorkspaceRow(t, d)
	chID := "ent_00000000000000000000000001"
	writeAndIndex(t, v, d, bareEntity(chID, "C1TRACK"))
	trackID := seedTrack(t, d, `["C1TRACK"]`, `[]`, "")
	conv := seedChatConversation(t, d, "track", fmt.Sprintf("%d", trackID))
	seedChatMessage(t, d, conv, "user", "the track is blocked on legal", 1720000000.0)

	p := NewPipeline(d, v, &fakeGen{}, chatIngestConfig(), t.Logf)
	staged, newFloor, err := p.ingestChatStatements(0, []string{"situation"})
	require.NoError(t, err)
	assert.Nil(t, staged, "flag off → a track turn is not even scanned")
	assert.Equal(t, int64(0), newFloor, "flag off → nothing consumed")
}

// chatsSourceConfig is chatIngestConfig with memory.sources.chats ON — the
// target/track widening + "remember this" gate.
func chatsSourceConfig() config.MemoryConfig {
	cfg := chatIngestConfig()
	cfg.Sources.Chats = true
	return cfg
}

// TestRunSemanticRememberThisTrackOwnerEvidence is the Task-6 end-to-end
// contract: with memory.sources.chats ON, a "remember this:" track owner turn
// mints exactly one owner-rank evidence line on a belief about the track's
// subject entity (MEM-09 code-mint), and the chat-turn floor advances.
func TestRunSemanticRememberThisTrackOwnerEvidence(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	createChatTables(t, d)
	seedWorkspaceRow(t, d)
	chID := "ent_00000000000000000000000001"
	writeAndIndex(t, v, d, bareEntity(chID, "C1TRACK"))
	bel := beliefTestNode("bel_00000000000000000000000001", "The track is on schedule", chID, 0.5, 0, "active")
	writeAndIndex(t, v, d, bel)
	trackID := seedTrack(t, d, `["C1TRACK"]`, `[]`, "")
	conv := seedChatConversation(t, d, "track", fmt.Sprintf("%d", trackID))
	turnID := seedChatMessage(t, d, conv, "user", "remember this: the track slipped a week", 1720000000.0)

	chatRef := fmt.Sprintf("chat:%d", conv)
	gen := &fakeGen{reply: func(string) (string, error) {
		return opsJSON(t, beliefOpJSON{BeliefID: bel.ID, Op: "retire",
			Evidence: []episodeRef{{ChannelID: chatRef, TS: "1720000000"}}, Rationale: "owner said"}), nil
	}}
	p := NewPipeline(d, v, gen, chatsSourceConfig(), t.Logf)

	var stats RunStats
	p.runSemantic(context.Background(), 0, 0, nil, &usageAccumulator{}, &stats)
	assert.Equal(t, 1, stats.ChatTurnsIngested)

	got, err := v.ReadNode(bel.ID)
	require.NoError(t, err)
	assert.Contains(t, got.Body, "- owner against "+chatRef+" 1720000000", "MEM-09 owner rank minted for the track chat ref")

	floor, err := d.MemoryChatTurnFloor()
	require.NoError(t, err)
	assert.Equal(t, turnID, floor, "the chat-turn floor advances after the belief pass commits")
}

// TestRunSemanticRememberThisTrackFlagOffNoEvidence: with memory.sources.chats
// OFF, the same "remember this:" track turn is never scanned (context set is
// {situation}), so no owner evidence is minted and the floor stays.
func TestRunSemanticRememberThisTrackFlagOffNoEvidence(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	createChatTables(t, d)
	seedWorkspaceRow(t, d)
	chID := "ent_00000000000000000000000001"
	writeAndIndex(t, v, d, bareEntity(chID, "C1TRACK"))
	bel := beliefTestNode("bel_00000000000000000000000001", "The track is on schedule", chID, 0.5, 0, "active")
	writeAndIndex(t, v, d, bel)
	trackID := seedTrack(t, d, `["C1TRACK"]`, `[]`, "")
	conv := seedChatConversation(t, d, "track", fmt.Sprintf("%d", trackID))
	seedChatMessage(t, d, conv, "user", "remember this: the track slipped a week", 1720000000.0)

	// Flag off: chatIngestConfig has Sources.Chats false.
	gen := &fakeGen{reply: func(string) (string, error) { return `{"ops":[]}`, nil }}
	p := NewPipeline(d, v, gen, chatIngestConfig(), t.Logf)

	var stats RunStats
	p.runSemantic(context.Background(), 0, 0, nil, &usageAccumulator{}, &stats)
	assert.Zero(t, stats.ChatTurnsIngested, "flag off → the track turn is not ingested")

	got, err := v.ReadNode(bel.ID)
	require.NoError(t, err)
	assert.Equal(t, "active", got.Status, "flag off → belief untouched")
	assert.NotContains(t, got.Body, "owner", "flag off → no owner evidence")

	floor, err := d.MemoryChatTurnFloor()
	require.NoError(t, err)
	assert.Equal(t, int64(0), floor, "flag off → floor untouched")
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
