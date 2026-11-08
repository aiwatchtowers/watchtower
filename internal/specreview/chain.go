package specreview

import (
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strings"

	"watchtower/internal/db"
)

// The review chain of one document is the asks linked by previous_ask_id
// (spec 2026-11-08-spec-review-discuss-design §1). What carries along it is
// the closed list: findings that never come back.

// ClosedItem is a finding closed earlier in the chain: its key, kind (an
// AuthorItem kind; "" when no earlier round says) and where-quote ("" when it
// has no anchor in the document).
type ClosedItem struct {
	Key, Kind, WhereQuote string
}

// markOK is the owner's ok mark: Skip, Checked and, on a disputed ledger
// entry, Author is right. With db.SpecReviewMarkNotUseful it closes a finding.
const markOK = "ok"

// markComment is the owner's comment mark (Fix included): it reopens a
// finding closed earlier in the chain.
const markComment = "comment"

// closedKindAsAgreed is the closed-list kind of an agreement the reviewer
// found as agreed: dismissing it (Skip, Not useful) says nothing about a
// later differs/missing finding on the same passage, so its where-quote
// never matches one (owner ruling on the Discuss branch review).
const closedKindAsAgreed = "agreement_as_agreed"

// ClosedList is the closed list of askID's review: over every earlier ask of
// its chain, the ledger entries resolved after a fixed reply (or none), and
// every key the owner marked ok (Skip, Checked, Author is right on a
// disputed entry) or Not useful. A comment mark (Fix) on a later or the
// same ask reopens a key: it leaves the list until something closes it
// again. A key is listed once, in the order it was (last) closed. A
// row whose stored JSON does not decode is an error (BuildInputs notes it
// instead).
func ClosedList(d *db.DB, askID int64) ([]ClosedItem, error) {
	c, notes, err := readChain(d, askID)
	if err != nil {
		return nil, err
	}
	if len(notes) > 0 {
		return nil, errors.New(strings.Join(notes, "; "))
	}
	return c.closed, nil
}

// chainState is what the earlier asks of a chain hand the next round.
type chainState struct {
	closed []ClosedItem
	// known is every key in a ledger or an open list along the chain.
	known map[string]bool
}

// readChain reads every earlier ask of askID's chain. A row whose JSON does
// not decode adds a note and gives what it can; only a database error fails.
func readChain(d *db.DB, askID int64) (chainState, []string, error) {
	st := chainState{known: map[string]bool{}}
	ids, err := d.SpecReviewChain(askID)
	if err != nil {
		return st, nil, err
	}
	if len(ids) > 0 && ids[len(ids)-1] == askID {
		ids = ids[:len(ids)-1]
	}
	var notes []string
	info := map[string]ClosedItem{}
	// learn keeps the latest kind and where-quote known for a key: the
	// chain is read root first, so a later round's anchor wins.
	learn := func(key, kind string, where *Anchor) {
		if key == "" {
			return
		}
		it := info[key]
		it.Key = key
		if kind != "" {
			it.Kind = kind
		}
		if where != nil {
			it.WhereQuote = where.Quote
		}
		info[key] = it
	}
	type rowClose struct {
		ledger   []string // ledger keys resolved after fixed
		marks    []string // keys marked ok or not useful
		reopened []string // keys with a comment mark
	}
	var rows []rowClose
	for _, id := range ids {
		var rc rowClose
		row, err := d.GetSpecReview(id)
		switch {
		case errors.Is(err, db.ErrSpecReviewNotFound):
		case err != nil:
			return st, nil, err
		default:
			ledger, open, err := decodeLoop(row)
			if err != nil {
				notes = append(notes, fmt.Sprintf("the closed list of ask #%d left out: %v", id, err))
			}
			for _, e := range ledger {
				st.known[e.Key] = true
				learn(e.Key, e.Kind, e.Where)
				if e.Verdict == VerdictResolved && (e.Reply == nil || e.Reply.Reply == ReplyFixed) {
					rc.ledger = append(rc.ledger, e.Key)
				}
			}
			for _, it := range open {
				st.known[it.Key] = true
				learn(it.Key, it.Kind, it.Where)
			}
			if row.Result != "" {
				var r Result
				if err := json.Unmarshal([]byte(row.Result), &r); err != nil {
					notes = append(notes, fmt.Sprintf("the findings of ask #%d left out of the closed list: %v", id, err))
				} else {
					learnResult(r, learn)
				}
			}
		}
		threads, err := d.ListSpecReviewThreadFindings(id)
		if err != nil {
			return st, nil, err
		}
		for _, tf := range threads {
			var f threadFindingJSON
			if err := json.Unmarshal([]byte(tf.Finding), &f); err != nil {
				notes = append(notes, fmt.Sprintf("thread finding %s of ask #%d left out of the closed list: %v", tf.ItemKey, id, err))
				continue
			}
			learn(tf.ItemKey, threadKinds[f.Kind], f.Where)
		}
		marks, err := d.ListSpecReviewMarks(id)
		if err != nil {
			return st, nil, err
		}
		for key, m := range marks {
			switch m.State {
			case markOK, db.SpecReviewMarkNotUseful:
				rc.marks = append(rc.marks, key)
			case markComment:
				rc.reopened = append(rc.reopened, key)
			}
		}
		slices.Sort(rc.marks)
		rows = append(rows, rc)
	}
	var order []string
	closed := map[string]bool{}
	for _, rc := range rows {
		for _, key := range slices.Concat(rc.ledger, rc.marks) {
			if !closed[key] {
				closed[key] = true
				order = append(order, key)
			}
		}
		for _, key := range rc.reopened {
			if closed[key] {
				delete(closed, key)
				order = slices.DeleteFunc(order, func(k string) bool { return k == key })
			}
		}
	}
	for _, key := range order {
		it, ok := info[key]
		if !ok {
			it = ClosedItem{Key: key}
		}
		st.closed = append(st.closed, it)
	}
	return st, notes, nil
}

// learnResult hands learn the kind and anchor of every finding of r, an
// agreement as agreed (closedKindAsAgreed) and a check without a concern
// included (the owner may mark those too).
func learnResult(r Result, learn func(key, kind string, where *Anchor)) {
	for _, a := range r.Agreements {
		kind := KindAgreement
		if a.Status == "as_agreed" {
			kind = closedKindAsAgreed
		}
		learn(a.Key, kind, a.Where)
	}
	for _, x := range r.DecidedAlone {
		learn(x.Key, KindDecidedAlone, &x.Where)
	}
	for _, b := range r.BlindSpots {
		learn(b.Key, KindBlindSpot, b.Where)
	}
	for _, c := range r.Checks {
		learn(c.Key, KindCheck, nil)
	}
}
