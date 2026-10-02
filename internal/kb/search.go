package kb

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"sort"
	"strconv"
	"strings"
	"time"

	"watchtower/internal/db"
)

// Search limits and weights (spec §8).
const (
	DefaultLimit    = 10
	MaxLimit        = 25
	MaxQueries      = 5
	DefaultDocChars = 12000
	MaxDocChars     = 50000

	candidates  = 50  // chunks retrieved per MATCH list
	rrfK        = 50  // reciprocal rank fusion constant
	andWeight   = 1.0 // weight of a query's AND list
	orWeight    = 0.5 // weight of a query's OR fallback list
	snippetsMax = 2   // snippets kept per document
	recencyMin  = 0.75
)

// Request is one knowledge search. Queries are the chat model's variants of
// one question (key terms, synonyms, RU/EN, stems with '*').
//
// From/To filter on the document time. A document whose time is unknown
// (stored as 0: e.g. a calendar event with an unparsable start) sorts before
// every date, so it passes a To filter but never a From filter.
type Request struct {
	Queries  []string
	Sources  []string  // optional filter; each must be in SourceNames()
	From, To time.Time // optional; To is exclusive; both set requires From < To
	Limit    int       // 0 = DefaultLimit, capped at MaxLimit
	Now      time.Time // zero = time.Now(); drives recency and the index note

	// Scope, when not empty, ranks its documents first: every query runs a
	// second time restricted to the scope and that list is fused in too, so
	// an in-scope chunk earns a second contribution (and one outside the
	// global top candidates still gets retrieved). Nothing outside the scope
	// is dropped. ScopeOnly instead restricts every list to the scope.
	Scope     Scope
	ScopeOnly bool

	// WorkbenchID is the project session searching, 0 for every other caller:
	// project documents are visible only to their own project (PROJ-08).
	WorkbenchID int64
}

// Hit is one matching document. Chunk is the index of its best-matching
// chunk (pass it as get_knowledge_document's from_chunk to open the document
// at the matched part); ChunkAnchor is that chunk's source-native locator
// (a Slack message ts, a transcript start second, a comment id), empty when
// the source has none.
type Hit struct {
	Ref         string            `json:"ref"`
	Source      string            `json:"source"`
	Title       string            `json:"title"`
	When        string            `json:"when,omitempty"`
	Link        string            `json:"link,omitempty"`
	Anchor      map[string]string `json:"anchor"`
	Chunk       int               `json:"chunk"`
	ChunkAnchor string            `json:"chunk_anchor,omitempty"`
	Snippets    []string          `json:"snippets"`
	InScope     bool              `json:"in_scope,omitempty"` // in Request.Scope
	score       float64
}

// Result is a search answer; IndexNote explains a partial or stale index.
// ScopeNote is the caller's to fill: what it could not turn into the
// request's Scope (Search never sets it).
type Result struct {
	Hits      []Hit  `json:"hits"`
	IndexNote string `json:"index_note,omitempty"`
	ScopeNote string `json:"scope_note,omitempty"`
}

// RequestError reports an invalid Request (the caller's fault, not the index's).
type RequestError struct{ Msg string }

func (e *RequestError) Error() string { return "kb: invalid request: " + e.Msg }

// SourceNames lists every indexed source name, in indexing order.
func SourceNames() []string { return sourceNames() }

// Search runs every query against the index, fuses the ranked chunk lists
// with weighted reciprocal rank fusion, groups chunks into documents,
// applies the bounded recency factor and returns the top documents.
func Search(ctx context.Context, d *db.DB, req Request) (Result, error) {
	limit, err := validate(&req)
	if err != nil {
		return Result{}, err
	}
	now := req.Now
	if now.IsZero() {
		now = time.Now()
	}
	if req.ScopeOnly && req.Scope.Empty() {
		return Result{Hits: []Hit{}}, nil
	}
	boost := !req.Scope.Empty() && !req.ScopeOnly
	f := newFusion()
	for _, q := range req.Queries {
		and, or := BuildMatch(q)
		if and == "" {
			continue
		}
		if err := f.addQuery(ctx, d, and, or, req, req.ScopeOnly); err != nil {
			return Result{}, err
		}
		if boost {
			if err := f.addQuery(ctx, d, and, or, req, true); err != nil {
				return Result{}, err
			}
		}
	}
	note, err := indexNote(ctx, d, now)
	if err != nil {
		return Result{}, err
	}
	return Result{Hits: f.hits(now, limit), IndexNote: note}, nil
}

