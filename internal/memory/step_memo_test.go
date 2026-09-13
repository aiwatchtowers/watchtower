package memory

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// Tests for the "done today" memo (memory_step_state, migration 00069): the
// three staggered semantic steps used to re-run on every daemon cycle of their
// slot day, because dueForRewrite/dueForReflect are day-granular AND stateless
// and the strong map render had no change gate on its AI call at all.
//
// Every fixture here is built so a wrong implementation fails: more due
// entities than the cap (so "stamped the one it processed" is distinguishable
// from "stamped all of them"), a second cycle on the SAME UTC day (so the
// stagger cannot be what skipped it), and a map input that actually changes
// between renders (so "the gate works" is distinguishable from "the map never
// renders").

// memoRewriteGen is a generator that returns a valid rewrite for every call,
// with distinct prose per call so a re-rewrite of the same page produces a real
// vault diff (WriteNodes refuses a byte-identical batch as an empty commit).
func memoRewriteGen(t *testing.T) *fakeGen {
	t.Helper()
	n := 0
	return &fakeGen{reply: func(string) (string, error) {
		n++
		return rewriteReplyJSON(t, fmt.Sprintf("what %d", n), fmt.Sprintf("current %d", n), []string{"f"},
			[]episodeRef{{ChannelID: "C1CHAN", TS: "1710000000.000100"}}), nil
	}}
}

// seedRewriteFixture writes one shared episode plus count entities all due for a
// rewrite at rewriteNow, and returns their ids in ListMemoryNodes (ORDER BY id)
// order.
func seedRewriteFixture(t *testing.T, v *Vault, d *db.DB, count int) []string {
	t.Helper()
	ids := dueEntityIDs(rewriteNow, count)
	epID := "ep_00000000000000000000000001"
	writeAndIndex(t, v, d, rewriteEpisodeNode(epID, "C1CHAN", "1710000000.000100"))
	for i, id := range ids {
		writeAndIndex(t, v, d, rewriteEntityNode(id, fmt.Sprintf("Ent%d", i), epID))
	}
	return ids
}

// TestRewriteEntityPagesMemoSkipsSecondCycleSameDay: a second daemon cycle on
// the same slot day re-rewrites nothing and makes no AI call — even though the
// stagger still answers "due" for every one of those entities.
func TestRewriteEntityPagesMemoSkipsSecondCycleSameDay(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	ids := seedRewriteFixture(t, v, d, 2)
	gen := memoRewriteGen(t)
	p := NewPipeline(d, v, gen, pipelineTestConfig(), t.Logf)

	first, _, _, err := p.RewriteEntityPages(context.Background(), 10, rewriteNow)
	require.NoError(t, err)
	assert.ElementsMatch(t, ids, first, "the first cycle rewrites both due entities")
	require.Len(t, gen.calls, 2)

	// A later cycle of the SAME UTC day: the stagger by itself would still fire.
	later := rewriteNow.Add(70 * time.Minute)
	for _, id := range ids {
		require.True(t, dueForRewrite(id, later), "the stagger alone still says due — only the memo can skip")
	}

	second, _, _, err := p.RewriteEntityPages(context.Background(), 10, later)
	require.NoError(t, err)
	assert.Empty(t, second, "nothing is re-rewritten on the same slot day")
	assert.Len(t, gen.calls, 2, "no strong-tier call on the repeat cycle")
}

