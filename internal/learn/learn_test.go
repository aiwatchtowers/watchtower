package learn

import (
	"reflect"
	"strings"
	"testing"

	"watchtower/docs/guide"
)

// TestGuideCardsValid fails on any invalid card in the shipped guide.
func TestGuideCardsValid(t *testing.T) {
	cat, err := Load()
	if err != nil {
		t.Fatalf("guide cards are invalid:\n%v", err)
	}
	for _, c := range cat.Cards {
		if c.Page == "" {
			t.Errorf("card %q has no page", c.ID)
		}
	}
}

func TestSignalsPinned(t *testing.T) {
	want := []string{
		"meeting.recorded", "chat.used", "workbench.bound", "reaction.used",
		"automation.created", "memory.on", "calendar.connected", "jira.connected",
		"linear.connected", "confluence.connected", "iphone.paired", "dictation.used",
	}
	if !reflect.DeepEqual(Signals, want) {
		t.Fatalf("Signals = %v (the Desktop's LearnSignal pins the same list)", Signals)
	}
}

const validBody = `id: quick-capture
title: Capture an idea by voice
text: Press the key anywhere, say it, and it lands in Ideas.
area: meetings
level: next
kind: feature
since: 0.24.0`

func page(path string, sections ...guide.Section) guide.Page {
	return guide.Page{Path: path, Title: "T", Sections: sections}
}

func section(anchor string, cards ...string) guide.Section {
	return guide.Section{Heading: anchor, Anchor: anchor, Cards: cards}
}

func with(lines ...string) string { return validBody + "\n" + strings.Join(lines, "\n") }

func replace(body, key, line string) string {
	var out []string
	for _, l := range strings.Split(body, "\n") {
		if strings.HasPrefix(l, key+":") {
			if line != "" {
				out = append(out, line)
			}
			continue
		}
		out = append(out, l)
	}
	return strings.Join(out, "\n")
}

func TestLoadValidCard(t *testing.T) {
	body := with("action: hotkey:quick-capture", "done_when: dictation.used", "requires: feature:ideas", "", "replaces: [old-capture, older-capture]", "changed: Now from anywhere.")
	cat, err := load([]guide.Page{page("features/voice.md", section("quick-capture", body))})
	if err != nil {
		t.Fatal(err)
	}
	want := Card{
		ID: "quick-capture", Title: "Capture an idea by voice",
		Text: "Press the key anywhere, say it, and it lands in Ideas.",
		Area: "meetings", Level: "next", Kind: "feature", Since: "0.24.0",
		Action: "hotkey:quick-capture", Changed: "Now from anywhere.",
		DoneWhen: "dictation.used", Requires: "feature:ideas",
		Replaces: []string{"old-capture", "older-capture"},
		Page:     "features/voice.md", Anchor: "quick-capture", HotkeyLabel: "⌃⌥D",
	}
	if len(cat.Cards) != 1 || !reflect.DeepEqual(cat.Cards[0], want) {
		t.Fatalf("cards = %+v", cat.Cards)
	}
	if !reflect.DeepEqual(cat.Retired, []string{"old-capture", "older-capture"}) {
		t.Errorf("retired = %v", cat.Retired)
	}
}

func TestLoadEmptyOptionalsAndNoCards(t *testing.T) {
	cat, err := load([]guide.Page{page("a.md", section("s", validBody))})
	if err != nil {
		t.Fatal(err)
	}
	c := cat.Cards[0]
	if c.Replaces == nil || len(c.Replaces) != 0 || c.Action != "" || c.HotkeyLabel != "" {
		t.Errorf("card = %+v", c)
	}
	cat, err = load([]guide.Page{page("a.md", section("s"))})
	if err != nil || cat.Cards == nil || cat.Retired == nil {
		t.Errorf("empty guide: cat = %+v, err = %v", cat, err)
	}
}

