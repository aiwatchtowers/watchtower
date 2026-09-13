package memory

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// Evidence dedupe in the belief pass: a confirm citing only evidence the belief
// already records is a no-op, and a re-cited ref is never weighed twice. The
// dedupe key is the WHOLE rendered evidence line (rank, direction, channel id,
// ts) — these tests pin each way a looser key would collapse two distinct data
// points into one.

// dedupeEpisodeNode builds an active episode carrying several provenance refs
// (the belief pass's input set is built from exactly these).
func dedupeEpisodeNode(id string, refs ...episodeRef) Node {
	body := "# Episode\n\n## Story\nThe migration shipped.\n\n## Outcome\nDone cleanly.\n\n## Provenance\n"
	for _, r := range refs {
		body += "- " + r.ChannelID + " " + r.TS + "\n"
	}
	return Node{ID: id, Type: "episode", Tier: "short", Status: "active", Title: "Episode", Body: body}
}

// dedupeFixture wires the standard belief-pass scene: one entity subject linking
// one episode whose provenance is refs, plus the belief under test. It returns
// the pipeline and a function that runs one belief pass over the given ops.
func dedupeFixture(t *testing.T, bel Node, refs ...episodeRef) (*Vault, func(t *testing.T, ops ...beliefOpJSON)) {
	t.Helper()
	v, d := newTestVault(t), newTestDB(t)
	subjectID := bel.Subject
	epID := "ep_00000000000000000000000001"
	writeAndIndex(t, v, d, dedupeEpisodeNode(epID, refs...))
	writeAndIndex(t, v, d, beliefSubjectEntity(subjectID, epID))
	writeAndIndex(t, v, d, bel)

	var reply string
	gen := &fakeGen{reply: func(string) (string, error) { return reply, nil }}
	p := NewPipeline(d, v, gen, pipelineTestConfig(), t.Logf)

	return v, func(t *testing.T, ops ...beliefOpJSON) {
		t.Helper()
		reply = opsJSON(t, ops...)
		_, _, _, _, err := p.ReviseBeliefs(context.Background(), []string{subjectID}, nil, 20, beliefNow)
		require.NoError(t, err)
	}
}

// beliefCommitCount counts the memory(beliefs) commits in the vault history —
// zero proves the op produced no vault write at all.
func beliefCommitCount(t *testing.T, v *Vault) int {
	t.Helper()
	commits, err := v.LogMemoryCommits(time.Time{})
	require.NoError(t, err)
	n := 0
	for _, c := range commits {
		if c.Op == "beliefs" {
			n++
		}
	}
	return n
}

const dedupeSubject = "ent_00000000000000000000000001"

// dedupeTS renders a provenance ts that is daysAgo old with the given fraction —
// the fraction distinguishes two refs of identical AGE, so a test can compare
// evidence weights without decay noise.
func dedupeTS(daysAgo int, frac string) string {
	return fmt.Sprintf("%d.%s", beliefNow.AddDate(0, 0, -daysAgo).Unix(), frac)
}

// A confirm whose every cited ref is already an ## Evidence line changes
// nothing: no stability, no confidence, no body edit, no vault commit, no
// ## History line. This is the calcification fix — without it the same ref
// re-cited each daemon cycle bought confidence and stability forever.
func TestReviseBeliefsConfirmWithAlreadyRecordedEvidenceIsNoOp(t *testing.T) {
	ts := dedupeTS(5, "000100")
	bel := beliefTestNode("bel_00000000000000000000000001", "Alice is reliable", dedupeSubject, 0.5, 2, "active",
		beliefEvidence{Rank: rankObserved, Support: true, ChannelID: "C1CHAN", TS: ts})
	v, run := dedupeFixture(t, bel, episodeRef{ChannelID: "C1CHAN", TS: ts})

	run(t, beliefOpJSON{BeliefID: bel.ID, Op: "confirm",
		Evidence: []episodeRef{{ChannelID: "C1CHAN", TS: ts}}, Rationale: "same message again"})

	got, err := v.ReadNode(bel.ID)
	require.NoError(t, err)
	assert.Equal(t, 0.5, got.Confidence, "a re-cited ref buys no confidence")
	assert.Equal(t, 2, got.Stability, "a re-cited ref buys no stability")
	assert.Equal(t, bel.Body, got.Body, "body byte-identical: no evidence line, no ## History line")
	assert.Zero(t, beliefCommitCount(t, v), "no vault commit — so reflection sees no churn")
}

