package blocks

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"strings"
	"unicode/utf8"

	"watchtower/internal/db"
)

// clipMark ends a plain text clipped to its byte cap.
const clipMark = "…"

// PlainText is the card's body for a document: blocks separated by a blank
// line — a heading's text; a text block's markdown as is; a list's title,
// then a line per row "- title — subtitle [badge]" (or the empty text
// when it has no rows); a table's title, its column titles and a line per
// row, cells joined by " | "; a person's "name — role" and a line each;
// metrics "label: value" a line each; a link "title (url)". Action labels
// and actions blocks are left out. Longer than maxBytes, it is clipped on a
// rune boundary and ends with "…" (maxBytes ≤ 0 = no cap).
func PlainText(d Document, maxBytes int) string {
	var parts []string
	for _, b := range d.Blocks {
		if s := blockText(b); s != "" {
			parts = append(parts, s)
		}
	}
	return clip(strings.Join(parts, "\n\n"), maxBytes)
}

func blockText(b Block) string {
	var lines []string
	add := func(s string) {
		if s != "" {
			lines = append(lines, s)
		}
	}
	switch {
	case b.Heading != nil:
		add(b.Heading.Text)
	case b.Text != nil:
		add(b.Text.Markdown)
	case b.List != nil:
		add(b.List.Title)
		if len(b.List.Rows) == 0 {
			add(b.List.Empty)
		}
		for _, r := range b.List.Rows {
			line := "- " + joinNonEmpty(" — ", r.Title, r.Subtitle)
			if r.Badge != nil {
				line += " [" + r.Badge.Text + "]"
			}
			add(line)
		}
	case b.Table != nil:
		add(b.Table.Title)
		titles := make([]string, len(b.Table.Columns))
		for i, c := range b.Table.Columns {
			titles[i] = c.Title
		}
		add(strings.Join(titles, " | "))
		for _, row := range b.Table.Rows {
			cells := make([]string, len(row))
			for i, c := range row {
				cells[i] = c.Text
			}
			add(strings.Join(cells, " | "))
		}
	case b.Person != nil:
		add(joinNonEmpty(" — ", b.Person.Name, b.Person.Role))
		for _, l := range b.Person.Lines {
			add(l.Text)
		}
	case b.Metrics != nil:
		for _, m := range b.Metrics.Items {
			add(m.Label + ": " + m.Value)
		}
	case b.Link != nil:
		add(b.Link.Title + " (" + b.Link.URL + ")")
	}
	return strings.Join(lines, "\n")
}

func joinNonEmpty(sep string, parts ...string) string {
	var kept []string
	for _, p := range parts {
		if p != "" {
			kept = append(kept, p)
		}
	}
	return strings.Join(kept, sep)
}

// clip cuts s to at most maxBytes bytes on a rune boundary, ending in
// clipMark when it cut.
func clip(s string, maxBytes int) string {
	if maxBytes <= 0 || len(s) <= maxBytes {
		return s
	}
	n := max(maxBytes-len(clipMark), 0)
	for n > 0 && !utf8.RuneStart(s[n]) {
		n--
	}
	if len(clipMark) > maxBytes {
		return s[:n]
	}
	return s[:n] + clipMark
}

// DefaultPriority is the priority an inbox output without one is stored
// with (automation_outputs.priority).
const DefaultPriority = "medium"

// ContentHash is the hex SHA-256 of the canonical JSON of an inbox
// output's {title, body, blocks, priority, link, actions}: blocks is the
// stored document or null, actions [] when none. Like the document's other
// defaults, an omitted priority (”) is written out as DefaultPriority, so
// it and an explicit "medium" are one content.
func ContentHash(title, body string, doc *Document, priority, link string, actions []db.InboxAction) string {
	if priority == "" {
		priority = DefaultPriority
	}
	var blocks json.RawMessage
	if doc != nil {
		b, err := doc.Canonical()
		if err != nil {
			// Unreachable for a validated or decoded document (its raw
			// action data is JSON); the hash still differs from a card
			// without blocks.
			b = []byte(`"unmarshalable"`)
		}
		blocks = b
	}
	if actions == nil {
		actions = []db.InboxAction{}
	}
	b, err := marshal(struct {
		Title    string           `json:"title"`
		Body     string           `json:"body"`
		Blocks   json.RawMessage  `json:"blocks"`
		Priority string           `json:"priority"`
		Link     string           `json:"link"`
		Actions  []db.InboxAction `json:"actions"`
	}{title, body, blocks, priority, link, actions})
	if err != nil {
		// Unreachable: every field is a string or an already-marshaled
		// value.
		b = []byte("unmarshalable:" + err.Error())
	}
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}
