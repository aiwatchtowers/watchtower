package specreview

import (
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"watchtower/internal/db"
)

// The author loop (spec 2026-10-26-spec-review-author-loop-design §2–§5): a
// spec or plan review ask stays hidden while the reviewer and the author
// settle the findings; the owner sees one ask when the loop ends. The JSON of
// AuthorItem and LedgerEntry is what spec_reviews.open_items / ledger hold and
// what the Desktop and `spec-review show --json` decode.

// MaxLoopRounds is the reviewer rounds per loop: round 1 on the first
// version, rounds 2 and 3 on the author's fixes.
const MaxLoopRounds = 3

// AuthorTimeout is how long the author has to answer a delivered round.
const AuthorTimeout = 30 * time.Minute

// Loop end reasons (spec_reviews.loop_end).
const (
	EndSettled        = "settled"
	EndCap            = "cap"
	EndReviewerFailed = "reviewer_failed"
	EndSessionGone    = "session_gone"
	EndTimeout        = "timeout"
	// EndOwner: the owner pressed Show Now before the loop finished.
	EndOwner = "owner"
)

// Item kinds of an AuthorItem.
const (
	KindAgreement    = "agreement"
	KindDecidedAlone = "decided_alone"
	KindBlindSpot    = "blind_spot"
	KindCheck        = "check"
)

// Author replies and reviewer verdicts.
const (
	ReplyFixed    = "fixed"
	ReplyDisagree = "disagree"

	VerdictResolved  = "resolved"
	VerdictDisputed  = "disputed"
	VerdictOpen      = "open"
	VerdictUnsettled = "unsettled" // ledger only: the loop ended before it settled
)

// noAnswerNote is an unsettled item's note when the author gave no reason.
const noAnswerNote = "The author did not answer"

// ownerEarlyNote is an unsettled item's note when the owner pressed Show Now
// before the author answered it.
const ownerEarlyNote = "You opened the review before the author answered"

// Reply is the author's answer to one finding: fixed (Note: what changed,
// optional) or disagree (Note: the reason).
type Reply struct {
	Key   string `json:"key"`
	Reply string `json:"reply"`
	Note  string `json:"note"`
}

// Verdict is the reviewer's word on one previous open item: resolved,
// disputed or open.
type Verdict struct {
	Key     string `json:"key"`
	Verdict string `json:"verdict"`
	Note    string `json:"note"`
}

// AuthorItem is one finding handed to the author. Round is the round that
// raised it; Reply is the author's last reply once it is carried over. Where
// is nil when the finding has no anchor in the document.
type AuthorItem struct {
	Key   string  `json:"key"`
	Kind  string  `json:"kind"`
	Text  string  `json:"text"`
	Note  string  `json:"note"`
	Where *Anchor `json:"where,omitempty"`
	Round int     `json:"round"`
	Reply *Reply  `json:"reply,omitempty"`
}

// LedgerEntry is a finding that left the author's list: resolved, disputed
// or unsettled (VerdictNote then says why). Settled is the round it entered
// the ledger.
type LedgerEntry struct {
	AuthorItem
	Verdict     string `json:"verdict"`
	VerdictNote string `json:"verdict_note"`
	Settled     int    `json:"settled"`
}

// Findings is what a round hands the author: agreements that differ or are
// missing, everything decided alone, every blind spot and every check with a
// concern, raised in round.
func Findings(r Result, round int) []AuthorItem {
	out := []AuthorItem{}
	for _, a := range r.Agreements {
		if a.Status != "as_agreed" {
			out = append(out, AuthorItem{Key: a.Key, Kind: KindAgreement, Text: a.Text, Note: a.Note, Where: copyAnchor(a.Where), Round: round})
		}
	}
	for _, d := range r.DecidedAlone {
		out = append(out, AuthorItem{Key: d.Key, Kind: KindDecidedAlone, Text: d.Text, Note: d.Note, Where: copyAnchor(&d.Where), Round: round})
	}
	for _, b := range r.BlindSpots {
		out = append(out, AuthorItem{Key: b.Key, Kind: KindBlindSpot, Text: b.Text, Note: b.Why, Where: copyAnchor(b.Where), Round: round})
	}
	for _, c := range r.Checks {
		if c.Answer == "concern" {
			out = append(out, AuthorItem{Key: c.Key, Kind: KindCheck, Text: c.Question, Note: c.Note, Round: round})
		}
	}
	return out
}

