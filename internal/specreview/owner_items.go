package specreview

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"watchtower/internal/asks"
	"watchtower/internal/db"
)

// A new hidden loop after the owner's Request changes (spec
// 2026-11-08-spec-review-discuss-design §1, D8): its round 1 opens with the
// owner's items — every comment of the answer and every finding the owner
// added from a thread — so the reviewer checks the fixes the owner asked for
// before the owner sees the document again.

// KindOwnerComment is an owner's item with no finding behind it: a margin
// comment (or a comment whose finding is gone). Its Text is the comment.
const KindOwnerComment = "owner_comment"

// OwnerHas reports whether the owner already has this review: its loop ended,
// or Show Now turned a first round into a plain review (loop ”, loop_end
// owner).
func OwnerHas(row *db.SpecReview) bool {
	return row.Loop == "owner" || row.LoopEnd == EndOwner
}

// AnsweredChanges reports whether ask was answered with Request changes. An
// answer that does not decode is not Request changes, and says why.
func AnsweredChanges(ask *db.OwnerAsk) (bool, error) {
	if ask.Status != "answered" && ask.Status != "delivered" {
		return false, nil
	}
	a, err := asks.ParseAnswer([]byte(ask.Answer))
	if err != nil {
		return false, fmt.Errorf("the answer on ask #%d does not decode: %w", ask.ID, err)
	}
	return a.Verdict == asks.VerdictChanges, nil
}

// SeedOf is the owner's items that open round 1 of ask's loop: nil unless ask
// is round 1 of an author loop whose previous ask's review the owner had
// (OwnerHas) and answered with Request changes; then one item per comment of
// that answer (the key is the comment's ItemKey, else an "oc:" key of its
// body and quote; kind, text and severity are those of the key's finding —
// in the previous review's result, its ledger or open items, or the owner's
// thread findings —, else KindOwnerComment with the comment as the text; the
// owner's comment is the note; Where is the comment's heading and quote, else
// the finding's own anchor; a comment with no body and no finding behind it
// is left out),
// then every thread finding of the previous ask not already seeded and not
// on the closed list. A key the owner marked ok or Not useful on the
// previous ask is never seeded. Every item has Round 1 and Owner set. Only a
// database error fails: stored JSON that does not decode gives what it can
// (a comment then keeps the owner's words as an owner_comment) and adds a
// note, so the seed never keeps a loop from reaching the owner.
func SeedOf(d *db.DB, ask *db.OwnerAsk) ([]AuthorItem, []string, error) {
	if !ask.PreviousAskID.Valid {
		return nil, nil, nil
	}
	row, err := d.GetSpecReview(ask.ID)
	if errors.Is(err, db.ErrSpecReviewNotFound) {
		return nil, nil, nil
	}
	if err != nil {
		return nil, nil, fmt.Errorf("reading the review of ask #%d: %w", ask.ID, err)
	}
	if row.Loop != "author" || row.Round != 1 {
		return nil, nil, nil
	}
	prevAsk, err := d.GetOwnerAskByID(ask.PreviousAskID.Int64)
	if errors.Is(err, db.ErrAskNotFound) {
		return nil, nil, nil
	}
	if err != nil {
		return nil, nil, fmt.Errorf("reading the previous ask #%d: %w", ask.PreviousAskID.Int64, err)
	}
	prev, err := d.GetSpecReview(prevAsk.ID)
	if errors.Is(err, db.ErrSpecReviewNotFound) {
		return nil, nil, nil
	}
	if err != nil {
		return nil, nil, fmt.Errorf("reading the review of ask #%d: %w", prevAsk.ID, err)
	}
	if !OwnerHas(prev) {
		return nil, nil, nil
	}
	changes, aerr := AnsweredChanges(prevAsk)
	if aerr != nil {
		// Not Request changes: the loop opens without the owner's items.
		return nil, []string{"the owner's items left out: " + aerr.Error()}, nil //nolint:nilerr // reported as a note
	}
	if !changes {
		return nil, nil, nil
	}
	answer, _ := asks.ParseAnswer([]byte(prevAsk.Answer)) // AnsweredChanges parsed it
	marks, err := d.ListSpecReviewMarks(prevAsk.ID)
	if err != nil {
		return nil, nil, fmt.Errorf("reading the marks of ask #%d: %w", prevAsk.ID, err)
	}
	threads, err := d.ListSpecReviewThreadFindings(prevAsk.ID)
	if err != nil {
		return nil, nil, fmt.Errorf("reading the thread findings of ask #%d: %w", prevAsk.ID, err)
	}
	chain, _, err := readChain(d, ask.ID)
	if err != nil {
		return nil, nil, fmt.Errorf("reading the review chain of ask #%d: %w", ask.ID, err)
	}
	findings, notes := findingsOf(prev, threads)
	skipped := func(key string) bool {
		m, ok := marks[key]
		return ok && (m.State == markOK || m.State == db.SpecReviewMarkNotUseful)
	}

	seed := []AuthorItem{}
	at := map[string]int{}
	for _, c := range answer.Comments {
		key := strings.TrimSpace(c.ItemKey)
		if key == "" {
			key = itemKey("oc:", c.Body, c.Quote)
		}
		if skipped(key) {
			continue
		}
		body := strings.TrimSpace(c.Body)
		if i, ok := at[key]; ok {
			// Two comments on one finding: one item, both comments.
			seed[i].Note = strings.TrimSpace(seed[i].Note + "\n" + body)
			continue
		}
		it, ok := findings[key]
		switch {
		case ok:
			// An empty body is a plain Fix: fix it as the finding says.
			it.Note = body
		case body == "":
			continue // no finding and no words: nothing to check
		default:
			it = AuthorItem{Key: key, Kind: KindOwnerComment, Text: body}
		}
		it.Round, it.Owner = 1, true
		// The comment's quote anchors the item; without one a finding
		// keeps its own anchor.
		if q := strings.TrimSpace(c.Quote); q != "" {
			it.Where = &Anchor{Heading: c.Heading, Quote: c.Quote}
		}
		at[key] = len(seed)
		seed = append(seed, it)
	}
	closed := map[string]bool{}
	for _, c := range chain.closed {
		closed[c.Key] = true
	}
	for _, tf := range threads {
		it, ok := findings[tf.ItemKey]
		if _, seeded := at[tf.ItemKey]; !ok || seeded || closed[tf.ItemKey] || skipped(tf.ItemKey) {
			continue
		}
		it.Round, it.Owner = 1, true
		at[tf.ItemKey] = len(seed)
		seed = append(seed, it)
	}
	return seed, notes, nil
}

