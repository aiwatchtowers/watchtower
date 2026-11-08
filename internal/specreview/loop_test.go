package specreview

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// loopResult is a reviewer result with one finding of each kind that goes to
// the author, plus an as_agreed agreement and an ok check that do not.
func loopResult(verdicts ...Verdict) Result {
	return Result{
		Agreements: []Agreement{
			{Key: "ag:same", Text: "A mute lasts a day", Status: "as_agreed"},
			{Key: "ag:miss", Text: "Threads stay unmuted", Status: "missing", Note: "not in the doc"},
		},
		DecidedAlone: []DecidedAlone{{Key: "da:local", Text: "State is local", Where: Anchor{Heading: "Decisions", Quote: "lives in the local database"}}},
		BlindSpots:   []BlindSpot{{Key: "bs:threads", Text: "Muted threads", Why: "a mention stays silent"}},
		Checks: []Check{
			{Key: "ck:ok", Question: "Is it fine?", Answer: "ok"},
			{Key: "ck:expiry", Question: "Does every promise have a task?", Answer: "concern", Note: "Expiry has none."},
		},
		Verdicts: verdicts,
	}
}

func keysOfItems(items []AuthorItem) []string {
	out := []string{}
	for _, it := range items {
		out = append(out, it.Key)
	}
	return out
}

func item(key string, round int) AuthorItem {
	return AuthorItem{Key: key, Kind: KindBlindSpot, Text: "text of " + key, Round: round}
}

func TestNextRound_RoundOneOpensFindings(t *testing.T) {
	o := NextRound(1, 0, nil, nil, nil, loopResult())
	assert.Equal(t, []string{"ag:miss", "da:local", "bs:threads", "ck:expiry"}, keysOfItems(o.Open))
	assert.Empty(t, o.Ledger)
	assert.Equal(t, "", o.End)
	for _, it := range o.Open {
		assert.Equal(t, 1, it.Round)
		assert.Nil(t, it.Reply)
	}
	assert.Equal(t, KindAgreement, o.Open[0].Kind)
	assert.Nil(t, o.Open[0].Where, "a missing agreement has no anchor")
	require.NotNil(t, o.Open[1].Where)
	assert.Equal(t, "lives in the local database", o.Open[1].Where.Quote)
	assert.Equal(t, "a mention stays silent", o.Open[2].Note, "a blind spot's why is its note")
	assert.Equal(t, KindCheck, o.Open[3].Kind)
	assert.Equal(t, "Expiry has none.", o.Open[3].Note)
}

func TestNextRound_ResolvedAndDisputedSettle(t *testing.T) {
	prev := []AuthorItem{item("bs:a", 1), item("bs:b", 1)}
	replies := []Reply{{Key: "bs:a", Reply: ReplyFixed, Note: "named it"}, {Key: "bs:b", Reply: ReplyDisagree, Note: "out of scope"}}
	r := Result{Verdicts: []Verdict{{Key: "bs:a", Verdict: VerdictResolved, Note: "fixed"}, {Key: "bs:b", Verdict: VerdictDisputed, Note: "it matters"}}}
	o := NextRound(2, 0, prev, nil, replies, r)
	assert.Empty(t, o.Open)
	assert.Equal(t, EndSettled, o.End)
	require.Len(t, o.Ledger, 2)
	assert.Equal(t, VerdictResolved, o.Ledger[0].Verdict)
	assert.Equal(t, 2, o.Ledger[0].Settled)
	require.NotNil(t, o.Ledger[0].Reply)
	assert.Equal(t, "named it", o.Ledger[0].Reply.Note)
	assert.Equal(t, VerdictDisputed, o.Ledger[1].Verdict)
	assert.Equal(t, "it matters", o.Ledger[1].VerdictNote)
	assert.Equal(t, ReplyDisagree, o.Ledger[1].Reply.Reply)
}

func TestNextRound_DisputedAfterFixedStaysOpen(t *testing.T) {
	prev := []AuthorItem{item("bs:a", 1)}
	replies := []Reply{{Key: "bs:a", Reply: ReplyFixed, Note: "done"}}
	for _, v := range []string{VerdictDisputed, VerdictOpen} {
		o := NextRound(2, 0, prev, nil, replies, Result{Verdicts: []Verdict{{Key: "bs:a", Verdict: v}}})
		require.Len(t, o.Open, 1, v)
		assert.Equal(t, "done", o.Open[0].Reply.Note, "the reply is carried")
		assert.Equal(t, 1, o.Open[0].Round, "the raising round is kept")
		assert.Empty(t, o.Ledger)
		assert.Equal(t, "", o.End)
	}
}

func TestNextRound_MissingVerdictStaysOpen(t *testing.T) {
	prev := []AuthorItem{item("bs:a", 1), item("bs:b", 1)}
	replies := []Reply{{Key: "bs:a", Reply: ReplyDisagree, Note: "no"}, {Key: "bs:b", Reply: ReplyFixed}}
	o := NextRound(2, 0, prev, nil, replies, Result{})
	assert.Equal(t, []string{"bs:a", "bs:b"}, keysOfItems(o.Open))
	assert.Equal(t, ReplyDisagree, o.Open[0].Reply.Reply)
	assert.Empty(t, o.Ledger)
}