// The no-op rule is ALL cited refs already stored, never ANY: an op carrying one
// new ref is genuinely new evidence and applies in full, appending exactly the
// one new line.
func TestReviseBeliefsConfirmWithOneNewRefStillApplies(t *testing.T) {
	stored := dedupeTS(5, "000100")
	fresh := dedupeTS(4, "000200")
	bel := beliefTestNode("bel_00000000000000000000000001", "Alice is reliable", dedupeSubject, 0.5, 2, "active",
		beliefEvidence{Rank: rankObserved, Support: true, ChannelID: "C1CHAN", TS: stored})
	v, run := dedupeFixture(t, bel,
		episodeRef{ChannelID: "C1CHAN", TS: stored},
		episodeRef{ChannelID: "C1CHAN", TS: fresh})

	run(t, beliefOpJSON{BeliefID: bel.ID, Op: "confirm", Evidence: []episodeRef{
		{ChannelID: "C1CHAN", TS: stored}, // already recorded
		{ChannelID: "C1CHAN", TS: fresh},  // new
	}, Rationale: "one old, one new"})

	got, err := v.ReadNode(bel.ID)
	require.NoError(t, err)
	assert.InDelta(t, 0.6, got.Confidence, 1e-9, "partly-new evidence still confirms")
	assert.Equal(t, 3, got.Stability)
	assert.Equal(t, 1, countEvidenceRef(got.Body, "C1CHAN "+stored), "the stored ref is not duplicated")
	assert.Equal(t, 1, countEvidenceRef(got.Body, "C1CHAN "+fresh), "the new ref is appended once")
	assert.Equal(t, 1, beliefCommitCount(t, v))
}

// countEvidenceRef counts the canonical ## Evidence lines ending in ref.
func countEvidenceRef(body, ref string) int {
	n := 0
	for _, e := range parseBeliefEvidence(body, func(string, ...any) {}) {
		if e.ChannelID+" "+e.TS == ref {
			n++
		}
	}
	return n
}

// Direction is part of the key: the same message stored as evidence AGAINST the
// belief does not suppress a confirm citing it FOR the belief — the model
// re-read that message and now reads it as supporting, which is a new data point.
func TestConfirmDedupeKeyIncludesDirection(t *testing.T) {
	ts := dedupeTS(5, "000100")
	bel := beliefTestNode("bel_00000000000000000000000001", "Alice is reliable", dedupeSubject, 0.5, 1, "active",
		beliefEvidence{Rank: rankObserved, Support: false, ChannelID: "C1CHAN", TS: ts})
	v, run := dedupeFixture(t, bel, episodeRef{ChannelID: "C1CHAN", TS: ts})

	run(t, beliefOpJSON{BeliefID: bel.ID, Op: "confirm",
		Evidence: []episodeRef{{ChannelID: "C1CHAN", TS: ts}}, Rationale: "reads as support after all"})

	got, err := v.ReadNode(bel.ID)
	require.NoError(t, err)
	assert.Equal(t, 2, got.Stability, "an opposite-direction line is a distinct data point — the confirm applies")
	assert.Contains(t, got.Body, "- observed for C1CHAN "+ts, "the supporting line is appended")
	assert.Contains(t, got.Body, "- observed against C1CHAN "+ts, "the stored against line is untouched")
}

// Rank is part of the key: a stored owner-rank line never swallows an incoming
// observed line for the same message. (Rank is a deterministic function of the
// ref scheme today, so this cannot normally happen — but a key that dropped rank
// could silently lose a line of a different trust level.)
func TestConfirmDedupeKeyIncludesRank(t *testing.T) {
	ts := dedupeTS(5, "000100")
	bel := beliefTestNode("bel_00000000000000000000000001", "Alice is reliable", dedupeSubject, 0.5, 1, "active",
		beliefEvidence{Rank: rankOwner, Support: true, ChannelID: "C1CHAN", TS: ts})
	v, run := dedupeFixture(t, bel, episodeRef{ChannelID: "C1CHAN", TS: ts})

	run(t, beliefOpJSON{BeliefID: bel.ID, Op: "confirm",
		Evidence: []episodeRef{{ChannelID: "C1CHAN", TS: ts}}, Rationale: "observed too"})

	got, err := v.ReadNode(bel.ID)
	require.NoError(t, err)
	assert.Equal(t, 2, got.Stability, "a different rank is a different line — the confirm applies")
	assert.Contains(t, got.Body, "- observed for C1CHAN "+ts)
	assert.Contains(t, got.Body, "- owner for C1CHAN "+ts, "the owner line stays (MEM-06 protection intact)")
}