// TestRewriteEntityPagesMemoAdvancesToNextEntities: with more due entities than
// the per-run cap, the next cycle of the same slot day picks up where the last
// one stopped instead of re-rewriting the same first page-set. This is the
// starvation fix — before the memo, every due entity past the cap in the
// ORDER BY id scan was never rewritten at all.
//
// A single-entity fixture could not tell "stamped the entity it processed" from
// "stamped every due entity", so this uses four due entities and a cap of two.
func TestRewriteEntityPagesMemoAdvancesToNextEntities(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	ids := seedRewriteFixture(t, v, d, 4)
	gen := memoRewriteGen(t)
	p := NewPipeline(d, v, gen, pipelineTestConfig(), t.Logf)

	first, _, _, err := p.RewriteEntityPages(context.Background(), 2, rewriteNow)
	require.NoError(t, err)
	assert.Equal(t, ids[:2], first, "the first cycle takes the first two due entities")

	second, _, _, err := p.RewriteEntityPages(context.Background(), 2, rewriteNow.Add(70*time.Minute))
	require.NoError(t, err)
	assert.Equal(t, ids[2:], second, "the next cycle advances to the entities the cap starved")
	assert.Len(t, gen.calls, 4, "four calls total — each entity paid for exactly once")

	third, _, _, err := p.RewriteEntityPages(context.Background(), 2, rewriteNow.Add(140*time.Minute))
	require.NoError(t, err)
	assert.Empty(t, third, "once every due entity is memoed the slot day is done")
	assert.Len(t, gen.calls, 4)
}

// TestRewriteEntityPagesMemoExpiresAtNextSlot: the memo suppresses repeats
// within the slot day only — the entity's next slot, one stagger window later,
// rewrites it again.
func TestRewriteEntityPagesMemoExpiresAtNextSlot(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	ids := seedRewriteFixture(t, v, d, 1)
	gen := memoRewriteGen(t)
	p := NewPipeline(d, v, gen, pipelineTestConfig(), t.Logf)

	_, _, _, err := p.RewriteEntityPages(context.Background(), 10, rewriteNow)
	require.NoError(t, err)
	require.Len(t, gen.calls, 1)

	sameDay, _, _, err := p.RewriteEntityPages(context.Background(), 10, rewriteNow.Add(70*time.Minute))
	require.NoError(t, err)
	require.Empty(t, sameDay)
	require.Len(t, gen.calls, 1)

	nextSlot := rewriteNow.AddDate(0, 0, rewriteStaggerDays)
	require.True(t, dueForRewrite(ids[0], nextSlot), "one stagger window later is the same slot")

	again, _, _, err := p.RewriteEntityPages(context.Background(), 10, nextSlot)
	require.NoError(t, err)
	assert.Equal(t, ids, again, "the memo expires with the day — the weekly cadence is unchanged")
	assert.Len(t, gen.calls, 2)
}

// TestRewriteEntityPagesMemoStampedOnGenerateFailure pins the stamp-on-ATTEMPT
// decision: a failed generate still consumed a strong-tier call, so the entity
// is memoed and NOT retried on the next cycle of the same slot day. The trade is
// deliberate — a transient failure costs that page its weekly slot rather than
// one call per daemon cycle all day.
func TestRewriteEntityPagesMemoStampedOnGenerateFailure(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedRewriteFixture(t, v, d, 1)
	gen := &fakeGen{reply: func(string) (string, error) { return "", fmt.Errorf("model down") }}
	p := NewPipeline(d, v, gen, pipelineTestConfig(), t.Logf)

	rewritten, failed, _, err := p.RewriteEntityPages(context.Background(), 10, rewriteNow)
	require.NoError(t, err)
	assert.Empty(t, rewritten)
	assert.Equal(t, 1, failed)
	require.Len(t, gen.calls, 1)

	rewritten, failed, _, err = p.RewriteEntityPages(context.Background(), 10, rewriteNow.Add(70*time.Minute))
	require.NoError(t, err)
	assert.Empty(t, rewritten)
	assert.Zero(t, failed, "the failed entity is not re-attempted this slot day")
	assert.Len(t, gen.calls, 1, "a failing page does not burn one call per cycle")
}

