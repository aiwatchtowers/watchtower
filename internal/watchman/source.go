package watchman

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net/url"
	"strconv"
	"strings"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/logredact"
)

// Source reads one kind of owner decision for one workbench, newest first, resumable by an opaque cursor ("" = nothing seen yet).
type Source interface {
	Name() string
	Next(ctx context.Context, d *db.DB, workbenchID int64, cursor string, limit int) (ps []db.WatchmanPrecedent, next string, done bool, err error)
}

// Source names, also the precedents' source column.
const (
	SourceAsk        = "ask"
	SourceReview     = "review"
	SourceSpec       = "spec"
	SourcePermission = "permission"
)

// Categories (spec §7, fixed in v1).
const (
	CategoryDesign     = "design"
	CategoryScope      = "scope"
	CategoryUXText     = "ux_text"
	CategoryTests      = "tests"
	CategoryReviewCode = "review_code"
	CategoryReviewDoc  = "review_doc"
	CategoryPermission = "permission"
	CategoryFinish     = "finish"
)

// SituationLimit caps a precedent's situation (and owner words), in runes.
const SituationLimit = 2048

// DBSources returns the database sources in learning order.
func DBSources() []Source {
	return []Source{&asksSource{}, &reviewSource{}, &specSource{}, &permissionSource{}}
}

// SkipCounter is implemented by a Source that can meet rows it cannot learn
// from (unreadable JSON, a missing decided_at): Skipped is how many it met
// since it was made. Each one is also logged with its ids, never its text.
type SkipCounter interface {
	Skipped() int
}

// skips is the SkipCounter the database sources embed.
type skips struct{ n int }

func (s *skips) Skipped() int { return s.n }

// skip counts one row and logs it by id; err must already be log-safe
// (built by logredact.Errorf when it may hold row text).
func (s *skips) skip(source, id string, err error) {
	s.n++
	log.Printf("watchman: %s %s skipped: %v", source, id, err)
}

// errNoStamp is a decided row with no readable decided_at.
var errNoStamp = errors.New("no readable decided_at")

// unreadable fingerprints a parse error, which may quote row text (FILES-01).
func unreadable(what string, err error) error {
	return logredact.Errorf("unreadable %s: %s", what, logredact.Text(err.Error()))
}

// clean redacts secrets and caps text at SituationLimit: every text a source
// stores goes through it.
func clean(s string) string { return Clip(Redact(strings.TrimSpace(s)), SituationLimit) }

// joinNonEmpty joins the non-blank parts with sep.
func joinNonEmpty(sep string, parts ...string) string {
	var keep []string
	for _, p := range parts {
		if p = strings.TrimSpace(p); p != "" {
			keep = append(keep, p)
		}
	}
	return strings.Join(keep, sep)
}

// cursor is a source's walk state: hi is the newest row seen, lo the oldest.
// Next returns rows newer than hi first (incremental), then rows older than lo
// (backfill, newest first). It is stored as "hi|lo", each mark
// "decided_at,id[,sub]" with sub query-escaped; an unset mark is "".
type cursor struct{ hi, lo *db.WatchmanMark }

func encodeMark(m *db.WatchmanMark) string {
	if m == nil {
		return ""
	}
	s := m.At + "," + strconv.FormatInt(m.ID, 10)
	if m.Sub != "" {
		s += "," + url.QueryEscape(m.Sub)
	}
	return s
}

func decodeMark(s string) (*db.WatchmanMark, error) {
	if s == "" {
		return nil, nil
	}
	parts := strings.SplitN(s, ",", 3)
	if len(parts) < 2 || parts[0] == "" {
		return nil, fmt.Errorf("watchman cursor mark %q: want decided_at,id", s)
	}
	id, err := strconv.ParseInt(parts[1], 10, 64)
	if err != nil {
		return nil, fmt.Errorf("watchman cursor mark %q: %w", s, err)
	}
	m := &db.WatchmanMark{At: parts[0], ID: id}
	if len(parts) == 3 {
		if m.Sub, err = url.QueryUnescape(parts[2]); err != nil {
			return nil, fmt.Errorf("watchman cursor mark %q: %w", s, err)
		}
	}
	return m, nil
}

func parseCursor(s string) (cursor, error) {
	if s == "" {
		return cursor{}, nil
	}
	hi, lo, ok := strings.Cut(s, "|")
	if !ok {
		return cursor{}, fmt.Errorf("watchman cursor %q: want hi|lo", s)
	}
	h, err := decodeMark(hi)
	if err != nil {
		return cursor{}, err
	}
	l, err := decodeMark(lo)
	if err != nil {
		return cursor{}, err
	}
	return cursor{hi: h, lo: l}, nil
}

func (c cursor) String() string {
	if c.hi == nil && c.lo == nil {
		return ""
	}
	return encodeMark(c.hi) + "|" + encodeMark(c.lo)
}

// pageReader reads one page of a source's rows: strictly after from oldest
// first, or (older) strictly before from newest first, nil from = the newest.
type pageReader[R any] func(from *db.WatchmanMark, older bool, limit int) ([]R, error)

// walk reads up to limit rows: new rows past hi first, then the backfill past
// lo with what the limit leaves. done is true when the backfill has no rows
// left (the limit was not filled by new rows and the older page came back
// short).
func walk[R any](raw string, limit int, read pageReader[R], mark func(R) db.WatchmanMark) (rows []R, next string, done bool, err error) {
	c, err := parseCursor(raw)
	if err != nil {
		return nil, raw, false, err
	}
	if limit <= 0 {
		return nil, raw, false, nil
	}
	if c.hi != nil {
		newer, err := read(c.hi, false, limit)
		if err != nil {
			return nil, raw, false, err
		}
		if len(newer) > 0 {
			m := mark(newer[len(newer)-1])
			c.hi = &m
		}
		rows = newer
		if len(rows) == limit {
			return rows, c.String(), false, nil
		}
	}
	rest := limit - len(rows)
	older, err := read(c.lo, true, rest)
	if err != nil {
		return nil, raw, false, err
	}
	if len(older) > 0 {
		if c.hi == nil {
			m := mark(older[0])
			c.hi = &m
		}
		m := mark(older[len(older)-1])
		c.lo = &m
	}
	return append(rows, older...), c.String(), len(older) < rest, nil
}

// decidedAt parses a reader's normalised decided_at.
func decidedAt(m db.WatchmanMark) (time.Time, error) {
	t, err := time.Parse(time.RFC3339Nano, m.At)
	if err != nil {
		return time.Time{}, fmt.Errorf("watchman decided_at %q: %w", m.At, err)
	}
	return t.UTC(), nil
}
