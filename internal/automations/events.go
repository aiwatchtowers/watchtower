package automations

import (
	"encoding/json"
	"fmt"
	"maps"
	"path"
	"strings"
)

// Event is one content-free sync event (spec §8): its type and its fields —
// ids, labels, enums and counts only, never message text, subject, summary,
// title or body.
type Event struct {
	Type   string
	Fields map[string]any
}

// MarshalJSON writes the event flat, {"type": …, <fields>}, the shape of one
// trigger.events element; Type wins over a stray "type" field.
func (e Event) MarshalJSON() ([]byte, error) {
	flat := make(map[string]any, len(e.Fields)+1)
	maps.Copy(flat, e.Fields)
	flat["type"] = e.Type
	data, err := json.Marshal(flat)
	if err != nil {
		return nil, fmt.Errorf("marshalling %s event: %w", e.Type, err)
	}
	return data, nil
}

// EventFields are, per event type, the string fields a trigger.event.where may
// match; count is carried but not matchable.
var EventFields = map[string][]string{
	"slack.new_messages":      {"account", "channel", "channel_id"},
	"gmail.new_messages":      {"account", "provider"},
	"jira.issue_changed":      {"account", "key", "project", "field"},
	"calendar.event_changed":  {"account", "event_id", "change"},
	"confluence.page_changed": {"space", "page_id"},
	SlackReactionAdded:        {"account", "channel_id", "emoji"},
}

// MatchWhere reports whether e satisfies every where key: the event carries
// the field as a string and it equals the pattern case-insensitively or
// matches it as a path.Match glob (both lower-cased). An empty where matches
// every event. Matching is a filter, never a permission.
func MatchWhere(where map[string]string, e Event) bool {
	for key, pattern := range where {
		value, ok := e.Fields[key].(string)
		if !ok || !matchValue(pattern, value) {
			return false
		}
	}
	return true
}

func matchValue(pattern, value string) bool {
	p, v := strings.ToLower(pattern), strings.ToLower(value)
	if p == v {
		return true
	}
	ok, err := path.Match(p, v)
	return err == nil && ok
}

// validGlob reports whether pattern is a well-formed path.Match glob.
func validGlob(pattern string) bool {
	_, err := path.Match(strings.ToLower(pattern), "")
	return err == nil
}