func TestNextRound_MissingReplyIsFixed(t *testing.T) {
	prev := []AuthorItem{item("bs:a", 1), item("bs:b", 1)}
	r := Result{Verdicts: []Verdict{{Key: "bs:a", Verdict: VerdictResolved}, {Key: "bs:b", Verdict: VerdictDisputed}}}
	o := NextRound(2, 0, prev, nil, nil, r)
	require.Len(t, o.Ledger, 1)
	assert.Equal(t, "bs:a", o.Ledger[0].Key)
	assert.Equal(t, &Reply{Key: "bs:a", Reply: ReplyFixed}, o.Ledger[0].Reply)
	require.Len(t, o.Open, 1, "disputed after an implicit fixed stays open")
	assert.Equal(t, &Reply{Key: "bs:b", Reply: ReplyFixed}, o.Open[0].Reply)
}

func TestNextRound_NewFindingsSkipKnownKeys(t *testing.T) {
	prev := []AuthorItem{item("bs:threads", 1)}
	ledger := []LedgerEntry{{AuthorItem: item("da:local", 1), Verdict: VerdictResolved, Settled: 1}}
	o := NextRound(2, 0, prev, ledger, nil, loopResult())
	assert.Equal(t, []string{"bs:threads", "ag:miss", "ck:expiry"}, keysOfItems(o.Open))
	assert.Equal(t, 1, o.Open[0].Round)
	assert.Equal(t, 2, o.Open[1].Round, "a new finding carries the round that raised it")
	assert.Nil(t, o.Open[1].Reply)
	assert.Equal(t, ledger, o.Ledger, "the previous ledger is kept")
}

func TestNextRound_SettledWhenNothingOpen(t *testing.T) {
	o := NextRound(1, 0, nil, nil, nil, Result{Agreements: []Agreement{{Key: "ag:x", Status: "as_agreed"}}})
	assert.Empty(t, o.Open)
	assert.NotNil(t, o.Open)
	assert.Equal(t, EndSettled, o.End)

	prev := []AuthorItem{item("bs:a", 1)}
	o = NextRound(2, 0, prev, nil, nil, Result{Verdicts: []Verdict{{Key: "bs:a", Verdict: VerdictResolved}}})
	assert.Equal(t, EndSettled, o.End)
}

func TestNextRound_CapMovesOpenToUnsettled(t *testing.T) {
	prev := []AuthorItem{item("bs:a", 1), item("bs:b", 2)}
	prevLedger := []LedgerEntry{{AuthorItem: item("bs:z", 1), Verdict: VerdictResolved, Settled: 2}}
	r := Result{
		Verdicts:   []Verdict{{Key: "bs:a", Verdict: VerdictResolved}, {Key: "bs:b", Verdict: VerdictOpen}},
		BlindSpots: []BlindSpot{{Key: "bs:new", Text: "a blocker"}},
	}
	o := NextRound(LegacyMaxLoopRounds, 0, prev, prevLedger, nil, r)
	assert.Equal(t, EndCap, o.End)
	assert.Empty(t, o.Open)
	require.Len(t, o.Ledger, 4)
	assert.Equal(t, "bs:z", o.Ledger[0].Key)
	assert.Equal(t, VerdictResolved, o.Ledger[1].Verdict)
	for _, e := range o.Ledger[2:] {
		assert.Equal(t, VerdictUnsettled, e.Verdict, e.Key)
		assert.Equal(t, "Not settled in 3 rounds", e.VerdictNote)
		assert.Equal(t, 3, e.Settled)
	}
	assert.Equal(t, []string{"bs:b", "bs:new"}, []string{o.Ledger[2].Key, o.Ledger[3].Key})

	// Below the cap, open items stay open.
	o = NextRound(2, 0, prev, nil, nil, r)
	assert.Equal(t, "", o.End)
	assert.Len(t, o.Open, 2)
}

func TestNextRound_ExplicitFixHeldContinues(t *testing.T) {
	prev := []AuthorItem{item("bs:a", 1), item("bs:b", 1)}
	replies := []Reply{{Key: "bs:a", Reply: ReplyFixed, Note: "named it"}, {Key: "bs:b", Reply: ReplyFixed}}
	r := Result{Verdicts: []Verdict{{Key: "bs:a", Verdict: VerdictResolved}, {Key: "bs:b", Verdict: VerdictOpen}}}
	o := NextRound(2, LoopRulesOpen, prev, nil, replies, r)
	assert.Equal(t, "", o.End, "a fix held, something is open: the loop goes on")
	assert.Equal(t, []string{"bs:b"}, keysOfItems(o.Open))
	require.Len(t, o.Ledger, 1)
	assert.Equal(t, VerdictResolved, o.Ledger[0].Verdict)
}

