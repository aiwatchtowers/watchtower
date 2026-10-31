// Package sources holds the hub's database-backed slice sources (spec §9,
// Plan 1b): each a capped projection of watchtower.db equal to the Swift
// hub's slice of the same kind, encoded with wire.Marshal so the phone's Kit
// decodes the same bytes. Never `SELECT *`: every column read is named, and
// a raw column the phone must not see (folder_path, claude_session_id, the
// hook columns) is never put in a payload.
package sources

import (
	"log"
	"strings"
	"sync"
	"time"

	"github.com/rivo/uniseg"

	"watchtower/internal/hub/wire"
)

// ellipsis ends a clipped text (SliceClip.ellipsis).
const ellipsis = "…"

// clipText is SliceClip.text: value cut to at most limit grapheme clusters,
// the ellipsis included, and a true flag; an unclipped value has a nil flag,
// so the encoder omits the `<field>_clipped` key.
func clipText(value string, limit int) (string, *bool) {
	if uniseg.GraphemeClusterCount(value) <= limit {
		return value, nil
	}
	clipped := true
	if limit <= 0 {
		return "", &clipped
	}
	var b strings.Builder
	g := uniseg.NewGraphemes(value)
	for n := 0; n < limit-1 && g.Next(); n++ {
		b.WriteString(g.Str())
	}
	b.WriteString(ellipsis)
	return b.String(), &clipped
}

// clipList is SliceClip.list: the first limit items and how many were left
// out (nil when none, so `<list>_more` is omitted).
func clipList[T any](items []T, limit int) ([]T, *int) {
	if len(items) <= limit {
		return items, nil
	}
	kept := max(limit, 0)
	more := len(items) - kept
	return items[:kept], &more
}

// parseDate is SliceDate.parse: the database's UTC datetime strings
// (`YYYY-MM-DDTHH:MM:SSZ`, optionally with a fraction); nil for "" or an
// unparsable value.
func parseDate(value string) *wire.Time {
	if value == "" {
		return nil
	}
	t, err := time.Parse(time.RFC3339Nano, value)
	if err != nil {
		return nil
	}
	return &wire.Time{Time: t.UTC()}
}

// warnedDates is record + "." + field for every requiredDate that logged.
var warnedDates sync.Map

// requiredDate is SliceDate.required: an unparsable stamp (never written by
// Go or the Desktop) becomes 1970 rather than a record the phone cannot
// decode, logged once per record and field (the record name is a kind and an
// id, the field a column name: no content, FILES-01).
func requiredDate(value, field, record string) wire.Time {
	if t := parseDate(value); t != nil {
		return *t
	}
	if _, seen := warnedDates.LoadOrStore(record+"."+field, true); !seen {
		log.Printf("hub slices: unparsable %s on %s; published as 1970", field, record)
	}
	return wire.Time{Time: time.Unix(0, 0).UTC()}
}

// dateWarned reports whether requiredDate logged this record's field (the
// test seam).
func dateWarned(field, record string) bool {
	_, ok := warnedDates.Load(record + "." + field)
	return ok
}

// sqliteDate is a time bound into SQL for julianday() the way GRDB binds a
// Swift Date: UTC "YYYY-MM-DD HH:MM:SS.SSS".
func sqliteDate(t time.Time) string { return t.UTC().Format("2006-01-02 15:04:05.000") }

// askVisible is OwnerAskQueries.notInSpecLoop over alias "a": it drops the spec
// review author loop's hidden asks from an owner-facing read of owner_asks
// aliased "a".
const askVisible = "NOT EXISTS (SELECT 1 FROM spec_reviews sr WHERE sr.ask_id = a.id AND sr.loop = 'author')"
