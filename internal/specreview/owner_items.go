package specreview

import (
	"encoding/json"
	"errors"
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

// AnsweredChanges reports whether ask was answered with Request changes.
func AnsweredChanges(ask *db.OwnerAsk) bool {
	if ask.Status != "answered" && ask.Status != "delivered" {
		return false
	}
	a, err := asks.ParseAnswer([]byte(ask.Answer))
	return err == nil && a.Verdict == asks.VerdictChanges
}

// SeedOf is the owner's items that open round 1 of ask's loop: nil unless ask
// is round 1 of an author loop whose previous ask's review the owner had
// (OwnerHas) and answered with Request changes; then one item per comment of
// that answer (the key is the comment's ItemKey, else an "oc:" key of its
// body and quote; kind, text and severity are those of the key's finding —
// in the previous review's result, its ledger or open items, or the owner's
// thread findings —, else KindOwnerComment with the comment as the text; the
// owner's comment is the note; Where is the comment's heading and quote),
// then every thread finding of the previous ask not already seeded and not
// on the closed list. A key the owner marked ok or Not useful on the
// previous ask is never seeded. Every item has Round 1. Only a database error
// fails: stored JSON that does not decode gives what it can (a comment then
// keeps the owner's words as an owner_comment), so the seed never keeps a
// loop from reaching the owner.
func SeedOf(d *db.DB, ask *db.OwnerAsk) ([]AuthorItem, error) {
	if !ask.PreviousAskID.Valid {
		return nil, nil
	}
	row, err := d.GetSpecReview(ask.ID)
	if errors.Is(err, db.ErrSpecReviewNotFound) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if row.Loop != "author" || row.Round != 1 {
		return nil, nil
	}
	prevAsk, err := d.GetOwnerAskByID(ask.PreviousAskID.Int64)
	if errors.Is(err, db.ErrAskNotFound) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	prev, err := d.GetSpecReview(prevAsk.ID)
	if errors.Is(err, db.ErrSpecReviewNotFound) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if !OwnerHas(prev) || !AnsweredChanges(prevAsk) {
		return nil, nil
	}
	answer, _ := asks.ParseAnswer([]byte(prevAsk.Answer)) // AnsweredChanges parsed it
	marks, err := d.ListSpecReviewMarks(prevAsk.ID)
	if err != nil {
		return nil, err
	}
	threads, err := d.ListSpecReviewThreadFindings(prevAsk.ID)
	if err != nil {
		return nil, err
	}
	chain, _, err := readChain(d, ask.ID)
	if err != nil {
		return nil, err
	}
	findings := findingsOf(prev, threads)
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
		if ok {
			it.Note = body
		} else {
			it = AuthorItem{Key: key, Kind: KindOwnerComment, Text: body}
		}
		it.Where, it.Round = nil, 1
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
		it.Round = 1
		at[tf.ItemKey] = len(seed)
		seed = append(seed, it)
	}
	return seed, nil
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
// a source that does not decode is left out.
func findingsOf(prev *db.SpecReview, threads []db.SpecReviewThreadFinding) map[string]AuthorItem {
	out := map[string]AuthorItem{}
	var r Result
	if prev.Result != "" && json.Unmarshal([]byte(prev.Result), &r) == nil {
		for _, a := range r.Agreements {
			out[a.Key] = AuthorItem{Key: a.Key, Kind: KindAgreement, Text: a.Text, Severity: a.Severity}
		}
		for _, x := range r.DecidedAlone {
			out[x.Key] = AuthorItem{Key: x.Key, Kind: KindDecidedAlone, Text: x.Text, Severity: x.Severity}
		}
		for _, b := range r.BlindSpots {
			out[b.Key] = AuthorItem{Key: b.Key, Kind: KindBlindSpot, Text: b.Text, Severity: b.Severity}
		}
		for _, c := range r.Checks {
			out[c.Key] = AuthorItem{Key: c.Key, Kind: KindCheck, Text: c.Question, Severity: c.Severity}
		}
	}
	var ledger []LedgerEntry
	var open []AuthorItem
	_ = decodeList(prev.Ledger, &ledger)
	_ = decodeList(prev.OpenItems, &open)
	for _, e := range ledger {
		out[e.Key] = AuthorItem{Key: e.Key, Kind: e.Kind, Text: e.Text, Severity: e.Severity}
	}
	for _, it := range open {
		out[it.Key] = AuthorItem{Key: it.Key, Kind: it.Kind, Text: it.Text, Severity: it.Severity}
	}
	for _, tf := range threads {
		var f threadFindingJSON
		kind, ok := "", false
		if json.Unmarshal([]byte(tf.Finding), &f) == nil {
			kind, ok = threadKinds[f.Kind]
		}
		if ok {
			out[tf.ItemKey] = AuthorItem{Key: tf.ItemKey, Kind: kind, Text: f.Text, Severity: normSeverity(f.Severity), Where: copyAnchor(f.Where)}
		}
	}
	return out
}
