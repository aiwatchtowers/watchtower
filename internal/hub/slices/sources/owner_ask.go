package sources

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/rivo/uniseg"

	"watchtower/internal/db"
	"watchtower/internal/hub/slices"
	"watchtower/internal/hub/wire"
	"watchtower/internal/specreview"
)

// The owner_ask caps (OwnerAskSlice).
const (
	askClosedWindow          = 7 * 24 * time.Hour
	askMaxClosedPerWorkbench = 50
	// askMaxJSONBytes caps payload and answer, serialized.
	askMaxJSONBytes = 64 * 1024
	// askMaxSnapshotBytes caps doc_snapshot, UTF-8.
	askMaxSnapshotBytes = 256 * 1024
)

// OwnerAsk is the owner_ask slice (OwnerAskSlice, mobile POC spec §4.6),
// record owner_ask-<owner_asks.id>: every open ask of a published workbench
// plus its answered, delivered and withdrawn asks filed in the last 7 days
// (≤ 50 per workbench, newest first). An author-loop ask is never published.
// Rows are read raw: an ask the Mac's card decoder refuses is still
// published, and the phone falls back to "Open the ask on the Mac". now nil
// is time.Now.
func OwnerAsk(d *db.DB, now func() time.Time) slices.Source {
	if now == nil {
		now = time.Now
	}
	return &ownerAskSource{d: d, now: now, review: &specReviewLines{}}
}

type ownerAskSource struct {
	d      *db.DB
	now    func() time.Time
	review *specReviewLines
}

func (*ownerAskSource) Kind() slices.Kind { return "owner_ask" }

// askQuickOption and askQuick are the Mac-computed one-tap answer.
type askQuickOption struct {
	Label       string `json:"label"`
	Recommended bool   `json:"recommended"`
}

type askQuick struct {
	QuestionID string           `json:"question_id"`
	Options    []askQuickOption `json:"options"`
}

// askSpecReview is the spec reviewer's line on a review ask.
type askSpecReview struct {
	Status string `json:"status"`
	Line   string `json:"line"`
}

// ownerAskPayload is the Kit mirror WatchtowerKit.OwnerAsk.
type ownerAskPayload struct {
	ID              int64          `json:"id"`
	WorkbenchID     int64          `json:"workbench_id"`
	WorkbenchName   string         `json:"workbench_name"`
	SessionID       *int64         `json:"session_id,omitempty"`
	TargetID        *int64         `json:"target_id,omitempty"`
	Kind            string         `json:"kind"`
	Status          string         `json:"status"`
	WithdrawnReason string         `json:"withdrawn_reason,omitempty"`
	PreviousAskID   *int64         `json:"previous_ask_id,omitempty"`
	CreatedAt       wire.Time      `json:"created_at"`
	AnsweredAt      *wire.Time     `json:"answered_at,omitempty"`
	DeliveredAt     *wire.Time     `json:"delivered_at,omitempty"`
	Title           string         `json:"title"`
	TitleClipped    *bool          `json:"title_clipped,omitempty"`
	Summary         string         `json:"summary"`
	SummaryClipped  *bool          `json:"summary_clipped,omitempty"`
	Changes         string         `json:"changes"`
	ChangesClipped  *bool          `json:"changes_clipped,omitempty"`
	Payload         any            `json:"payload,omitempty"`
	PayloadClipped  bool           `json:"payload_clipped,omitempty"`
	DocPath         string         `json:"doc_path"`
	DocPathClipped  *bool          `json:"doc_path_clipped,omitempty"`
	DocSnapshot     *string        `json:"doc_snapshot,omitempty"`
	DocClipped      bool           `json:"doc_clipped,omitempty"`
	DocBytes        *int           `json:"doc_bytes,omitempty"`
	Answer          any            `json:"answer,omitempty"`
	Quick           *askQuick      `json:"quick,omitempty"`
	SpecReview      *askSpecReview `json:"spec_review,omitempty"`
}

type askRow struct {
	id, project                                            int64
	session, target, previous                              *int64
	kind, status, withdrawnReason, title, summary, changes string
	payload, docPath, docSnapshot, answer                  string
	createdAt, answeredAt, deliveredAt                     string
}

func (s *ownerAskSource) Items(ctx context.Context) ([]slices.Item, error) {
	var out []slices.Item
	err := readTx(ctx, s.d, func(tx *sql.Tx) error {
		var err error
		out, err = s.items(ctx, tx)
		return err
	})
	return out, err
}