// workbenchDocVisible is the SQL condition (over kb_documents aliased d) that
// hides every project document but those of the project bound to its one
// argument; projectID 0 hides them all (PROJ-08).
const workbenchDocVisible = `(d.source <> '` + WorkbenchDocSource + `' OR json_extract(d.anchor_json, '$.project_id') = ?)`

// validate checks req and returns the effective limit.
func validate(req *Request) (int, error) {
	if len(req.Queries) == 0 || len(req.Queries) > MaxQueries {
		return 0, &RequestError{Msg: fmt.Sprintf("queries: want 1–%d, got %d", MaxQueries, len(req.Queries))}
	}
	for i, q := range req.Queries {
		if strings.TrimSpace(q) == "" {
			return 0, &RequestError{Msg: fmt.Sprintf("queries[%d] is empty", i)}
		}
	}
	if !req.From.IsZero() && !req.To.IsZero() && !req.From.Before(req.To) {
		return 0, &RequestError{Msg: fmt.Sprintf("from (%s) must be before to (%s)", req.From.UTC().Format(time.RFC3339), req.To.UTC().Format(time.RFC3339))}
	}
	known := SourceNames()
	for _, s := range req.Sources {
		if !slices.Contains(known, s) {
			return 0, &RequestError{Msg: fmt.Sprintf("unknown source %q (known: %s)", s, strings.Join(known, ", "))}
		}
	}
	switch {
	case req.Limit < 0:
		return 0, &RequestError{Msg: fmt.Sprintf("limit must not be negative, got %d", req.Limit)}
	case req.Limit == 0:
		return DefaultLimit, nil
	case req.Limit > MaxLimit:
		return MaxLimit, nil
	}
	return req.Limit, nil
}

// candidate is one retrieved chunk with its document's fields.
type candidate struct {
	chunkID     int64
	chunkIdx    int
	chunkAnchor string
	docID       string
	snippet     string
	source      string
	title       string
	docTime     string
	docUnix     float64
	link        string
	anchor      map[string]string
	inScope     bool
}

// addQuery folds one query in: its AND list, plus the OR fallback when the
// AND list is sparse. scoped restricts both lists to req.Scope.
func (f *fusion) addQuery(ctx context.Context, d *db.DB, and, or string, req Request, scoped bool) error {
	list, err := retrieve(ctx, d, and, req, scoped)
	if err != nil {
		return err
	}
	f.add(list, andWeight)
	if len(list) < candidates && or != and {
		orList, err := retrieve(ctx, d, or, req, scoped)
		if err != nil {
			return err
		}
		f.add(orList, orWeight)
	}
	return nil
}