// reflectMemoFixture seeds a workspace plus one belief churned past the flapping
// threshold, and returns the generator and pipeline for a reflection run.
func reflectMemoFixture(t *testing.T, v *Vault, d *db.DB, day time.Time) (*fakeGen, *Pipeline, string) {
	t.Helper()
	seedWorkspaceRow(t, d)
	belID := "bel_00000000000000000000000001"
	bel := beliefTestNode(belID, "Alice ships fast", "ent_00000000000000000000000001", 0.5, 1, "active",
		beliefEvidence{Rank: rankObserved, Support: true, ChannelID: "C1", TS: "1710000000"})
	writeAndIndex(t, v, d, bel)
	churnNode(t, v, bel, "beliefs", reflectChurnThreshold, day)

	gen := &fakeGen{reply: func(string) (string, error) {
		return reflectObsJSON(fmt.Sprintf(`{"kind":"dispute","node_id":%q,"rationale":"keeps flipping"}`, belID)), nil
	}}
	return gen, NewPipeline(d, v, gen, reflectConfig(), t.Logf), belID
}

// TestReflectMemoSkipsSecondRunSameDay: on the reflection slot day the pass runs
// once, not once per daemon cycle — even though the stagger still says "due".
func TestReflectMemoSkipsSecondRunSameDay(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	day := reflectDueDay("T1")
	gen, p, _ := reflectMemoFixture(t, v, d, day)

	n, flagged, _, _, err := p.Reflect(context.Background(), day)
	require.NoError(t, err)
	require.Equal(t, 1, n)
	require.Equal(t, 1, flagged)
	require.Len(t, gen.calls, 1)

	later := day.Add(70 * time.Minute)
	require.True(t, dueForReflect("T1", later), "the stagger alone still says due — only the memo can skip")

	n, flagged, _, _, err = p.Reflect(context.Background(), later)
	require.NoError(t, err)
	assert.Zero(t, n)
	assert.Zero(t, flagged)
	assert.Len(t, gen.calls, 1, "no second strong-tier reflection call on the same slot day")
}

// TestReflectMemoStampedOnGenerateFailure pins the stamp-on-ATTEMPT decision for
// reflection, which is the counter-intuitive one: the vault git log cannot serve
// as this memo (a dispute-only or zero-observation run writes no commit at all),
// and stamping only on success would retry a model outage every daemon cycle all
// slot day — the exact bug being fixed.
func TestReflectMemoStampedOnGenerateFailure(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	day := reflectDueDay("T1")
	gen, p, _ := reflectMemoFixture(t, v, d, day)
	gen.reply = func(string) (string, error) { return "", fmt.Errorf("model down") }

	_, _, _, _, err := p.Reflect(context.Background(), day)
	require.Error(t, err, "the failure is still surfaced to the caller")
	require.Len(t, gen.calls, 1)

	_, _, _, _, err = p.Reflect(context.Background(), day.Add(70*time.Minute))
	require.NoError(t, err)
	assert.Len(t, gen.calls, 1, "an outage costs the week, not one call per cycle")
}

// TestReflectMemoDoesNotBlockNextWeek: the memo is day-scoped, so the next slot
// day one stagger window later reflects again. Without this, a "has run" memo
// would silently retire the weekly pass forever.
func TestReflectMemoDoesNotBlockNextWeek(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	// A due day one window in the past, so the churn commits (written at real
	// clock time) sit inside BOTH runs' seven-day lookbacks.
	day := reflectDueDay("T1").AddDate(0, 0, -reflectStaggerDays)
	gen, p, _ := reflectMemoFixture(t, v, d, day)

	n, _, _, _, err := p.Reflect(context.Background(), day)
	require.NoError(t, err)
	require.Equal(t, 1, n)
	require.Len(t, gen.calls, 1)

	nextSlot := day.AddDate(0, 0, reflectStaggerDays)
	require.True(t, dueForReflect("T1", nextSlot))

	n, _, _, _, err = p.Reflect(context.Background(), nextSlot)
	require.NoError(t, err)
	assert.Equal(t, 1, n, "the weekly cadence survives the memo")
	assert.Len(t, gen.calls, 2)
}

