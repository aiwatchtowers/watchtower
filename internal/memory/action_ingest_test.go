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

// actionsConfig is a semantic-enabled config with the actions source on, for the
// runSemantic wiring tests.
func actionsConfig() config.MemoryConfig {
	cfg := pipelineTestConfig()
	cfg.Semantic.Enabled = true
	cfg.Sources.Actions = true
	return cfg
}

// actMirror is a situation episode-mirror node with an empty "## Outcome"
// section — the annotation anchor for the interaction ingest.
func actMirror(sitID int) Node {
	return Node{
		ID:      NewID("episode"),
		Type:    "episode",
		Tier:    "short",
		Status:  "active",
		Title:   "Mirror",
		Aliases: []string{fmt.Sprintf("situation:%d", sitID)},
		Body:    "# Mirror\n\n## Story\ns\n\n## Outcome\n\n## Provenance\n- C1GEN 1.1\n",
	}
}

// seedActSituation seeds an entity (aliased to channelID), an inbox item in that
// channel, a situation carrying it as a signal, and the situation's episode
// mirror. Returns the situation id, its inbox item id, and the entity node id.
// Pass channelID="" for the "maps to no entity" case (no entity is seeded).
func seedActSituation(t *testing.T, v *Vault, d *db.DB, entityAlias string) (sitID, itemID int, entID string) {
	t.Helper()
	entID = "ent_00000000000000000000000001"
	if entityAlias != "" {
		writeAndIndex(t, v, d, bareEntity(entID, entityAlias))
	}
	item, err := d.CreateInboxItem(db.InboxItem{ChannelID: "C1GEN", MessageTS: "1.1", SenderUserID: "U2BOB", TriggerType: "stream"})
	require.NoError(t, err)
	sit, err := d.CreateSituation(db.DashboardSituation{Title: "situation", Kind: "external", Priority: "medium"})
	require.NoError(t, err)
	require.NoError(t, d.AddSituationSignals(int(sit), []int{int(item)}))
	writeAndIndex(t, v, d, actMirror(int(sit)))
	return int(sit), int(item), entID
}

// seedFeedback inserts one inbox_feedback row and returns its id.
func seedFeedback(t *testing.T, d *db.DB, itemID, rating int, createdAt string) int64 {
	t.Helper()
	res, err := d.Exec(`INSERT INTO inbox_feedback (inbox_item_id, rating, reason, created_at) VALUES (?, ?, '', ?)`,
		itemID, rating, createdAt)
	require.NoError(t, err)
	id, err := res.LastInsertId()
	require.NoError(t, err)
	return id
}

// TestIngestInteractionsFeedbackAnnotatesAndBumps: a 👎 on an item whose
// situation maps to an entity appends an "owner dismissed" bullet to the mirror's
// ## Outcome, increments that entity's dismissed_count, stages the act: ref, and
// advances the floor to the feedback id.
func TestIngestInteractionsFeedbackAnnotatesAndBumps(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	sitID, itemID, entID := seedActSituation(t, v, d, "C1GEN")
	fid := seedFeedback(t, d, itemID, -1, "2026-07-16T10:00:00Z")

	p := NewPipeline(d, v, &fakeGen{}, actionsConfig(), t.Logf)
	staged, folded, bumped, newFloor, err := p.ingestInteractions(0)
	require.NoError(t, err)
	assert.Equal(t, 1, folded, "one interaction folded")
	assert.Equal(t, 1, bumped, "one entity engagement bumped")
	assert.Equal(t, fid, newFloor, "floor advances to the feedback id")

	engaged, dismissed, err := d.GetEngagement(entID)
	require.NoError(t, err)
	assert.Equal(t, 0, engaged)
	assert.Equal(t, 1, dismissed, "👎 → dismissed_count")

	n, err := Resolve(v, d, fmt.Sprintf("situation:%d", sitID))
	require.NoError(t, err)
	assert.Contains(t, n.Body, "- 2026-07-16: owner dismissed", "owner-action bullet appended to ## Outcome")

	require.NotNil(t, staged)
	assert.True(t, staged.refs[fmt.Sprintf("act:inbox_feedback:%d ", fid)+tsOf(t, d, fid)], "act: ref staged for the belief pass")
	assert.True(t, staged.subjects[entID])
}