// The key is compared field-exact, never by prefix or substring: a stored ref
// that is a prefix of the incoming one (in the channel id or in the ts) does not
// suppress it.
func TestConfirmDedupeKeyIsFieldExactNotPrefix(t *testing.T) {
	t.Run("channel id prefix", func(t *testing.T) {
		ts := dedupeTS(5, "000100")
		bel := beliefTestNode("bel_00000000000000000000000001", "Alice is reliable", dedupeSubject, 0.5, 1, "active",
			beliefEvidence{Rank: rankObserved, Support: true, ChannelID: "C1", TS: ts})
		v, run := dedupeFixture(t, bel, episodeRef{ChannelID: "C1CHAN", TS: ts})

		run(t, beliefOpJSON{BeliefID: bel.ID, Op: "confirm",
			Evidence: []episodeRef{{ChannelID: "C1CHAN", TS: ts}}, Rationale: "a different channel"})

		got, err := v.ReadNode(bel.ID)
		require.NoError(t, err)
		assert.Equal(t, 2, got.Stability, "C1 must not swallow C1CHAN")
		assert.Contains(t, got.Body, "- observed for C1CHAN "+ts)
	})

	t.Run("ts prefix", func(t *testing.T) {
		stored := dedupeTS(5, "000100")
		incoming := stored + "1" // "…000100" vs "…0001001"
		bel := beliefTestNode("bel_00000000000000000000000001", "Alice is reliable", dedupeSubject, 0.5, 1, "active",
			beliefEvidence{Rank: rankObserved, Support: true, ChannelID: "C1CHAN", TS: stored})
		v, run := dedupeFixture(t, bel, episodeRef{ChannelID: "C1CHAN", TS: incoming})

		run(t, beliefOpJSON{BeliefID: bel.ID, Op: "confirm",
			Evidence: []episodeRef{{ChannelID: "C1CHAN", TS: incoming}}, Rationale: "a different message"})

		got, err := v.ReadNode(bel.ID)
		require.NoError(t, err)
		assert.Equal(t, 2, got.Stability, "a ts prefix must not swallow a longer ts")
		assert.Contains(t, got.Body, "- observed for C1CHAN "+incoming)
	})
}

// Fail open: an ## Evidence bullet the canonical parser cannot read is absent
// from the dedupe set, so a matching incoming ref counts as new and the confirm
// applies. The malformed bullet here CONTAINS the incoming line as a substring —
// a body-text scan would wrongly suppress the op.
func TestReviseBeliefsMalformedEvidenceDoesNotSuppressConfirm(t *testing.T) {
	ts := dedupeTS(5, "000100")
	bel := Node{
		ID: "bel_00000000000000000000000001", Type: "belief", Tier: "long", Status: "active",
		Confidence: 0.5, Stability: 1, Subject: dedupeSubject, Title: "Alice is reliable",
		// Five fields, so parseBeliefEvidence logs and skips it — while the
		// canonical four-field line is a literal substring of it.
		Body: "# Alice is reliable\n\n## Evidence\n- observed for C1CHAN " + ts + " (per Bob)\n\n## History\n- 2026-01-01: seeded\n",
	}
	v, run := dedupeFixture(t, bel, episodeRef{ChannelID: "C1CHAN", TS: ts})

	run(t, beliefOpJSON{BeliefID: bel.ID, Op: "confirm",
		Evidence: []episodeRef{{ChannelID: "C1CHAN", TS: ts}}, Rationale: "recorded properly this time"})

	got, err := v.ReadNode(bel.ID)
	require.NoError(t, err)
	assert.Equal(t, 2, got.Stability, "unparseable evidence suppresses nothing — the confirm applies")
	assert.InDelta(t, 0.6, got.Confidence, 1e-9)
	assert.Contains(t, got.Body, "- observed for C1CHAN "+ts+"\n", "the canonical line is now recorded")
}

