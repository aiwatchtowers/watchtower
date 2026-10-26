package guide

import (
	"strings"
	"testing"
)

func TestParseLearnCards(t *testing.T) {
	body := strings.Join([]string{
		"# Page",
		"Intro.",
		"<!-- learn",
		"id: intro-card",
		"-->",
		"## First",
		"<!-- learn",
		"id: a",
		"title: A",
		"-->",
		"Text of first.",
		"  <!-- learn  ",
		"id: b",
		"  -->",
		"## Second",
		"<!-- learn: none -->",
		"Text of second.",
		"```",
		"<!-- learn",
		"id: in-fence",
		"-->",
		"```",
	}, "\n")
	p := parse("x.md", body)
	if len(p.Sections) != 3 {
		t.Fatalf("got %d sections: %+v", len(p.Sections), p.Sections)
	}
	intro, first, second := p.Sections[0], p.Sections[1], p.Sections[2]
	if intro.Text != "Intro." || len(intro.Cards) != 1 || intro.Cards[0] != "id: intro-card" {
		t.Errorf("intro = %+v", intro)
	}
	if first.Text != "Text of first." {
		t.Errorf("first text = %q", first.Text)
	}
	if got, want := strings.Join(first.Cards, "|"), "id: a\ntitle: A|id: b"; got != want {
		t.Errorf("first cards = %q, want %q", got, want)
	}
	if len(second.Cards) != 0 {
		t.Errorf("fenced block became a card: %q", second.Cards)
	}
	if strings.Contains(second.Text, "learn: none") || !strings.Contains(second.Text, "id: in-fence") {
		t.Errorf("second text = %q", second.Text)
	}
}

func TestParseSectionWithOnlyCardsIsKept(t *testing.T) {
	p := parse("x.md", "# T\n<!-- learn\nid: a\n-->\n")
	if len(p.Sections) != 1 || len(p.Sections[0].Cards) != 1 || p.Sections[0].Text != "" {
		t.Fatalf("sections = %+v", p.Sections)
	}
}

func TestParseUnclosedCardStaysText(t *testing.T) {
	p := parse("x.md", "# T\n## S\n<!-- learn\nid: a\nmore text\n")
	s := p.Sections[0]
	if len(s.Cards) != 0 || !strings.Contains(s.Text, "id: a") {
		t.Fatalf("section = %+v", s)
	}
	if !HasStrayCardOpen(s.Text) {
		t.Error("stray opening line not reported")
	}
	if HasStrayCardOpen("```\n<!-- learn\n```") {
		t.Error("fenced opening line reported")
	}
}

func TestStripCards(t *testing.T) {
	in := "# T\n<!-- learn\nid: a\n-->\nkeep\n<!-- learn: none -->\n```\n<!-- learn: none -->\n```"
	want := "# T\nkeep\n```\n<!-- learn: none -->\n```"
	if got := stripCards(in); got != want {
		t.Errorf("stripCards = %q, want %q", got, want)
	}
}