// TestIngestInteractions_EngagementStampIsRFC3339 guards fix #14: the
// memory_engagement.last_interaction_at stamp is the interaction's RFC3339
// created_at (not its unix-seconds ref ts), matching the column's timestamp
// intent.
func TestIngestInteractions_EngagementStampIsRFC3339(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	_, itemID, entID := seedActSituation(t, v, d, "C1GEN")
	seedFeedback(t, d, itemID, 1, "2026-07-16T10:00:00Z")

	p := NewPipeline(d, v, &fakeGen{}, actionsConfig(), t.Logf)
	_, _, bumped, _, err := p.ingestInteractions(0)
	require.NoError(t, err)
	require.Equal(t, 1, bumped)

	var stamp string
	require.NoError(t, d.QueryRow(`SELECT last_interaction_at FROM memory_engagement WHERE node_id = ?`, entID).Scan(&stamp))
	assert.Equal(t, "2026-07-16T10:00:00Z", stamp, "last_interaction_at is the RFC3339 created_at, not a unix string")
}

// tsOf returns the unix-seconds string of an inbox_feedback row's created_at, for
// asserting the staged act: ref key.
func tsOf(t *testing.T, d *db.DB, fid int64) string {
	t.Helper()
	var ts int64
	require.NoError(t, d.QueryRow(`SELECT CAST(strftime('%s', created_at) AS INTEGER) FROM inbox_feedback WHERE id = ?`, fid).Scan(&ts))
	return fmt.Sprintf("%d", ts)
}

// TestIngestInteractionsConversionAnnotatesEngaged: a converted situation appends
// "converted to target #N" and increments the subject entity's engaged_count.
func TestIngestInteractionsConversionAnnotatesEngaged(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	sitID, _, entID := seedActSituation(t, v, d, "C1GEN")
	require.NoError(t, d.MarkSituationConverted(sitID, 12, 0))

	p := NewPipeline(d, v, &fakeGen{}, actionsConfig(), t.Logf)
	_, folded, bumped, _, err := p.ingestInteractions(0)
	require.NoError(t, err)
	assert.Equal(t, 1, folded)
	assert.Equal(t, 1, bumped)

	engaged, dismissed, err := d.GetEngagement(entID)
	require.NoError(t, err)
	assert.Equal(t, 1, engaged, "conversion → engaged_count")
	assert.Equal(t, 0, dismissed)

	n, err := Resolve(v, d, fmt.Sprintf("situation:%d", sitID))
	require.NoError(t, err)
	assert.Contains(t, n.Body, "converted to target #12", "conversion outcome annotation")
}

// TestIngestInteractionsConversionIdempotent: a second re-scan of the same
// converted situation is a no-op — the mirror bullet is already present, so the
// engagement aggregate does not double-count (the novelty-gated re-scan).
func TestIngestInteractionsConversionIdempotent(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	_, _, entID := seedActSituation(t, v, d, "C1GEN")
	require.NoError(t, d.MarkSituationConverted(1, 12, 0))

	p := NewPipeline(d, v, &fakeGen{}, actionsConfig(), t.Logf)
	_, _, _, _, err := p.ingestInteractions(0)
	require.NoError(t, err)
	_, folded, bumped, _, err := p.ingestInteractions(0)
	require.NoError(t, err)
	assert.Zero(t, folded, "an already-annotated verdict is a no-op on re-scan")
	assert.Zero(t, bumped)

	engaged, _, err := d.GetEngagement(entID)
	require.NoError(t, err)
	assert.Equal(t, 1, engaged, "engagement not double-counted on re-scan")
}