func (s *ownerAskSource) items(ctx context.Context, tx *sql.Tx) ([]slices.Item, error) {
	refs, err := publishedRefs(ctx, tx)
	if err != nil {
		return nil, err
	}
	if len(refs) == 0 {
		s.review.reset()
		return nil, nil
	}
	names := map[int64]string{}
	for _, r := range refs {
		names[r.id] = r.name
	}
	stamp := s.now()
	var all []askRow
	err = scanRows(ctx, tx, `
SELECT id, project_id, session_id, target_id, previous_ask_id, kind, status, withdrawn_reason,
       title, summary, changes, payload, doc_path, doc_snapshot, answer, created_at, answered_at, delivered_at
FROM (
    SELECT a.*, ROW_NUMBER() OVER (
        PARTITION BY a.project_id, a.status = 'open'
        ORDER BY a.created_at DESC, a.id DESC
    ) AS rank
    FROM owner_asks a
    WHERE (a.status = 'open' OR julianday(a.created_at) >= julianday(?)) AND `+askVisible+`
)
WHERE status = 'open' OR rank <= ?
ORDER BY id`, []any{sqliteDate(stamp.Add(-askClosedWindow)), askMaxClosedPerWorkbench},
		func(rows *sql.Rows) error {
			var r askRow
			if err := rows.Scan(&r.id, &r.project, &r.session, &r.target, &r.previous, &r.kind, &r.status,
				&r.withdrawnReason, &r.title, &r.summary, &r.changes, &r.payload, &r.docPath, &r.docSnapshot,
				&r.answer, &r.createdAt, &r.answeredAt, &r.deliveredAt); err != nil {
				return err
			}
			all = append(all, r)
			return nil
		})
	if err != nil {
		return nil, fmt.Errorf("reading owner asks: %w", err)
	}
	var reviewIDs []int64
	for _, r := range all {
		if r.kind == "review" {
			reviewIDs = append(reviewIDs, r.id)
		}
	}
	lines, err := s.review.lines(ctx, tx, reviewIDs)
	if err != nil {
		return nil, err
	}
	out := make([]slices.Item, 0, len(all))
	for _, r := range all {
		name, ok := names[r.project]
		if !ok {
			continue
		}
		b, err := wire.Marshal(askPayload(r, name, lines[r.id]))
		if err != nil {
			return nil, fmt.Errorf("encoding owner ask %d: %w", r.id, err)
		}
		out = append(out, slices.Item{ID: strconv.FormatInt(r.id, 10), Payload: b})
	}
	return out, nil
}

func askPayload(r askRow, workbenchName string, review *askSpecReview) ownerAskPayload {
	record := "owner_ask-" + strconv.FormatInt(r.id, 10)
	isOpen := r.status == "open"
	p := ownerAskPayload{
		ID: r.id, WorkbenchID: r.project, SessionID: r.session, TargetID: r.target, Kind: r.kind,
		Status: r.status, WithdrawnReason: r.withdrawnReason, PreviousAskID: r.previous,
		CreatedAt:  requiredDate(r.createdAt, "created_at", record),
		AnsweredAt: parseDate(r.answeredAt), DeliveredAt: parseDate(r.deliveredAt),
		SpecReview: review,
	}
	p.WorkbenchName, _ = clipText(workbenchName, 200)
	p.Title, p.TitleClipped = clipText(r.title, 200)
	p.Summary, p.SummaryClipped = clipText(r.summary, 4000)
	p.Changes, p.ChangesClipped = clipText(r.changes, 4000)
	p.DocPath, p.DocPathClipped = clipText(r.docPath, 300)
	payload, payloadClipped := storedJSON(r.payload, record, "payload")
	p.Payload, p.PayloadClipped = payload, payloadClipped
	if isOpen && r.kind == "review" {
		text, clipped, total := clipSnapshot(r.docSnapshot)
		p.DocSnapshot, p.DocClipped = &text, clipped
		if clipped {
			p.DocBytes = &total
		}
	}
	if !isOpen {
		p.Answer, _ = storedJSON(r.answer, record, "answer")
	}
	// Without the payload the phone offers only "Open the ask on the Mac".
	if payload != nil && r.kind == "question" {
		p.Quick = quickAnswer(payload)
	}
	return p
}