func TestNextRound_NoFixHeldStalls(t *testing.T) {
	prev := []AuthorItem{item("bs:a", 1), item("bs:b", 1), item("bs:c", 1)}
	replies := []Reply{
		{Key: "bs:a", Reply: ReplyDisagree, Note: "out of scope"},
		{Key: "bs:b", Reply: ReplyFixed, Note: "done"},
		{Key: "bs:c", Reply: ReplyDisagree, Note: "not our call"},
	}
	r := Result{Verdicts: []Verdict{
		{Key: "bs:a", Verdict: VerdictDisputed, Note: "it matters"},
		{Key: "bs:b", Verdict: VerdictOpen},
		{Key: "bs:c", Verdict: VerdictOpen},
	}}
	o := NextRound(2, LoopRulesOpen, prev, nil, replies, r)
	assert.Equal(t, EndStalled, o.End)
	assert.Empty(t, o.Open)
	assert.NotNil(t, o.Open)
	require.Len(t, o.Ledger, 3)
	assert.Equal(t, "bs:a", o.Ledger[0].Key)
	assert.Equal(t, VerdictDisputed, o.Ledger[0].Verdict, "a dispute settles as today")
	assert.Equal(t, "bs:b", o.Ledger[1].Key)
	assert.Equal(t, VerdictUnsettled, o.Ledger[1].Verdict)
	assert.Equal(t, "The reviewer and the author stopped making progress", o.Ledger[1].VerdictNote)
	assert.Equal(t, 2, o.Ledger[1].Settled)
	assert.Equal(t, "bs:c", o.Ledger[2].Key)
	assert.Equal(t, VerdictUnsettled, o.Ledger[2].Verdict)
	assert.Equal(t, "not our call", o.Ledger[2].VerdictNote, "a disagree left open keeps its reply note")
}

func TestNextRound_MissingReplyDoesNotKeepLoopGoing(t *testing.T) {
	prev := []AuthorItem{item("bs:a", 1), item("bs:b", 1)}
	r := Result{Verdicts: []Verdict{{Key: "bs:a", Verdict: VerdictResolved}}}
	o := NextRound(2, LoopRulesOpen, prev, nil, nil, r)
	assert.Equal(t, EndStalled, o.End, "an implicit fix does not count as progress")
	assert.Empty(t, o.Open)
	require.Len(t, o.Ledger, 2)
	assert.Equal(t, "bs:a", o.Ledger[0].Key)
	assert.Equal(t, VerdictResolved, o.Ledger[0].Verdict, "a missing reply still counts as fixed for the ledger")
	assert.Equal(t, &Reply{Key: "bs:a", Reply: ReplyFixed}, o.Ledger[0].Reply)
	assert.Equal(t, VerdictUnsettled, o.Ledger[1].Verdict)
}

func TestNextRound_Round1NeverStalls(t *testing.T) {
	o := NextRound(1, LoopRulesOpen, nil, nil, nil, loopResult())
	assert.Equal(t, "", o.End)
	assert.Len(t, o.Open, 4)
}

func TestNextRound_FuseAt8(t *testing.T) {
	prev := []AuthorItem{item("bs:a", 1), item("bs:b", 1)}
	replies := []Reply{{Key: "bs:a", Reply: ReplyFixed}, {Key: "bs:b", Reply: ReplyFixed}}
	r := Result{Verdicts: []Verdict{{Key: "bs:a", Verdict: VerdictResolved}, {Key: "bs:b", Verdict: VerdictOpen}}}
	assert.Equal(t, 8, MaxLoopRounds)
	o := NextRound(MaxLoopRounds, LoopRulesOpen, prev, nil, replies, r)
	assert.Equal(t, EndCap, o.End)
	assert.Empty(t, o.Open)
	require.Len(t, o.Ledger, 2)
	assert.Equal(t, VerdictUnsettled, o.Ledger[1].Verdict)
	assert.Equal(t, "Not settled in 8 rounds", o.Ledger[1].VerdictNote)
	assert.Equal(t, 8, o.Ledger[1].Settled)

	// Below the fuse the held fix keeps it going.
	o = NextRound(MaxLoopRounds-1, LoopRulesOpen, prev, nil, replies, r)
	assert.Equal(t, "", o.End)
}

func TestNextRound_LegacyRulesCapAt3(t *testing.T) {
	prev := []AuthorItem{item("bs:a", 1), item("bs:b", 1)}
	replies := []Reply{{Key: "bs:a", Reply: ReplyDisagree, Note: "no"}}
	r := Result{Verdicts: []Verdict{{Key: "bs:a", Verdict: VerdictOpen}, {Key: "bs:b", Verdict: VerdictOpen}}}

	o := NextRound(2, 0, prev, nil, replies, r)
	assert.Equal(t, "", o.End, "old rules never stall")
	assert.Len(t, o.Open, 2)

	o = NextRound(3, 0, prev, nil, replies, r)
	assert.Equal(t, EndCap, o.End)
	require.Len(t, o.Ledger, 2)
	for _, e := range o.Ledger {
		assert.Equal(t, "Not settled in 3 rounds", e.VerdictNote, e.Key)
	}
	assert.Equal(t, 3, MaxRoundsFor(0))
	assert.Equal(t, MaxLoopRounds, MaxRoundsFor(LoopRulesOpen))
}