// TestIngestInteractionsMapsToNoEntity: a feedback whose situation channel aliases
// no memory entity is consumed (the floor advances) but bumps no aggregate and
// stages nothing.
func TestIngestInteractionsMapsToNoEntity(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	_, itemID, _ := seedActSituation(t, v, d, "") // no entity seeded
	fid := seedFeedback(t, d, itemID, -1, "2026-07-16T10:00:00Z")

	p := NewPipeline(d, v, &fakeGen{}, actionsConfig(), t.Logf)
	staged, folded, bumped, newFloor, err := p.ingestInteractions(0)
	require.NoError(t, err)
	assert.Zero(t, folded)
	assert.Zero(t, bumped)
	assert.Nil(t, staged, "nothing staged when nothing maps")
	assert.Equal(t, fid, newFloor, "the interaction is still consumed — the floor advances past it")
}

// TestIngestInteractionsFloorHoldsOnError: a DB error mapping an interaction's
// situation freezes the whole step — the floor is returned unmoved so the rows
// re-scan next run.
func TestIngestInteractionsFloorHoldsOnError(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	_, itemID, _ := seedActSituation(t, v, d, "C1GEN")
	seedFeedback(t, d, itemID, -1, "2026-07-16T10:00:00Z")

	_, err := d.Exec(`DROP TABLE situation_signals`)
	require.NoError(t, err)

	p := NewPipeline(d, v, &fakeGen{}, actionsConfig(), t.Logf)
	_, _, _, newFloor, err := p.ingestInteractions(0)
	require.Error(t, err, "a mapping DB error freezes the step")
	assert.Equal(t, int64(0), newFloor, "the floor holds on error")
}

// TestIngestInteractionsNoRowsNoOp: with no feedback and no terminal situations
// the step writes nothing, commits nothing, and leaves the floor where it was.
func TestIngestInteractionsNoRowsNoOp(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)

	p := NewPipeline(d, v, &fakeGen{}, actionsConfig(), t.Logf)
	staged, folded, bumped, newFloor, err := p.ingestInteractions(0)
	require.NoError(t, err)
	assert.Nil(t, staged)
	assert.Zero(t, folded)
	assert.Zero(t, bumped)
	assert.Equal(t, int64(0), newFloor)
}

// TestMemory05_InteractionIngestInboxUntouched guards MEM-05 for the Phase-5
// interaction ingest: it reads inbox_feedback / situations / situation_signals
// but writes none of them, and never moves inbox_last_processed_ts.
func TestMemory05_InteractionIngestInboxUntouched(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	_, err := d.Exec(`INSERT INTO workspace (id, name, inbox_last_processed_ts) VALUES ('T1', 'test', 1752570123.5)`)
	require.NoError(t, err)
	sitID, itemID, _ := seedActSituation(t, v, d, "C1GEN")
	seedFeedback(t, d, itemID, -1, "2026-07-16T10:00:00Z")
	require.NoError(t, d.MarkSituationConverted(sitID, 7, 0))

	inboxBefore := dumpTable(t, d, "inbox_items")
	feedbackBefore := dumpTable(t, d, "inbox_feedback")
	situationsBefore := dumpTable(t, d, "situations")
	signalsBefore := dumpTable(t, d, "situation_signals")

	p := NewPipeline(d, v, &fakeGen{}, actionsConfig(), t.Logf)
	_, _, _, _, err = p.ingestInteractions(0)
	require.NoError(t, err)

	assert.Equal(t, inboxBefore, dumpTable(t, d, "inbox_items"), "inbox_items byte-identical")
	assert.Equal(t, feedbackBefore, dumpTable(t, d, "inbox_feedback"), "inbox_feedback byte-identical")
	assert.Equal(t, situationsBefore, dumpTable(t, d, "situations"), "situations byte-identical")
	assert.Equal(t, signalsBefore, dumpTable(t, d, "situation_signals"), "situation_signals byte-identical")

	var wm float64
	require.NoError(t, d.QueryRow(`SELECT inbox_last_processed_ts FROM workspace`).Scan(&wm))
	assert.Equal(t, 1752570123.5, wm, "inbox watermark untouched")
}