// storedJSON is a stored JSON column for the wire (OwnerAskSlice.json): ""
// is absent, an unreadable value (never written by Go or the Desktop) is
// logged and left out, and a value over askMaxJSONBytes serialized is
// dropped with clipped set. The value keeps its numbers verbatim.
func storedJSON(text, record, field string) (value any, clipped bool) {
	if text == "" {
		return nil, false
	}
	dec := json.NewDecoder(strings.NewReader(text))
	dec.UseNumber()
	var v any
	if err := dec.Decode(&v); err != nil || dec.More() {
		log.Printf("hub slices: unreadable %s on %s left out", field, record)
		return nil, false
	}
	b, err := wire.Marshal(v)
	if err != nil || len(b) > askMaxJSONBytes {
		return nil, true
	}
	return v, false
}

// clipSnapshot is OwnerAskSlice.clipSnapshot: at most askMaxSnapshotBytes of
// UTF-8, cut after the last newline before the cap, or at the last whole
// grapheme cluster when there is none; no ellipsis. total is the full size.
func clipSnapshot(text string) (out string, clipped bool, total int) {
	total = len(text)
	if total <= askMaxSnapshotBytes {
		return text, false, total
	}
	if i := strings.LastIndexByte(text[:askMaxSnapshotBytes], '\n'); i >= 0 {
		return text[:i+1], true, total
	}
	end, rest, state := 0, text, -1
	for rest != "" {
		var cluster string
		cluster, rest, _, state = uniseg.FirstGraphemeClusterInString(rest, state)
		if end+len(cluster) > askMaxSnapshotBytes {
			break
		}
		end += len(cluster)
	}
	return text[:end], true, total
}

// quickAnswer is OwnerAskSlice.quick: {question_id, options} for one
// single-select question with 2–4 options, at least one recommended; nil
// otherwise. Labels are trimmed the way the Mac's card decoder reads them.
func quickAnswer(payload any) *askQuick {
	obj, ok := payload.(map[string]any)
	if !ok {
		return nil
	}
	questions, ok := obj["questions"].([]any)
	if !ok || len(questions) != 1 {
		return nil
	}
	q, ok := questions[0].(map[string]any)
	if !ok {
		return nil
	}
	raw, ok := q["options"].([]any)
	if !ok || len(raw) < 2 || len(raw) > 4 {
		return nil
	}
	if multi, _ := q["multi"].(bool); multi {
		return nil
	}
	var (
		options     []askQuickOption
		recommended bool
	)
	for _, r := range raw {
		o, ok := r.(map[string]any)
		if !ok {
			return nil
		}
		label, ok := o["label"].(string)
		if !ok {
			return nil
		}
		rec, _ := o["recommended"].(bool)
		recommended = recommended || rec
		options = append(options, askQuickOption{Label: strings.TrimSpace(label), Recommended: rec})
	}
	if !recommended {
		return nil
	}
	id := "1"
	if s, ok := q["id"].(string); ok && s != "" {
		id = s
	}
	return &askQuick{QuestionID: id, Options: options}
}

// specReviewLines is the Swift SpecReviewLines (F9): one query for every
// review ask's row without its result; a done review's line is decoded once
// per finish (finished_at and loop_end) and kept across passes.
type specReviewLines struct {
	mu   sync.Mutex
	done map[int64]doneLine
}

type doneLine struct{ finish, line string }

func (l *specReviewLines) reset() {
	l.mu.Lock()
	l.done = nil
	l.mu.Unlock()
}

