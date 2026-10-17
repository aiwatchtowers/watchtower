package automations

import (
	"encoding/json"
	"reflect"
	"slices"
	"strings"
	"testing"
)

func TestBus_WhereFilterAndGlob(t *testing.T) {
	ev := func(fields map[string]any) Event { return Event{Type: "slack.new_messages", Fields: fields} }
	releases := ev(map[string]any{"account": "work", "channel": "Releases", "channel_id": "C1", "count": 3})
	cases := []struct {
		label string
		where map[string]string
		e     Event
		want  bool
	}{
		{"case-insensitive equality", map[string]string{"channel": "releases"}, releases, true},
		{"no prefix match", map[string]string{"channel": "release"}, releases, false},
		{"glob", map[string]string{"channel": "rel*"}, ev(map[string]any{"channel": "releases"}), true},
		{"glob upper pattern", map[string]string{"channel": "REL*"}, releases, true},
		{"glob miss", map[string]string{"channel": "dev*"}, releases, false},
		{"both keys match", map[string]string{"account": "work", "channel": "*"}, releases, true},
		{"one key misses", map[string]string{"account": "work", "channel": "*"}, ev(map[string]any{"account": "home", "channel": "releases"}), false},
		{"key absent from event", map[string]string{"account": "work", "channel": "*"}, ev(map[string]any{"channel": "releases"}), false},
		{"empty where", map[string]string{}, releases, true},
		{"nil where", nil, ev(nil), true},
		{"non-string field never matches", map[string]string{"count": "3"}, releases, false},
	}
	for _, c := range cases {
		if got := MatchWhere(c.where, c.e); got != c.want {
			t.Errorf("%s: MatchWhere(%v) = %v, want %v", c.label, c.where, got, c.want)
		}
	}
}

func TestEvent_MarshalsFlat(t *testing.T) {
	e := Event{Type: "jira.issue_changed", Fields: map[string]any{"account": "work", "key": "PAY-1", "project": "PAY", "field": "status"}}
	data, err := json.Marshal(e)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var got map[string]any
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatalf("unmarshal %s: %v", data, err)
	}
	want := map[string]any{"type": "jira.issue_changed", "account": "work", "key": "PAY-1", "project": "PAY", "field": "status"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("marshalled %s, want %v", data, want)
	}

	// The event's type wins over a stray "type" field; no fields is just the type.
	data, err = json.Marshal(Event{Type: "confluence.page_changed", Fields: map[string]any{"type": "x"}})
	if err != nil || string(data) != `{"type":"confluence.page_changed"}` {
		t.Errorf("type override: %s, %v", data, err)
	}
	data, err = json.Marshal(Event{Type: "gmail.new_messages"})
	if err != nil || string(data) != `{"type":"gmail.new_messages"}` {
		t.Errorf("no fields: %s, %v", data, err)
	}
}

// contentFreeNames are the only field names an event may carry: ids, labels,
// enums and counts — never message text, subject, summary, title or body.
var contentFreeNames = []string{
	"type", "account", "provider", "channel", "channel_id", "key", "project",
	"field", "event_id", "change", "space", "page_id", "count", "message_ts", "emoji",
}

// contentMarker is planted in every source fixture's text, subject, summary,
// title, description and location; no serialised event may contain it.
const contentMarker = "CONTENT-MARKER-acme"

// noContentCases lists each source's emitted events, built from fixtures
// carrying contentMarker. Tasks 4–6 add one case per source.
var noContentCases = []struct {
	source string
	events func(t *testing.T) []Event
}{
	{"synthetic", func(*testing.T) []Event {
		return []Event{{Type: "slack.new_messages", Fields: map[string]any{"account": "work", "channel": "releases", "channel_id": "C1", "count": 2}}}
	}},
	{"slack", slackContentEvents},
	{"reaction", func(*testing.T) []Event {
		return []Event{ReactionEvent("acme", "1:C1", "1700000000.000100", "eyes")}
	}},
	{"mail", mailContentEvents},
	{"jira", jiraContentEvents},
	{"calendar", calendarContentEvents},
	{"confluence", confluenceContentEvents},
}

func TestBus_EventsCarryNoContent(t *testing.T) {
	for typ, fields := range EventFields {
		if !slices.Contains(EventTypes, typ) {
			t.Errorf("EventFields names unknown type %q", typ)
		}
		for _, f := range fields {
			if !slices.Contains(contentFreeNames, f) {
				t.Errorf("%s field %q is not on the content-free allowlist", typ, f)
			}
		}
	}
	for _, typ := range EventTypes {
		if _, ok := EventFields[typ]; !ok {
			t.Errorf("EventFields has no entry for %q", typ)
		}
	}
	for _, f := range []string{"count", "channel_id"} {
		if !slices.Contains(contentFreeNames, f) {
			t.Errorf("%q missing from the allowlist", f)
		}
	}
	for _, c := range noContentCases {
		for _, e := range c.events(t) {
			assertEventContentFree(t, c.source, e)
		}
	}
}

func assertEventContentFree(t *testing.T, source string, e Event) {
	t.Helper()
	data, err := json.Marshal(e)
	if err != nil {
		t.Fatalf("%s: marshal: %v", source, err)
	}
	if strings.Contains(string(data), contentMarker) {
		t.Errorf("%s: event carries content: %s", source, data)
	}
	if !slices.Contains(EventTypes, e.Type) {
		t.Errorf("%s: unknown event type %q", source, e.Type)
	}
	for name := range e.Fields {
		if !slices.Contains(contentFreeNames, name) {
			t.Errorf("%s: %s field %q is not on the content-free allowlist", source, e.Type, name)
		}
	}
}

func TestReactionEvent_FieldsAndWhere(t *testing.T) {
	e := ReactionEvent("acme", "1:C1", "1700000000.000100", "eyes")
	data, err := json.Marshal(e)
	if err != nil {
		t.Fatal(err)
	}
	want := `{"account":"acme","channel_id":"1:C1","emoji":"eyes","message_ts":"1700000000.000100","type":"slack.reaction_added"}`
	if string(data) != want {
		t.Errorf("marshalled %s, want %s", data, want)
	}
	if len(e.Fields) != 4 {
		t.Errorf("event carries %d fields, want 4 (plus type)", len(e.Fields))
	}
	for where, match := range map[string]bool{"eyes": true, "EYES": true, "white_*": false} {
		if got := MatchWhere(map[string]string{"emoji": where}, e); got != match {
			t.Errorf("where emoji %q = %v, want %v", where, got, match)
		}
	}
	frontmatter := "name: T\ntrigger:\n  event:\n    type: slack.reaction_added\n    where: {message_ts: x}\n"
	wantParseError(t, recipeWith(frontmatter, "x\n"), "message_ts")
}

func TestReactionEvent_WhereEmojiColonsNormalised(t *testing.T) {
	frontmatter := "name: T\ntrigger:\n  event:\n    type: slack.reaction_added\n    where: {emoji: \":eyes:\"}\n"
	r := mustParse(t, recipeWith(frontmatter, "x\n"), Scope{Kind: ScopePersonal})
	e := ReactionEvent("acme", "1:C1", "1700000000.000100", "eyes")
	if !MatchWhere(r.Trigger.Event.Where, e) {
		t.Errorf("where %v does not match the eyes event", r.Trigger.Event.Where)
	}
}