// TestInteractionIngest_GateOff: with memory.sources.actions off, a full Run does
// no interaction work — the floor is unmoved and no engagement row is written.
func TestInteractionIngest_GateOff(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	_, itemID, entID := seedActSituation(t, v, d, "C1GEN")
	seedFeedback(t, d, itemID, -1, "2026-07-16T10:00:00Z")

	cfg := pipelineTestConfig() // Sources.Actions default false
	gen := &fakeGen{reply: func(string) (string, error) { return "[]", nil }}
	p := NewPipeline(d, v, gen, cfg, t.Logf)

	stats, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Zero(t, stats.InteractionsIngested)
	assert.Zero(t, stats.EngagementUpdated)
	floor, err := d.MemoryInteractionFloor()
	require.NoError(t, err)
	assert.Equal(t, int64(0), floor, "the interaction floor is unmoved when the gate is off")
	engaged, dismissed, err := d.GetEngagement(entID)
	require.NoError(t, err)
	assert.Zero(t, engaged)
	assert.Zero(t, dismissed)
}

// TestInteractionIngest_SemanticOffStillAnnotatesAndBumps guards fix #4a: with
// memory.sources.actions ON but the semantic tier OFF, a full Run still folds the
// owner's interactions — the annotation lands, the entity is bumped, and the
// floor advances. Interaction ingest is its own Run step, not a semantic-tier
// sub-step, so it has value without the belief pass.
func TestInteractionIngest_SemanticOffStillAnnotatesAndBumps(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	_, itemID, entID := seedActSituation(t, v, d, "C1GEN")
	fid := seedFeedback(t, d, itemID, 1, "2026-07-16T10:00:00Z")

	cfg := pipelineTestConfig()
	cfg.Sources.Actions = true   // interaction ingest ON
	cfg.Semantic.Enabled = false // semantic tier OFF
	gen := &fakeGen{reply: func(string) (string, error) { return "[]", nil }}
	p := NewPipeline(d, v, gen, cfg, t.Logf)

	stats, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 1, stats.InteractionsIngested, "interaction folded with the semantic tier off")
	assert.Equal(t, 1, stats.EngagementUpdated)
	floor, err := d.MemoryInteractionFloor()
	require.NoError(t, err)
	assert.Equal(t, fid, floor, "the interaction floor advances")
	engaged, _, err := d.GetEngagement(entID)
	require.NoError(t, err)
	assert.Equal(t, 1, engaged, "👍 → engaged_count")
}

// TestIngestInteractions_SharedEntityBumpedOnce guards fix #9b: one 👍 whose inbox
// item belongs to TWO situations sharing the same entity bumps that entity ONCE,
// and InteractionsIngested counts the one distinct feedback id (not once per
// situation).
func TestIngestInteractions_SharedEntityBumpedOnce(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	entID := "ent_00000000000000000000000001"
	writeAndIndex(t, v, d, bareEntity(entID, "C1GEN"))

	item, err := d.CreateInboxItem(db.InboxItem{ChannelID: "C1GEN", MessageTS: "1.1", SenderUserID: "U2BOB", TriggerType: "stream"})
	require.NoError(t, err)
	// Two situations, both carrying the same item (hence the same entity C1GEN).
	for _, title := range []string{"sit-a", "sit-b"} {
		sit, serr := d.CreateSituation(db.DashboardSituation{Title: title, Kind: "external", Priority: "medium"})
		require.NoError(t, serr)
		require.NoError(t, d.AddSituationSignals(int(sit), []int{int(item)}))
		writeAndIndex(t, v, d, actMirror(int(sit)))
	}
	fid := seedFeedback(t, d, int(item), 1, "2026-07-16T10:00:00Z")

	p := NewPipeline(d, v, &fakeGen{}, actionsConfig(), t.Logf)
	_, folded, bumped, newFloor, err := p.ingestInteractions(0)
	require.NoError(t, err)
	assert.Equal(t, 1, folded, "one DISTINCT feedback id, not one per situation")
	assert.Equal(t, 1, bumped, "the shared entity is bumped once")
	assert.Equal(t, fid, newFloor)

	engaged, _, err := d.GetEngagement(entID)
	require.NoError(t, err)
	assert.Equal(t, 1, engaged, "shared entity engaged_count incremented exactly once")
}