// retrieve returns up to `candidates` chunks matching match, best bm25 first
// (ties by chunk id, so fusion is deterministic), honouring the source and
// time filters, and only req.Scope's documents when scoped. Each candidate
// says whether it is in req.Scope. All rows are read before returning
// (single connection).
func retrieve(ctx context.Context, d *db.DB, match string, req Request, scoped bool) ([]candidate, error) {
	inScope, args := "0", []any{}
	var scopePred string
	var scopeArgs []any
	if !req.Scope.Empty() {
		scopePred, scopeArgs = req.Scope.predicate()
		inScope = "CASE WHEN " + scopePred + " THEN 1 ELSE 0 END"
		args = append(args, scopeArgs...)
	}
	var sb strings.Builder
	sb.WriteString(`SELECT c.id, c.idx, c.anchor, c.doc_id, snippet(kb_fts, 1, '', '', '…', 40), d.source, d.title, d.doc_time, d.doc_time_unix, d.link, d.anchor_json, ` + inScope + `
		FROM kb_fts JOIN kb_chunks c ON c.id = kb_fts.rowid JOIN kb_documents d ON d.id = c.doc_id
		WHERE kb_fts MATCH ?`)
	args = append(args, match)
	sb.WriteString(` AND ` + workbenchDocVisible)
	args = append(args, strconv.FormatInt(req.WorkbenchID, 10))
	if scoped { // Search never asks for it with an empty scope
		sb.WriteString(` AND ` + scopePred)
		args = append(args, scopeArgs...)
	}
	if len(req.Sources) > 0 {
		sb.WriteString(` AND d.source IN (?` + strings.Repeat(`, ?`, len(req.Sources)-1) + `)`)
		for _, s := range req.Sources {
			args = append(args, s)
		}
	}
	if !req.From.IsZero() {
		sb.WriteString(` AND d.doc_time_unix >= ?`)
		args = append(args, float64(req.From.Unix()))
	}
	if !req.To.IsZero() {
		sb.WriteString(` AND d.doc_time_unix < ?`)
		args = append(args, float64(req.To.Unix()))
	}
	sb.WriteString(` ORDER BY bm25(kb_fts, 4.0, 1.0, 2.0), c.id LIMIT ?`)
	args = append(args, candidates)

	rows, err := d.QueryContext(ctx, sb.String(), args...)
	if err != nil {
		// match is built only from quoted letter/digit terms, so an FTS
		// syntax error here is a bug in BuildMatch, not bad user input.
		return nil, fmt.Errorf("kb: search %q: %w", match, err)
	}
	defer rows.Close()
	var out []candidate
	for rows.Next() {
		var c candidate
		var anchorJS string
		if err := rows.Scan(&c.chunkID, &c.chunkIdx, &c.chunkAnchor, &c.docID, &c.snippet, &c.source, &c.title, &c.docTime, &c.docUnix, &c.link, &anchorJS, &c.inScope); err != nil {
			return nil, fmt.Errorf("kb: search %q: %w", match, err)
		}
		if c.anchor, err = parseAnchor(anchorJS); err != nil {
			return nil, fmt.Errorf("kb: anchor of %s: %w", c.docID, err)
		}
		out = append(out, c)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("kb: search %q: %w", match, err)
	}
	return out, nil
}

// fusedChunk accumulates one chunk's fused score; snippet comes from the list
// where the chunk contributed most.
type fusedChunk struct {
	candidate
	score, bestContribution float64
}

type fusion struct{ chunks map[int64]*fusedChunk }

func newFusion() *fusion { return &fusion{chunks: map[int64]*fusedChunk{}} }

// add folds one ranked list in: chunk score += w / (k + rank), rank 1-based.
func (f *fusion) add(list []candidate, w float64) {
	for i, c := range list {
		contribution := w / float64(rrfK+i+1)
		fc, ok := f.chunks[c.chunkID]
		if !ok {
			fc = &fusedChunk{candidate: c}
			f.chunks[c.chunkID] = fc
		}
		fc.score += contribution
		if contribution > fc.bestContribution {
			fc.bestContribution = contribution
			fc.snippet = c.snippet
		}
	}
}

// hits groups the fused chunks by document (score = best chunk), applies
// recency, sorts and cuts to limit.
func (f *fusion) hits(now time.Time, limit int) []Hit {
	byDoc := map[string][]*fusedChunk{}
	for _, fc := range f.chunks {
		byDoc[fc.docID] = append(byDoc[fc.docID], fc)
	}
	type ranked struct {
		hit  Hit
		unix float64
	}
	docs := make([]ranked, 0, len(byDoc))
	for _, chunks := range byDoc {
		sort.Slice(chunks, func(i, j int) bool {
			if chunks[i].score != chunks[j].score {
				return chunks[i].score > chunks[j].score
			}
			return chunks[i].chunkID < chunks[j].chunkID
		})
		best := chunks[0]
		h := Hit{
			Ref: best.docID, Source: best.source, Title: best.title, When: best.docTime, Link: best.link,
			Anchor: best.anchor, Chunk: best.chunkIdx, ChunkAnchor: best.chunkAnchor, Snippets: []string{},
			InScope: best.inScope,
			score:   best.score * recencyFactor(best.docUnix, now),
		}
		for _, c := range chunks {
			if len(h.Snippets) == snippetsMax {
				break
			}
			if !slices.Contains(h.Snippets, c.snippet) {
				h.Snippets = append(h.Snippets, c.snippet)
			}
		}
		docs = append(docs, ranked{hit: h, unix: best.docUnix})
	}
	sort.Slice(docs, func(i, j int) bool {
		a, b := docs[i], docs[j]
		if a.hit.score != b.hit.score {
			return a.hit.score > b.hit.score
		}
		if a.unix != b.unix {
			return a.unix > b.unix
		}
		return a.hit.Ref < b.hit.Ref
	})
	out := make([]Hit, 0, min(limit, len(docs)))
	for i := 0; i < len(docs) && i < limit; i++ {
		out = append(out, docs[i].hit)
	}
	return out
}

