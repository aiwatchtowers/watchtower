package inboxlegacy

import (
	"strings"
	"testing"

	"watchtower/internal/automations/blocks"
	"watchtower/internal/tower/api"
)

// project projects s in UTC and decodes the document back.
func project(t *testing.T, s api.LegacySection) *blocks.Document {
	t.Helper()
	out, err := Project(s)
	if err != nil {
		t.Fatalf("Project: %v", err)
	}
	d, err := blocks.Decode(out)
	if err != nil {
		t.Fatalf("decode %s: %v", out, err)
	}
	return d
}

func lists(d *blocks.Document) []*blocks.List {
	var out []*blocks.List
	for _, b := range d.Blocks {
		if b.List != nil {
			out = append(out, b.List)
		}
	}
	return out
}

func texts(d *blocks.Document) []string {
	var out []string
	for _, b := range d.Blocks {
		switch {
		case b.Heading != nil:
			out = append(out, "# "+b.Heading.Text)
		case b.Text != nil:
			out = append(out, b.Text.Markdown)
		}
	}
	return out
}

func wantRef(t *testing.T, r blocks.ListRow, kind string, id int64) {
	t.Helper()
	if r.Ref == nil || r.Ref.Kind != kind || r.Ref.ID != id {
		t.Fatalf("row %q ref %+v, want %s %d", r.Title, r.Ref, kind, id)
	}
}

func TestProject_MorningBrief(t *testing.T) {
	d := project(t, api.LegacySection{Kind: api.LegacyMorningBrief,
		Items: []api.LegacyItem{
			{RefKind: api.RefPlanItem, ID: 1, Title: "Review ACME-412 fix", Stamp: "2026-11-12T09:00:00Z", Done: true},
			{RefKind: api.RefPlanItem, ID: 2, Title: "Standup", Stamp: "2026-11-12T09:30:00Z", End: "2026-11-12T09:45:00Z"},
			{RefKind: api.RefPlanItem, ID: 3, Title: "Sign off the checklist", Subtitle: "from Waiting for me"},
		},
		Attention: []api.LegacyAttention{{Text: "Release 2.0 waits on your sign-off", Reason: "docs link is red", Priority: "high"}},
	})
	if got := strings.Join(texts(d), "|"); got != "# Plan · 1 of 3|# Attention" {
		t.Fatalf("headings %q", got)
	}
	ls := lists(d)
	if len(ls) != 2 {
		t.Fatalf("%d lists, want plan and attention", len(ls))
	}
	plan := ls[0].Rows
	if plan[0].Title != "✓ Review ACME-412 fix" || plan[1].Title != "Standup" {
		t.Errorf("plan rows %+v", plan)
	}
	if plan[2].Subtitle != "from Waiting for me" {
		t.Errorf("backlog row %+v", plan[2])
	}
	for _, r := range plan {
		// No clock in the document: the phone draws times in its own zone.
		if r.Badge != nil || strings.Contains(r.Title+r.Subtitle, ":") {
			t.Errorf("row %+v carries a time", r)
		}
	}
	for i, r := range plan {
		wantRef(t, r, blocks.RefPlanItem, int64(i+1))
	}
	att := ls[1].Rows[0]
	if att.Title != "Release 2.0 waits on your sign-off" || att.Subtitle != "docs link is red" || att.Tone != "danger" || att.Ref != nil {
		t.Errorf("attention row %+v", att)
	}
}

func TestProject_MorningBriefPlaceholder(t *testing.T) {
	d := project(t, api.LegacySection{Kind: api.LegacyMorningBrief})
	if got := texts(d); len(got) != 1 || got[0] != noPlan {
		t.Fatalf("texts %q", got)
	}
}

func TestProject_TracksFlagsStoppedInsideTheOneCard(t *testing.T) {
	d := project(t, api.LegacySection{Kind: api.LegacyTracks, Items: []api.LegacyItem{
		{RefKind: api.RefTrack, ID: 4, Title: "Budget approval for Q1", Subtitle: "Track", Preview: "2 new", Unread: true},
		{RefKind: api.RefTrack, ID: 5, Title: "Office move", Subtitle: "Track"},
		{RefKind: api.RefTrack, ID: 6, Title: "Old thread", Subtitle: "Track", Stopped: true},
	}})
	ls := lists(d)
	if len(ls) != 2 || ls[0].Title != "" || ls[1].Title != "Stopped · 1" {
		t.Fatalf("lists %+v", ls)
	}
	first := ls[0].Rows[0]
	if first.Badge == nil || first.Badge.Text != "2 new" || first.Badge.Tone != "accent" || first.Subtitle != "Track" {
		t.Errorf("active row %+v", first)
	}
	if ls[0].Rows[1].Badge != nil {
		t.Errorf("a track with nothing new has a badge: %+v", ls[0].Rows[1])
	}
	wantRef(t, ls[0].Rows[0], blocks.RefTrack, 4)
	wantRef(t, ls[1].Rows[0], blocks.RefTrack, 6)
}