// threadFindingJSON is the part of a stored thread finding an owner's item
// needs.
type threadFindingJSON struct {
	Kind     string  `json:"kind"`
	Severity string  `json:"severity"`
	Text     string  `json:"text"`
	Where    *Anchor `json:"where"`
}

// threadKinds maps a thread finding's kind to an AuthorItem kind.
var threadKinds = map[string]string{
	"differs": KindAgreement, "missing": KindAgreement,
	"decided_alone": KindDecidedAlone, "blind_spot": KindBlindSpot,
}

// findingsOf is every finding of a previous review by key, as an AuthorItem:
// the reviewer's result (agreements as agreed and checks without a concern
// included: the owner may comment on any card), then the loop's ledger and
// open items, then the owner's thread findings. A later source wins a key;
// a source that does not decode is left out with a note.
func findingsOf(prev *db.SpecReview, threads []db.SpecReviewThreadFinding) (map[string]AuthorItem, []string) {
	out := map[string]AuthorItem{}
	var notes []string
	leftOut := func(what string, err error) {
		notes = append(notes, fmt.Sprintf("%s of ask #%d left out of the owner's items: %v", what, prev.AskID, err))
	}
	var r Result
	if prev.Result != "" {
		if err := json.Unmarshal([]byte(prev.Result), &r); err != nil {
			leftOut("the findings", err)
			r = Result{}
		}
		for _, a := range r.Agreements {
			out[a.Key] = AuthorItem{Key: a.Key, Kind: KindAgreement, Text: a.Text, Severity: a.Severity, Where: copyAnchor(a.Where)}
		}
		for _, x := range r.DecidedAlone {
			out[x.Key] = AuthorItem{Key: x.Key, Kind: KindDecidedAlone, Text: x.Text, Severity: x.Severity, Where: copyAnchor(&x.Where)}
		}
		for _, b := range r.BlindSpots {
			out[b.Key] = AuthorItem{Key: b.Key, Kind: KindBlindSpot, Text: b.Text, Severity: b.Severity, Where: copyAnchor(b.Where)}
		}
		for _, c := range r.Checks {
			out[c.Key] = AuthorItem{Key: c.Key, Kind: KindCheck, Text: c.Question, Severity: c.Severity}
		}
	}
	var ledger []LedgerEntry
	var open []AuthorItem
	if err := decodeList(prev.Ledger, &ledger); err != nil {
		leftOut("the ledger", err)
	}
	if err := decodeList(prev.OpenItems, &open); err != nil {
		leftOut("the open items", err)
	}
	for _, e := range ledger {
		out[e.Key] = AuthorItem{Key: e.Key, Kind: e.Kind, Text: e.Text, Severity: e.Severity, Where: copyAnchor(e.Where)}
	}
	for _, it := range open {
		out[it.Key] = AuthorItem{Key: it.Key, Kind: it.Kind, Text: it.Text, Severity: it.Severity, Where: copyAnchor(it.Where)}
	}
	for _, tf := range threads {
		var f threadFindingJSON
		if err := json.Unmarshal([]byte(tf.Finding), &f); err != nil {
			leftOut("thread finding "+tf.ItemKey, err)
			continue
		}
		if kind, ok := threadKinds[f.Kind]; ok {
			out[tf.ItemKey] = AuthorItem{Key: tf.ItemKey, Kind: kind, Text: f.Text, Severity: normSeverity(f.Severity), Where: copyAnchor(f.Where)}
		}
	}
	return out, notes
}