// TestIngestInteractions_FloorHeldOnBumpFailure guards fix #9c: if a bump fails
// (memory_engagement gone), the whole batch rolls back and the feedback floor is
// HELD so the batch re-scans next run (transient-error semantics, no double-count).
func TestIngestInteractions_FloorHeldOnBumpFailure(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	_, itemID, _ := seedActSituation(t, v, d, "C1GEN")
	seedFeedback(t, d, itemID, 1, "2026-07-16T10:00:00Z")

	_, err := d.Exec(`DROP TABLE memory_engagement`) // force the bump tx to fail
	require.NoError(t, err)

	p := NewPipeline(d, v, &fakeGen{}, actionsConfig(), t.Logf)
	_, _, bumped, newFloor, err := p.ingestInteractions(0)
	require.Error(t, err, "a bump failure fails the step")
	assert.Zero(t, bumped)
	assert.Equal(t, int64(0), newFloor, "the feedback floor holds so the batch re-scans")
}

// TestIngestInteractions_VerdictStableKeyOnUpdatedAtMove guards fix #7b: moving a
// situation's updated_at (an AttachSignal bump) with the SAME verdict does NOT
// re-annotate or re-bump (novelty keys on verdict TEXT, not the date); a verdict
// that genuinely changes (a track added) appends once more.
func TestIngestInteractions_VerdictStableKeyOnUpdatedAtMove(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	sitID, _, entID := seedActSituation(t, v, d, "C1GEN")
	require.NoError(t, d.MarkSituationConverted(sitID, 12, 0))

	p := NewPipeline(d, v, &fakeGen{}, actionsConfig(), t.Logf)
	_, folded, bumped, _, err := p.ingestInteractions(0)
	require.NoError(t, err)
	require.Equal(t, 1, folded)
	require.Equal(t, 1, bumped)

	// AttachSignal-style bump of updated_at, verdict UNCHANGED.
	_, err = d.Exec(`UPDATE situations SET updated_at = '2026-07-16T12:00:00Z' WHERE id = ?`, sitID)
	require.NoError(t, err)
	_, folded, bumped, _, err = p.ingestInteractions(0)
	require.NoError(t, err)
	assert.Zero(t, folded, "same verdict, moved date → not re-folded")
	assert.Zero(t, bumped)
	engaged, _, err := d.GetEngagement(entID)
	require.NoError(t, err)
	assert.Equal(t, 1, engaged, "no double-bump on an updated_at move")

	// A genuinely changed verdict (track added) appends once more.
	_, err = d.Exec(`UPDATE situations SET converted_track_id = 5 WHERE id = ?`, sitID)
	require.NoError(t, err)
	_, folded, bumped, _, err = p.ingestInteractions(0)
	require.NoError(t, err)
	assert.Equal(t, 1, folded, "a changed verdict is folded once more")
	assert.Equal(t, 1, bumped)
	engaged, _, err = d.GetEngagement(entID)
	require.NoError(t, err)
	assert.Equal(t, 2, engaged, "the changed verdict bumps once more")

	n, err := Resolve(v, d, fmt.Sprintf("situation:%d", sitID))
	require.NoError(t, err)
	assert.Contains(t, n.Body, "converted to target #12 and track #5")
}