func TestLoadRejects(t *testing.T) {
	long := strings.Repeat("x", 121)
	for name, tc := range map[string]struct{ body, want string }{
		"unknown key":       {with("color: red"), `card "quick-capture": unknown key "color"`},
		"duplicate key":     {with("area: tasks"), `duplicate key "area"`},
		"missing key":       {replace(validBody, "since", ""), `missing required key "since"`},
		"missing id":        {replace(validBody, "id", ""), `a.md: card 1 under "s": missing required key "id"`},
		"not key value":     {with("just text"), `is not "key: value"`},
		"empty value":       {with("action:"), `key "action" has no value`},
		"bad id":            {replace(validBody, "id", "id: Quick_Capture"), `is not kebab-case`},
		"long title":        {replace(validBody, "title", "title: "+strings.Repeat("é", 41)), `title is 41 characters (max 40)`},
		"long text":         {replace(validBody, "text", "text: "+long), `text is 121 characters (max 120)`},
		"long changed":      {with("replaces: [a-b]", "changed: "+long), `changed is 121 characters`},
		"area":              {replace(validBody, "area", "area: music"), `area "music" is not one of`},
		"level":             {replace(validBody, "level", "level: expert"), `level "expert"`},
		"kind":              {replace(validBody, "kind", "kind: video"), `kind "video"`},
		"since":             {replace(validBody, "since", "since: 0.24"), `since "0.24" is not X.Y.Z or next`},
		"signal":            {with("done_when: dayplan.opened"), `done_when "dayplan.opened"`},
		"action kind":       {with("action: open:home"), `kind is not nav, connect, turnOn, chat or hotkey`},
		"action no value":   {with("action: nav"), `has no value after its kind`},
		"nav screen":        {with("action: nav:settings"), `unknown screen`},
		"connect source":    {with("action: connect:teams"), `unknown source`},
		"turnOn unknown":    {with("action: turnOn:nope"), `unknown feature id`},
		"turnOn core":       {with("action: turnOn:chat"), `has no switch`},
		"chat prompt":       {with("action: chat:" + long), `prompt is 121 characters`},
		"hotkey":            {with("action: hotkey:launch"), `unknown hotkey name`},
		"requires grammar":  {with("requires: ideas"), `is not feature:<id> or source:<name>`},
		"requires feature":  {with("requires: feature:nope"), `unknown feature id`},
		"requires source":   {with("requires: source:teams"), `unknown source`},
		"changed alone":     {with("changed: It moved."), `changed needs replaces`},
		"replaces syntax":   {with("replaces: a, b"), `is not a [id, id] list`},
		"replaces empty id": {with("replaces: [a, ]"), `has an empty id`},
		"replaces self":     {with("replaces: [quick-capture]"), `replaces its own id`},
		"replaces twice":    {with("replaces: [a, a]"), `replaces "a" twice`},
		"replaces bad id":   {with("replaces: [A]"), `replaces id "A" is not kebab-case`},
	} {
		t.Run(name, func(t *testing.T) {
			_, err := load([]guide.Page{page("a.md", section("s", tc.body))})
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("err = %v, want it to contain %q", err, tc.want)
			}
		})
	}
}

func TestLoadAcceptsNextAndEachActionKind(t *testing.T) {
	for _, action := range []string{"nav:projects", "nav:ideas", "connect:jira", "turnOn:memory", "chat:How do I start?", "hotkey:help"} {
		body := with("action: "+action, "requires: source:slack")
		body = replace(body, "since", "since: next")
		if _, err := load([]guide.Page{page("a.md", section("s", body))}); err != nil {
			t.Errorf("%s: %v", action, err)
		}
	}
}

func TestLoadDuplicateIDAcrossPages(t *testing.T) {
	_, err := load([]guide.Page{page("a.md", section("s", validBody)), page("b.md", section("s", validBody))})
	if err == nil || !strings.Contains(err.Error(), `b.md: card "quick-capture": id already used on a.md`) {
		t.Fatalf("err = %v", err)
	}
}

func TestLoadRetiredIDStillACard(t *testing.T) {
	old := replace(validBody, "id", "id: old-capture")
	_, err := load([]guide.Page{page("a.md", section("s", with("replaces: [old-capture]"), old))})
	if err == nil || !strings.Contains(err.Error(), `card "old-capture": id is retired`) {
		t.Fatalf("err = %v", err)
	}
}

func TestLoadUnclosedBlock(t *testing.T) {
	s := guide.Section{Heading: "s", Anchor: "s", Text: "<!-- learn\nid: a"}
	_, err := load([]guide.Page{page("a.md", s)})
	if err == nil || !strings.Contains(err.Error(), "never closes") {
		t.Fatalf("err = %v", err)
	}
}

func TestLoadCollectsEveryError(t *testing.T) {
	bad := replace(replace(validBody, "area", "area: music"), "kind", "kind: video")
	_, err := load([]guide.Page{page("a.md", section("s", bad)), page("b.md", section("s", with("color: red")))})
	if err == nil {
		t.Fatal("no error")
	}
	for _, want := range []string{`area "music"`, `kind "video"`, `b.md: card "quick-capture": unknown key "color"`} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("err lacks %q:\n%v", want, err)
		}
	}
}