// recencyFactor is max(1/(1+0.5·age_years), 0.75); an unknown time (0) gets
// the floor, a future one 1.
func recencyFactor(docUnix float64, now time.Time) float64 {
	if docUnix == 0 {
		return recencyMin
	}
	age := (float64(now.Unix()) - docUnix) / (365.25 * 86400)
	if age <= 0 {
		return 1
	}
	return max(1/(1+0.5*age), recencyMin)
}

// parseAnchor decodes a stored anchor_json (always a JSON object of strings).
func parseAnchor(raw string) (map[string]string, error) {
	out := map[string]string{}
	if err := json.Unmarshal([]byte(raw), &out); err != nil {
		return nil, err
	}
	return out, nil
}

// DocView is one opened document. Text holds chunks FromChunk.. of
// ChunkCount joined in order; Truncated means text remains after it.
type DocView struct {
	Ref        string            `json:"ref"`
	Source     string            `json:"source"`
	Title      string            `json:"title"`
	When       string            `json:"when"`
	Link       string            `json:"link"`
	Anchor     map[string]string `json:"anchor"`
	FromChunk  int               `json:"from_chunk"`
	ChunkCount int               `json:"chunk_count"`
	Text       string            `json:"text"`
	Truncated  bool              `json:"truncated"`
}

// DocOptions selects the part of a document GetDocument returns.
type DocOptions struct {
	FromChunk int // first chunk to include (a Hit's Chunk); 0 = the start
	MaxChars  int // rune cap; <= 0 means DefaultDocChars, capped at MaxDocChars
	// WorkbenchID is the project session opening, 0 for every other caller:
	// another project's document reads as not found (PROJ-08).
	WorkbenchID int64
}

// ErrNotFound is returned by GetDocument for an unknown ref.
var ErrNotFound = errors.New("kb: document not found")

// GetDocument returns a document's chunks from opts.FromChunk on, joined in
// order and capped at opts.MaxChars runes. A FromChunk outside the document
// is a RequestError.
func GetDocument(ctx context.Context, d *db.DB, ref string, opts DocOptions) (DocView, error) {
	maxChars := opts.MaxChars
	if maxChars <= 0 {
		maxChars = DefaultDocChars
	}
	maxChars = min(maxChars, MaxDocChars)
	v := DocView{Ref: ref, FromChunk: opts.FromChunk}
	var anchorJS string
	err := d.QueryRowContext(ctx, `SELECT d.source, d.title, d.doc_time, d.link, d.anchor_json, d.chunk_count
		FROM kb_documents d WHERE d.id = ? AND `+workbenchDocVisible, ref, strconv.FormatInt(opts.WorkbenchID, 10)).
		Scan(&v.Source, &v.Title, &v.When, &v.Link, &anchorJS, &v.ChunkCount)
	if errors.Is(err, sql.ErrNoRows) {
		return DocView{}, fmt.Errorf("%w: %s", ErrNotFound, ref)
	}
	if err != nil {
		return DocView{}, fmt.Errorf("kb: reading %s: %w", ref, err)
	}
	if v.Anchor, err = parseAnchor(anchorJS); err != nil {
		return DocView{}, fmt.Errorf("kb: anchor of %s: %w", ref, err)
	}
	if opts.FromChunk < 0 || opts.FromChunk >= v.ChunkCount {
		return DocView{}, &RequestError{Msg: fmt.Sprintf("from_chunk %d is outside the document (chunks 0–%d)", opts.FromChunk, v.ChunkCount-1)}
	}
	bodies, err := queryStrings(ctx, d, `SELECT body FROM kb_chunks WHERE doc_id = ? AND idx >= ? ORDER BY idx`, ref, opts.FromChunk)
	if err != nil {
		return DocView{}, fmt.Errorf("kb: reading chunks of %s: %w", ref, err)
	}
	text := []rune(strings.Join(bodies, "\n"))
	if len(text) > maxChars {
		text, v.Truncated = text[:maxChars], true
	}
	v.Text = string(text)
	return v, nil
}