// TestReflectCalmWeekLeavesMemoUnstamped: a calm week returns before the AI call
// and must NOT stamp — nothing was spent, and a later cycle of the same day may
// see real churn.
func TestReflectCalmWeekLeavesMemoUnstamped(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	day := reflectDueDay("T1")

	belID := "bel_00000000000000000000000001"
	bel := beliefTestNode(belID, "Alice ships fast", "ent_00000000000000000000000001", 0.5, 1, "active",
		beliefEvidence{Rank: rankObserved, Support: true, ChannelID: "C1", TS: "1710000000"})
	writeAndIndex(t, v, d, bel) // one commit — below reflectChurnThreshold

	gen := &fakeGen{reply: func(string) (string, error) {
		return reflectObsJSON(fmt.Sprintf(`{"kind":"dispute","node_id":%q,"rationale":"keeps flipping"}`, belID)), nil
	}}
	p := NewPipeline(d, v, gen, reflectConfig(), t.Logf)

	n, _, _, _, err := p.Reflect(context.Background(), day)
	require.NoError(t, err)
	require.Zero(t, n)
	require.Empty(t, gen.calls, "a calm week makes no AI call")

	// Real churn arrives later the same day: the pass must still run.
	churnNode(t, v, bel, "beliefs", reflectChurnThreshold, day)
	n, flagged, _, _, err := p.Reflect(context.Background(), day.Add(70*time.Minute))
	require.NoError(t, err)
	assert.Equal(t, 1, n, "the calm early return did not consume the slot day")
	assert.Equal(t, 1, flagged)
	assert.Len(t, gen.calls, 1)
}

// mapMemoGen returns a generator producing a distinct map body per call, so a
// second render is visible in map.md and not masked by WriteFile's
// byte-identical no-op.
func mapMemoGen() *fakeGen {
	n := 0
	return &fakeGen{reply: func(string) (string, error) {
		n++
		return fmt.Sprintf("# World map\n\nrender %d\n", n), nil
	}}
}

func readMapFile(t *testing.T, v *Vault) string {
	t.Helper()
	content, err := os.ReadFile(filepath.Join(v.path, mapFileName))
	require.NoError(t, err)
	return string(content)
}

// TestRenderMapSkipsUnchangedInput: the map's WRITE was already change-gated,
// but its AI CALL was not — one strong render per daemon cycle, forever. With
// identical vault/index state the second render makes no call at all.
func TestRenderMapSkipsUnchangedInput(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	writeAndIndex(t, v, d, indexEntity("ent_00000000000000000000000001", "Acme", "a project"))
	gen := mapMemoGen()
	p := NewPipeline(d, v, gen, pipelineTestConfig(), t.Logf)

	_, err := p.renderMap(context.Background(), 1, true)
	require.NoError(t, err)
	require.Len(t, gen.calls, 1, "the first render must actually call the model")
	after := readMapFile(t, v)
	assert.Contains(t, after, "render 1")

	_, err = p.renderMap(context.Background(), 2, true)
	require.NoError(t, err)
	assert.Len(t, gen.calls, 1, "byte-identical prompt input skips the strong-tier call")
	assert.Equal(t, after, readMapFile(t, v), "map.md left exactly as it was")
}

// TestRenderMapRendersWhenInputChanges is the other half of the gate: a changed
// ## Current line changes the prompt input, so the map re-renders. Without this
// pairing, TestRenderMapSkipsUnchangedInput would pass just as well against a
// map that never renders at all.
func TestRenderMapRendersWhenInputChanges(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	ent := indexEntity("ent_00000000000000000000000001", "Acme", "a project")
	writeAndIndex(t, v, d, ent)
	gen := mapMemoGen()
	p := NewPipeline(d, v, gen, pipelineTestConfig(), t.Logf)

	_, err := p.renderMap(context.Background(), 1, true)
	require.NoError(t, err)
	require.Len(t, gen.calls, 1)

	// The strong map's input carries each top entity's ## Current first line. The
	// new value is the SAME BYTE LENGTH as the old one on purpose: a fingerprint
	// that hashed len(user) rather than the bytes would otherwise still "detect"
	// this change, and the guard would pass against an implementation that is not
	// keyed on the input at all.
	moved := indexEntity("ent_00000000000000000000000001", "Acme", "a prqject")
	require.Len(t, "a prqject", len("a project"), "the fixture must not vary the input's length")
	writeAndIndex(t, v, d, moved)

	_, err = p.renderMap(context.Background(), 2, true)
	require.NoError(t, err)
	require.Len(t, gen.calls, 2, "a changed world re-renders the map")
	assert.NotEqual(t, gen.calls[0], gen.calls[1], "the second call saw the new input")
	assert.Contains(t, readMapFile(t, v), "render 2")
}