func copyAnchor(a *Anchor) *Anchor {
	if a == nil {
		return nil
	}
	c := *a
	return &c
}

// RoundOutcome is a round's result for the loop: the author's open items, the
// ledger so far, and End ("" while the loop goes on, else settled or cap).
type RoundOutcome struct {
	Open   []AuthorItem
	Ledger []LedgerEntry
	End    string
}

// NextRound applies round's reviewer result r to the previous round's open
// items and ledger, given the author's replies. Round 1 opens r's findings.
// From round 2: a missing reply counts as fixed; resolved settles the item,
// disputed after a disagree settles it as disputed, anything else (disputed
// after fixed, open, no verdict) keeps it open with the reply. New findings
// skip every key already known. Nothing open ends the loop as settled; at
// MaxLoopRounds what is still open moves to the ledger as unsettled (cap).
func NextRound(round int, prevOpen []AuthorItem, prevLedger []LedgerEntry, replies []Reply, r Result) RoundOutcome {
	ledger := append([]LedgerEntry{}, prevLedger...)
	open := []AuthorItem{}
	if round <= 1 {
		open = Findings(r, 1)
	} else {
		replyOf := map[string]Reply{}
		for _, rp := range replies {
			replyOf[rp.Key] = rp
		}
		verdictOf := map[string]Verdict{}
		for _, v := range r.Verdicts {
			verdictOf[v.Key] = v
		}
		known := map[string]bool{}
		for _, e := range prevLedger {
			known[e.Key] = true
		}
		for _, it := range prevOpen {
			known[it.Key] = true
			rp, ok := replyOf[it.Key]
			if !ok {
				rp = Reply{Key: it.Key, Reply: ReplyFixed}
			}
			it.Reply = &rp
			v, hasVerdict := verdictOf[it.Key]
			switch {
			case hasVerdict && v.Verdict == VerdictResolved,
				hasVerdict && v.Verdict == VerdictDisputed && rp.Reply == ReplyDisagree:
				ledger = append(ledger, LedgerEntry{AuthorItem: it, Verdict: v.Verdict, VerdictNote: v.Note, Settled: round})
			default:
				open = append(open, it)
			}
		}
		for _, f := range Findings(r, round) {
			if !known[f.Key] {
				known[f.Key] = true
				open = append(open, f)
			}
		}
	}
	switch {
	case len(open) == 0:
		return RoundOutcome{Open: open, Ledger: ledger, End: EndSettled}
	case round >= MaxLoopRounds:
		note := fmt.Sprintf("Not settled in %d rounds", MaxLoopRounds)
		for _, it := range open {
			ledger = append(ledger, LedgerEntry{AuthorItem: it, Verdict: VerdictUnsettled, VerdictNote: note, Settled: round})
		}
		return RoundOutcome{Open: []AuthorItem{}, Ledger: ledger, End: EndCap}
	}
	return RoundOutcome{Open: open, Ledger: ledger}
}