func (l *specReviewLines) lines(ctx context.Context, tx *sql.Tx, askIDs []int64) (map[int64]*askSpecReview, error) {
	if len(askIDs) == 0 {
		l.reset()
		return nil, nil
	}
	l.mu.Lock()
	known := l.done
	l.mu.Unlock()
	kept := map[int64]doneLine{}
	out := map[int64]*askSpecReview{}
	misses := map[int64]string{}
	marks, args := inList(askIDs)
	err := scanRows(ctx, tx, `SELECT ask_id, status, reason, finished_at, loop_end FROM spec_reviews
		WHERE ask_id IN (`+marks+`)`, args, func(rows *sql.Rows) error {
		var (
			id                                int64
			status, reason, finished, loopEnd string
		)
		if err := rows.Scan(&id, &status, &reason, &finished, &loopEnd); err != nil {
			return err
		}
		if status == "done" {
			// A loop's end changes the line without a new finish.
			finish := finished + "|" + loopEnd
			if hit, ok := known[id]; ok && hit.finish == finish {
				kept[id] = hit
				out[id] = reviewLine("done", hit.line)
			} else {
				misses[id] = finish
			}
		} else if st, line, ok := reviewStateLine(status, reason); ok {
			out[id] = reviewLine(st, line)
		}
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("reading spec reviews: %w", err)
	}
	if len(misses) > 0 {
		ids := make([]int64, 0, len(misses))
		for id := range misses {
			ids = append(ids, id)
		}
		marks, args := inList(ids)
		err := scanRows(ctx, tx, `SELECT ask_id, result, loop, ledger FROM spec_reviews
			WHERE ask_id IN (`+marks+`)`, args, func(rows *sql.Rows) error {
			var (
				id                   int64
				result, loop, ledger string
			)
			if err := rows.Scan(&id, &result, &loop, &ledger); err != nil {
				return err
			}
			line := doneReviewLine(result, loop, ledger)
			kept[id] = doneLine{finish: misses[id], line: line}
			out[id] = reviewLine("done", line)
			return nil
		})
		if err != nil {
			return nil, fmt.Errorf("reading spec review results: %w", err)
		}
	}
	l.mu.Lock()
	l.done = kept
	l.mu.Unlock()
	return out, nil
}

func reviewLine(status, text string) *askSpecReview {
	line, _ := clipText(text, 300)
	return &askSpecReview{Status: status, Line: line}
}

// reviewStateLine is SpecReviewSummary.phoneLine for a review that is not
// done; ok is false for a status this build does not know.
func reviewStateLine(status, reason string) (string, string, bool) {
	withReason := func(label string) string {
		if reason == "" {
			return label
		}
		return label + ": " + reason
	}
	switch status {
	case "queued", "running":
		return status, "Reviewer is reading…", true
	case "failed":
		return status, withReason("Reviewer failed"), true
	case "skipped":
		return status, withReason("Reviewer skipped"), true
	}
	return "", "", false
}

// doneReviewLine is a done review's phone line: an ended author loop's
// line (SpecReviewSummary.loopLine), else the counts of the result.
func doneReviewLine(result, loop, ledger string) string {
	if loop == "owner" {
		var entries []specreview.LedgerEntry
		if ledger != "" {
			if err := json.Unmarshal([]byte(ledger), &entries); err != nil {
				entries = nil // malformed reads as an empty ledger (SpecReviewRow)
			}
		}
		return loopLine(entries)
	}
	if result == "" {
		return "The reviewer's result could not be read"
	}
	var r specreview.Result
	if err := json.Unmarshal([]byte(result), &r); err != nil {
		return "The reviewer's result could not be read"
	}
	return countsLine(r)
}

// countsLine is SpecReviewSummary.countsLine: "9 as agreed · 1 differs ·
// 1 missing · 4 decided alone · 2 blind spots", zero counts left out.
func countsLine(r specreview.Result) string {
	var agreed, differs, missing int
	for _, a := range r.Agreements {
		switch a.Status {
		case "as_agreed":
			agreed++
		case "differs":
			differs++
		case "missing":
			missing++
		}
	}
	blind := "blind spots"
	if len(r.BlindSpots) == 1 {
		blind = "blind spot"
	}
	parts := []struct {
		n     int
		label string
	}{
		{agreed, "as agreed"}, {differs, "differs"}, {missing, "missing"},
		{len(r.Agreements) - agreed - differs - missing, "other"},
		{len(r.DecidedAlone), "decided alone"}, {len(r.BlindSpots), blind},
	}
	var out []string
	for _, p := range parts {
		if p.n > 0 {
			out = append(out, strconv.Itoa(p.n)+" "+p.label)
		}
	}
	if len(out) == 0 {
		return "No findings"
	}
	return strings.Join(out, " · ")
}

// loopLine is SpecReviewSummary.loopLine over an ended loop's ledger.
func loopLine(ledger []specreview.LedgerEntry) string {
	var disputed, unanswered, fixed int
	for _, e := range ledger {
		disagree := e.Reply != nil && e.Reply.Reply == "disagree"
		switch {
		case e.Verdict == "disputed" || (e.Verdict == "unsettled" && disagree):
			disputed++
		case e.Verdict == "unsettled":
			unanswered++
		case e.Verdict == "resolved" && !disagree:
			fixed++
		}
	}
	var parts []string
	if disputed > 0 {
		parts = append(parts, fmt.Sprintf("Reviewer and author disagree on %d", disputed))
	}
	if unanswered > 0 {
		parts = append(parts, fmt.Sprintf("%d not answered", unanswered))
	}
	parts = append(parts, fmt.Sprintf("%d fixed by the author", fixed))
	return strings.Join(parts, " · ")
}