// The second half of the fix: a ref the belief already records is no longer
// weighed twice when the model re-cites it. The belief below carries one
// supporting and one opposing observation of identical age, and stability 2
// demands an against/for ratio of 2.0 to retire. Re-citing the stored against
// ref used to double its weight (ratio 2.0 → retired); counted once it is 1.0,
// so the retire is downgraded to shaken as the hysteresis intends.
func TestRetireEvidenceNotDoubleWeighted(t *testing.T) {
	tsFor := dedupeTS(5, "000100")
	tsAgainst := dedupeTS(5, "000200") // same age → same decay, so the ratio is exact
	bel := beliefTestNode("bel_00000000000000000000000001", "Deploys are stable", dedupeSubject, 0.7, 2, "active",
		beliefEvidence{Rank: rankObserved, Support: true, ChannelID: "C1CHAN", TS: tsFor},
		beliefEvidence{Rank: rankObserved, Support: false, ChannelID: "C1CHAN", TS: tsAgainst})
	v, run := dedupeFixture(t, bel,
		episodeRef{ChannelID: "C1CHAN", TS: tsFor},
		episodeRef{ChannelID: "C1CHAN", TS: tsAgainst})

	run(t, beliefOpJSON{BeliefID: bel.ID, Op: "retire",
		Evidence: []episodeRef{{ChannelID: "C1CHAN", TS: tsAgainst}}, Rationale: "the same bad deploy, again"})

	got, err := v.ReadNode(bel.ID)
	require.NoError(t, err)
	assert.Equal(t, "shaken", got.Status, "a re-cited against ref must not double its weight into a flip")
	assert.NotEqual(t, "retired", got.Status)
	assert.Equal(t, 1, countEvidenceRef(got.Body, "C1CHAN "+tsAgainst), "and it is not stored twice")
}

// A retire with genuinely new against-evidence still flips: the dedupe removes
// double counting, it does not blunt real contradiction. (The control for the
// test above — same belief, same threshold, a second distinct against ref.)
func TestRetireStillFlipsOnDistinctAgainstEvidence(t *testing.T) {
	tsFor := dedupeTS(5, "000100")
	tsAgainst := dedupeTS(5, "000200")
	tsAgainst2 := dedupeTS(5, "000300")
	bel := beliefTestNode("bel_00000000000000000000000001", "Deploys are stable", dedupeSubject, 0.7, 2, "active",
		beliefEvidence{Rank: rankObserved, Support: true, ChannelID: "C1CHAN", TS: tsFor},
		beliefEvidence{Rank: rankObserved, Support: false, ChannelID: "C1CHAN", TS: tsAgainst})
	v, run := dedupeFixture(t, bel,
		episodeRef{ChannelID: "C1CHAN", TS: tsFor},
		episodeRef{ChannelID: "C1CHAN", TS: tsAgainst},
		episodeRef{ChannelID: "C1CHAN", TS: tsAgainst2})

	run(t, beliefOpJSON{BeliefID: bel.ID, Op: "retire", Evidence: []episodeRef{
		{ChannelID: "C1CHAN", TS: tsAgainst},  // already recorded — weighs once
		{ChannelID: "C1CHAN", TS: tsAgainst2}, // genuinely new
	}, Rationale: "two distinct bad deploys"})

	got, err := v.ReadNode(bel.ID)
	require.NoError(t, err)
	assert.Equal(t, "retired", got.Status, "two distinct against refs meet the stability-2 threshold")
}

// filterNewEvidence collapses duplicates within one op too, so what the math
// weighs matches what lands in the body (appendToSection writes an identical
// line only once).
func TestFilterNewEvidenceCollapsesDuplicatesWithinOneOp(t *testing.T) {
	e := beliefEvidence{Rank: rankObserved, Support: true, ChannelID: "C1CHAN", TS: "100.000100"}
	other := beliefEvidence{Rank: rankObserved, Support: true, ChannelID: "C2CHAN", TS: "100.000100"}

	fresh := filterNewEvidence([]beliefEvidence{e, e, other}, nil)
	require.Len(t, fresh, 2, "the repeated line is weighed once")
	assert.Equal(t, e, fresh[0])
	assert.Equal(t, other, fresh[1])

	assert.Empty(t, filterNewEvidence([]beliefEvidence{e, e}, []beliefEvidence{e}))
}