// TestRenderMapRestoresMissingFileOnFingerprintMatch: the fingerprint skip
// returns before ANY write, so a matching fingerprint over a MISSING map.md
// would leave nothing to recreate it — and that is reachable (`memory reset-to`
// rewinds the vault past the map commit; the owner can delete the file). Before
// the gate, every strong cycle either rewrote map.md or fell through to
// fallbackMap, whose os.Stat recreated it; the gate must not lose that.
func TestRenderMapRestoresMissingFileOnFingerprintMatch(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	writeAndIndex(t, v, d, indexEntity("ent_00000000000000000000000001", "Acme", "a project"))
	gen := mapMemoGen()
	p := NewPipeline(d, v, gen, pipelineTestConfig(), t.Logf)

	_, err := p.renderMap(context.Background(), 1, true)
	require.NoError(t, err)
	require.Len(t, gen.calls, 1)

	// The world has not changed — only the file is gone.
	require.NoError(t, os.Remove(filepath.Join(v.path, mapFileName)))

	_, err = p.renderMap(context.Background(), 2, true)
	require.NoError(t, err)
	assert.Len(t, gen.calls, 2, "a missing map.md re-renders even on a fingerprint match")
	assert.Contains(t, readMapFile(t, v), "render 2", "map.md is back on disk")
}

// TestRenderMapFailureDoesNotStampFingerprint: the map stamps on SUCCESS only
// (deliberately unlike the rewrite/reflect memos) — a failed generate leaves the
// input unchanged, so the next cycle is a legitimate retry.
func TestRenderMapFailureDoesNotStampFingerprint(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	writeAndIndex(t, v, d, indexEntity("ent_00000000000000000000000001", "Acme", "a project"))
	calls := 0
	gen := &fakeGen{reply: func(string) (string, error) {
		calls++
		if calls == 1 {
			return "", fmt.Errorf("model exploded")
		}
		return "# World map\n\nrecovered\n", nil
	}}
	p := NewPipeline(d, v, gen, pipelineTestConfig(), t.Logf)

	_, err := p.renderMap(context.Background(), 1, true)
	require.NoError(t, err, "a failed map render never fails the run")
	require.Len(t, gen.calls, 1)

	_, err = p.renderMap(context.Background(), 2, true)
	require.NoError(t, err)
	assert.Len(t, gen.calls, 2, "the failed render is retried, not memoed away")
	assert.Contains(t, readMapFile(t, v), "recovered")
}

// TestRenderMapMechanicalPathNeverStamps: the mechanical fallback (semantic tier
// off / out of budget / no generator) must not record a fingerprint, or turning
// the semantic tier on would silently suppress the first strong render.
func TestRenderMapMechanicalPathNeverStamps(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	writeAndIndex(t, v, d, indexEntity("ent_00000000000000000000000001", "Acme", "a project"))
	gen := mapMemoGen()
	p := NewPipeline(d, v, gen, pipelineTestConfig(), t.Logf)

	_, err := p.renderMap(context.Background(), 1, false)
	require.NoError(t, err)
	require.Empty(t, gen.calls)

	_, err = p.renderMap(context.Background(), 2, true)
	require.NoError(t, err)
	assert.Len(t, gen.calls, 1, "the first strong render still runs after a mechanical cycle")
	assert.Contains(t, readMapFile(t, v), "render 1")
}
