// Package kb is the knowledge-search index: a mechanical, derived, rebuildable
// full-text index over raw and derived Watchtower data (spec
// docs/superpowers/specs/2026-09-26-knowledge-search-design.md). It makes no
// model calls (KB-02) and never writes a source table (KB-01).
package kb

import (
	"encoding/json"
	"regexp"
	"strings"
	"time"
)

var yoReplacer = strings.NewReplacer("ё", "е", "Ё", "Е")

// Normalize applies the index/query text normalization shared by both sides:
// FTS5's remove_diacritics does not fold ё to е, so we do.
func Normalize(s string) string { return yoReplacer.Replace(s) }

var (
	reUserMention = regexp.MustCompile(`<@([UW][A-Z0-9]+)(?:\|([^>]*))?>`)
	reChannelRef  = regexp.MustCompile(`<#C[A-Z0-9]+(?:\|([^>]*))?>`)
	reSpecial     = regexp.MustCompile(`<!([a-z]+)(?:\|[^>]*)?>`)
	reLabelledURL = regexp.MustCompile(`<(https?://[^|>]+|mailto:[^|>]+)\|([^>]+)>`)
	reBareURL     = regexp.MustCompile(`<(https?://[^>]+|mailto:[^>]+)>`)
)

// ResolveSlackMarkup turns Slack's wire markup into readable, searchable text.
// userName resolves a raw user id ("U123"); "" means unknown and the id stays.
func ResolveSlackMarkup(text string, userName func(rawID string) string) string {
	text = reUserMention.ReplaceAllStringFunc(text, func(m string) string {
		sub := reUserMention.FindStringSubmatch(m)
		if sub[2] != "" {
			return "@" + sub[2]
		}
		if name := userName(sub[1]); name != "" {
			return "@" + name
		}
		return "@" + sub[1]
	})
	text = reChannelRef.ReplaceAllStringFunc(text, func(m string) string {
		sub := reChannelRef.FindStringSubmatch(m)
		if sub[1] != "" {
			return "#" + sub[1]
		}
		return "#channel"
	})
	text = reSpecial.ReplaceAllString(text, "@$1")
	text = reLabelledURL.ReplaceAllStringFunc(text, func(m string) string {
		sub := reLabelledURL.FindStringSubmatch(m)
		return sub[2] + " (" + strings.TrimPrefix(sub[1], "mailto:") + ")"
	})
	text = reBareURL.ReplaceAllStringFunc(text, func(m string) string {
		sub := reBareURL.FindStringSubmatch(m)
		return strings.TrimPrefix(sub[1], "mailto:")
	})
	return text
}

// jsonTextKeys are the object keys whose string values are prose worth
// indexing; everything else (authors, ts, statuses, importance) is metadata.
var jsonTextKeys = map[string]bool{
	"text": true, "title": true, "summary": true, "description": true, "decision": true,
	"question": true, "item": true, "what": true, "essence": true, "quote": true, "outcome": true,
}

// jsonTexts extracts the prose strings of a JSON document in document order:
// top-level strings, strings inside arrays, and allow-listed object keys.
// Invalid or empty JSON yields nil.
func jsonTexts(raw string) []string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil
	}
	dec := json.NewDecoder(strings.NewReader(raw))
	var out []string
	var walk func(take bool) bool
	walk = func(take bool) bool {
		tok, err := dec.Token()
		if err != nil {
			return false
		}
		switch v := tok.(type) {
		case string:
			if take && strings.TrimSpace(v) != "" {
				out = append(out, v)
			}
		case json.Delim:
			switch v {
			case '[':
				for dec.More() {
					if !walk(true) {
						return false
					}
				}
				_, err = dec.Token()
				return err == nil
			case '{':
				for dec.More() {
					kt, err := dec.Token()
					if err != nil {
						return false
					}
					key, _ := kt.(string)
					if !walk(jsonTextKeys[key]) {
						return false
					}
				}
				_, err = dec.Token()
				return err == nil
			}
		}
		return true
	}
	if !walk(true) {
		return nil
	}
	return out
}

var timeLayouts = []string{
	time.RFC3339Nano,
	"2006-01-02T15:04:05.000-0700",
	"2006-01-02T15:04:05-0700",
	"2006-01-02T15:04:05",
	"2006-01-02 15:04:05",
	"2006-01-02",
}

// parseTime accepts the timestamp shapes our source tables hold; zero on failure.
func parseTime(s string) time.Time {
	s = strings.TrimSpace(s)
	for _, l := range timeLayouts {
		if t, err := time.Parse(l, s); err == nil {
			return t.UTC()
		}
	}
	return time.Time{}
}