func TestProject_IdeaFinder(t *testing.T) {
	d := project(t, api.LegacySection{Kind: api.LegacyIdeas, Items: []api.LegacyItem{
		{RefKind: api.RefIdea, ID: 7, Title: "Self-serve release notes", Subtitle: "Idea · proposed", Preview: "One page per release", Unread: true},
		{RefKind: api.RefIdea, ID: 8, Title: "Shared on-call calendar", Subtitle: "Idea · active"},
	}})
	ls := lists(d)
	if len(ls) != 2 || ls[0].Title != "To judge · 1" || ls[1].Title != "Recent" {
		t.Fatalf("lists %+v", ls)
	}
	if r := ls[0].Rows[0]; r.Subtitle != "Idea · proposed — One page per release" {
		t.Errorf("to judge row %+v", r)
	}
	wantRef(t, ls[0].Rows[0], blocks.RefIdea, 7)
	wantRef(t, ls[1].Rows[0], blocks.RefIdea, 8)
}

func TestProject_ThreadBriefsOneRowPerBrief(t *testing.T) {
	d := project(t, api.LegacySection{Kind: api.LegacyThreadBriefs, Items: []api.LegacyItem{
		{RefKind: api.RefAction, ID: 11, Title: "Release thread", Subtitle: "Thread brief", Preview: "Ship Friday"},
		{RefKind: api.RefAction, ID: 12, Title: "Hiring thread", Subtitle: "Thread brief", Preview: "Panel moved"},
	}})
	ls := lists(d)
	if len(ls) != 1 || len(ls[0].Rows) != 2 {
		t.Fatalf("lists %+v", ls)
	}
	if r := ls[0].Rows[0]; r.Title != "Release thread" || r.Subtitle != "Ship Friday" {
		t.Errorf("row %+v", r)
	}
	wantRef(t, ls[0].Rows[1], blocks.RefAction, 12)
}

func TestProject_MessagesIsANoticeOnYourMac(t *testing.T) {
	d := project(t, api.LegacySection{Kind: api.LegacyMessages, Items: []api.LegacyItem{
		{RefKind: api.RefInboxItem, ID: 1, Title: "a"}, {RefKind: api.RefInboxItem, ID: 2, Title: "b"},
	}})
	if got := strings.Join(texts(d), "|"); got != "2 waiting · Mentions, DMs and replies|On your Mac" {
		t.Fatalf("texts %q", got)
	}
	if len(lists(d)) != 0 {
		t.Error("the Messages notice lists its rows")
	}
}

func TestProject_UnknownKindFails(t *testing.T) {
	if _, err := Project(api.LegacySection{Kind: "future"}); err == nil {
		t.Fatal("an unknown kind projected")
	}
}

// TestProject_PlanItemNeedsTheHubOption: the projection's plan_item ref
// validates only with the hub's option; a script's options refuse it.
func TestProject_PlanItemNeedsTheHubOption(t *testing.T) {
	raw, err := document(api.LegacySection{Kind: api.LegacyMorningBrief, Items: []api.LegacyItem{
		{RefKind: api.RefPlanItem, ID: 1, Title: "Standup"},
	}}, blocks.MaxListRows)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := blocks.Validate("inboxlegacy", raw, blocks.Options{BuiltIn: true}); err == nil {
		t.Fatal("a plan_item ref validated without PlanItemRefs")
	}
	if _, err := blocks.Validate("inboxlegacy", raw, validateOptions); err != nil {
		t.Fatalf("with the hub's option: %v", err)
	}
}

// TestProject_LongListsFitTheCaps: a list past the row and byte caps keeps
// its first rows and says how many more are on the Mac; long words are
// clipped to the field limits.
func TestProject_LongListsFitTheCaps(t *testing.T) {
	long := strings.Repeat("word ", 400)
	items := make([]api.LegacyItem, 450)
	for i := range items {
		items[i] = api.LegacyItem{RefKind: api.RefIdea, ID: int64(i + 1), Title: long, Subtitle: "Idea · active", Preview: long}
	}
	out, err := Project(api.LegacySection{Kind: api.LegacyIdeas, Items: items})
	if err != nil {
		t.Fatal(err)
	}
	if len(out) > blocks.MaxBlocksBytes {
		t.Fatalf("%d bytes, over the cap", len(out))
	}
	d, err := blocks.Decode(out)
	if err != nil {
		t.Fatal(err)
	}
	kept := len(lists(d)[0].Rows)
	if kept == 0 || kept >= len(items) {
		t.Fatalf("kept %d rows", kept)
	}
	if got := texts(d); len(got) != 1 || got[0] != MoreOnYourMac(len(items)-kept) {
		t.Fatalf("texts %q", got)
	}
}

func TestUnprojectedSendsTheOwnerToTheMac(t *testing.T) {
	d, err := blocks.Decode(Unprojected())
	if err != nil {
		t.Fatal(err)
	}
	if got := texts(d); len(got) != 1 || got[0] != unprojectedLine {
		t.Fatalf("texts %q", got)
	}
}