// Reveal ends askID's author loop early with reason end: the ledger becomes
// the last finished round's ledger plus its open items as unsettled. A done
// row is that round; any other row (failed, skipped, queued, running) falls
// back to the previous ask's row, whose open items this row's replies
// answered (a missing reply counts as fixed). An item the author disagreed
// with keeps the reason; an item the author said it fixed in a round the
// reviewer never finished was not checked, so its note says so; any other
// item was not answered. A row not in
// the author loop is left as it is.
func Reveal(d *db.DB, askID int64, end string, now time.Time) error {
	row, err := d.GetSpecReview(askID)
	if err != nil {
		return err
	}
	if row.Loop != "author" {
		return nil
	}
	var ledger []LedgerEntry
	var open []AuthorItem
	replyOf := map[string]Reply{}
	if row.Status == "done" {
		if ledger, open, err = decodeLoop(row); err != nil {
			return err
		}
	} else {
		prev, err := previousRow(d, askID)
		if err != nil {
			return err
		}
		if prev == nil && end == EndOwner {
			// Show Now on a first round the reviewer has not finished: no
			// loop to show yet, so the ask becomes a plain review and its
			// findings land on the findings screen.
			_, err = d.LeaveSpecLoop(askID, end)
			return err
		}
		if prev != nil {
			if ledger, open, err = decodeLoop(prev); err != nil {
				return err
			}
			replies, err := decodeReplies(row.Replies)
			if err != nil {
				return err
			}
			for _, rp := range replies {
				replyOf[rp.Key] = rp
			}
		}
	}
	for _, it := range open {
		if row.Status != "done" {
			// This row's round was filed with replies to these items; a
			// missing one counts as fixed, as in NextRound.
			rp, ok := replyOf[it.Key]
			if !ok {
				rp = Reply{Key: it.Key, Reply: ReplyFixed}
			}
			it.Reply = &rp
		}
		note := noAnswerNote
		if end == EndOwner {
			note = ownerEarlyNote
		}
		switch {
		case it.Reply != nil && it.Reply.Reply == ReplyDisagree:
			note = it.Reply.Note
		case row.Status != "done" && it.Reply != nil && it.Reply.Reply == ReplyFixed:
			note = uncheckedNote(end)
		}
		ledger = append(ledger, LedgerEntry{AuthorItem: it, Verdict: VerdictUnsettled, VerdictNote: note, Settled: row.Round})
	}
	js, err := encodeList(ledger)
	if err != nil {
		return err
	}
	_, err = d.RevealSpecLoop(askID, end, js, now)
	return err
}

// uncheckedNote is the note of a fix the reviewer never checked, by end reason.
func uncheckedNote(end string) string {
	switch end {
	case EndReviewerFailed:
		return "The fix was not checked: the reviewer failed"
	case EndSessionGone:
		return "The fix was not checked: the author's session ended"
	case EndOwner:
		return "The fix was not checked: you opened the review before it was"
	}
	return "The fix was not checked"
}

// previousRow is the review row of askID's previous ask; nil when the ask has
// none or that row is gone.
func previousRow(d *db.DB, askID int64) (*db.SpecReview, error) {
	ask, err := d.GetOwnerAskByID(askID)
	if err != nil {
		return nil, err
	}
	if !ask.PreviousAskID.Valid {
		return nil, nil
	}
	prev, err := d.GetSpecReview(ask.PreviousAskID.Int64)
	if errors.Is(err, db.ErrSpecReviewNotFound) {
		return nil, nil
	}
	return prev, err
}

// decodeLoop reads a row's ledger and open items ("" is empty).
func decodeLoop(row *db.SpecReview) ([]LedgerEntry, []AuthorItem, error) {
	var ledger []LedgerEntry
	var open []AuthorItem
	if err := decodeList(row.Ledger, &ledger); err != nil {
		return nil, nil, fmt.Errorf("spec review %d ledger: %w", row.AskID, err)
	}
	if err := decodeList(row.OpenItems, &open); err != nil {
		return nil, nil, fmt.Errorf("spec review %d open items: %w", row.AskID, err)
	}
	return ledger, open, nil
}

func decodeReplies(s string) ([]Reply, error) {
	var out []Reply
	if err := decodeList(s, &out); err != nil {
		return nil, fmt.Errorf("spec review replies: %w", err)
	}
	return out, nil
}

func decodeList(s string, into any) error {
	if s == "" {
		return nil
	}
	return json.Unmarshal([]byte(s), into)
}

// encodeList writes a loop column: "" for an empty list, else its JSON.
func encodeList[T any](list []T) (string, error) {
	if len(list) == 0 {
		return "", nil
	}
	js, err := json.Marshal(list)
	if err != nil {
		return "", fmt.Errorf("encoding spec loop: %w", err)
	}
	return string(js), nil
}
