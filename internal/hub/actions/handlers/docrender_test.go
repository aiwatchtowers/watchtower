package handlers

import (
	"encoding/json"
	"os"
	"testing"
	"unicode/utf16"
)

// anchorFixtures is WatchtowerKit/Tests/Fixtures/asks/anchor-fixtures.json,
// the review comment anchors Core's CommentAnchor and the Kit's port make.
type anchorFixtures struct {
	ContextLength int `json:"context_length"`
	Cases         []struct {
		Name     string `json:"name"`
		Markdown string `json:"markdown"`
		Text     string `json:"text"`
		Headings []struct {
			Offset int    `json:"offset"`
			Title  string `json:"title"`
		} `json:"headings"`
		Anchor struct {
			Quote   string `json:"quote"`
			Prefix  string `json:"prefix"`
			Suffix  string `json:"suffix"`
			Heading string `json:"heading"`
		} `json:"anchor"`
	} `json:"cases"`
}

func loadAnchorFixtures(t *testing.T) anchorFixtures {
	t.Helper()
	raw, err := os.ReadFile("../../../../WatchtowerKit/Tests/Fixtures/asks/anchor-fixtures.json")
	if err != nil {
		t.Fatal(err)
	}
	var f anchorFixtures
	if err := json.Unmarshal(raw, &f); err != nil {
		t.Fatal(err)
	}
	if len(f.Cases) == 0 {
		t.Fatal("no cases")
	}
	return f
}

// utf16Len is a byte prefix's length in UTF-16 units, the fixture's offsets.
func utf16Len(s string) int { return len(utf16.Encode([]rune(s))) }

// Every case of the shared fixture: Go renders the snapshot to Core's text
// and headings, and re-locating the quote gives Core's context.
func TestAnchorFixtures(t *testing.T) {
	f := loadAnchorFixtures(t)
	if f.ContextLength != anchorContextLength {
		t.Fatalf("context_length = %d, Go uses %d", f.ContextLength, anchorContextLength)
	}
	for _, c := range f.Cases {
		t.Run(c.Name, func(t *testing.T) {
			doc := renderDocument(c.Markdown)
			if doc.text != c.Text {
				t.Fatalf("text = %q\nwant %q", doc.text, c.Text)
			}
			if renderPlain(c.Markdown) != c.Text {
				t.Fatal("renderPlain differs from renderDocument")
			}
			if len(doc.headings) != len(c.Headings) {
				t.Fatalf("headings = %+v, want %+v", doc.headings, c.Headings)
			}
			for i, h := range doc.headings {
				if utf16Len(doc.text[:h.offset]) != c.Headings[i].Offset || h.title != c.Headings[i].Title {
					t.Fatalf("heading %d = %+v, want %+v", i, h, c.Headings[i])
				}
			}
			prefix, suffix, ok := relocate(doc.text, c.Anchor.Quote)
			if !ok || prefix != c.Anchor.Prefix || suffix != c.Anchor.Suffix {
				t.Fatalf("relocate = %q, %q, %v\nwant %q, %q", prefix, suffix, ok, c.Anchor.Prefix, c.Anchor.Suffix)
			}
			got := placeComment("", c.Anchor.Quote, "b", &doc)
			if got.Quote != c.Anchor.Quote || got.Heading != c.Anchor.Heading {
				t.Fatalf("comment = %+v, want heading %q", got, c.Anchor.Heading)
			}
		})
	}
}

func TestQuoteNotFoundKeepsEmptyContext(t *testing.T) {
	doc := renderDocument("# Plan\n\nShip it behind a flag.\n\nShip it behind a flag.\n")
	for _, quote := range []string{"", "   ", "not in the document"} {
		if p, s, ok := relocate(doc.text, quote); ok || p != "" || s != "" {
			t.Fatalf("%q: relocate = %q, %q, %v", quote, p, s, ok)
		}
	}
	// Found only after whitespace collapsing, but twice: no context to
	// pick one with, so not found (CommentAnchor.locate).
	if _, _, ok := relocate("a  b x a\nb", "a b"); ok {
		t.Fatal("two collapsed hits with no context are not found")
	}
	got := placeComment("## Plan", "not in the document", "why?", &doc)
	if got.Heading != "## Plan" || got.Quote != "not in the document" || got.Prefix != "" || got.Suffix != "" {
		t.Fatalf("comment = %+v: the reviewer's heading and quote, no context", got)
	}
}

func TestRelocateFindsTheRenderedOrCollapsedQuote(t *testing.T) {
	doc := renderDocument("# Plan\n\nRun `make  test` before **every** push.\n")
	// A raw-markdown quote is looked up as rendered.
	if p, s, ok := relocate(doc.text, "  **every** push "); !ok || p != "Plan\n\nRun make  test before " || s != ".\n\n" {
		t.Fatalf("rendered: %q, %q, %v", p, s, ok)
	}
	// A reflowed quote: whitespace runs read as one space.
	if p, s, ok := relocate(doc.text, "make test"); !ok || p != "Plan\n\nRun " || s != " before every push.\n\n" {
		t.Fatalf("collapsed: %q, %q, %v", p, s, ok)
	}
	// The first of two exact hits, as NSString's range(of:).
	if p, _, ok := relocate("x y x", "x"); !ok || p != "" {
		t.Fatalf("first hit: %q, %v", p, ok)
	}
}

// A heading-less place keeps the reviewer's heading, without its hashes.
func TestPlacedCommentFallsBackToTheReviewersHeading(t *testing.T) {
	doc := renderDocument("Intro line\n\n## Later\n\nmore\n")
	got := placeComment("## Somewhere", "Intro line", "b", &doc)
	if got.Heading != "Somewhere" || got.Suffix != "\n\nLater\n\nmore\n\n" {
		t.Fatalf("comment = %+v", got)
	}
	if got := placeComment("x", "more", "b", &doc); got.Heading != "Later" {
		t.Fatalf("heading = %q, want the rendered one", got.Heading)
	}
}

// The context window counts characters (grapheme clusters), as Swift does.
func TestContextCountsGraphemes(t *testing.T) {
	family := "👩‍👩‍👧"
	text := "x" + family + "yz"
	start := len("x" + family)
	p, s := anchorContext(text, start, start+1)
	if p != "x"+family || s != "z" {
		t.Fatalf("%q %q", p, s)
	}
	long := ""
	for range 70 {
		long += family
	}
	p, _ = anchorContext(long+"Q", len(long), len(long)+1)
	if p != long[len(family)*6:] {
		t.Fatalf("prefix holds %d bytes, want 64 families", len(p))
	}
}

// Core's DocumentRendering text rules, as the Kit's CommentAnchorBuilderTests
// pin them for its port.
func TestRenderPlainFollowsDocumentRendering(t *testing.T) {
	for _, c := range []struct{ name, md, want string }{
		{"inline markup", "Some **bold**, *em*, _it_, ~~gone~~, `code *x*` and [a link](https://example.com) plus ![img](a.png).\n",
			"Some bold, em, it, gone, code *x* and a link plus img.\n\n"},
		{"intraword underscores", "snake_case_name and 2 * 3\n", "snake_case_name and 2 * 3\n\n"},
		{"escapes and entities", "\\*not em\\* &amp; &lt;tag&gt; &#65;\n", "*not em* & <tag> A\n\n"},
		{"breaks", "one\ntwo  \nthree\\\nfour\n", "one two\nthree\nfour\n\n"},
		{"lists", "- one\n- two\n  - nested\n\n3. three\n4. four\n\n- [x] done\n- [ ] open\n",
			"• one\n• two\n    • nested\n\n3. three\n4. four\n\n☑ done\n☐ open\n\n"},
		{"code quote rule", "```swift\nlet a = 1\n```\n\n> quoted\n> text\n\n---\n\nafter\n", "let a = 1\n\nquoted text\n\n \n\nafter\n\n"},
		{"headings", "# Café 👍🏽\n\ntext\n\n### Deep ##\n", "Café 👍🏽\n\ntext\n\nDeep\n\n"},
		{"setext", "Title\n=====\n\nSub\n---\n", "Title\n\nSub\n\n"},
		{"table", "| a | b |\n|---|:-:|\n| 1 | **2** |\n| 3 |\n", "a\nb\n1\n2\n3\n\n\n"},
		{"inline tag", "Set the token in\n<owner> config and **restart**.\n", "Set the token in <owner> config and restart.\n\n"},
		{"autolink", "<https://example.com> is the site\n", "https://example.com is the site\n\n"},
		{"html block", "Text\n<div>\nraw\n</div>\n", "Text\n\n<div>\nraw\n</div>\n\n"},
		{"html comment", "<!-- note -->\nAfter\n", "<!-- note -->\n\nAfter\n\n"},
		{"lone tag", "<owner>\n", "<owner>\n\n"},
		{"tag in paragraph", "Text\n<owner>\n", "Text <owner>\n\n"},
		{"tag with text", "<owner> config\n", "<owner> config\n\n"},
		{"empty", "", ""},
	} {
		if got := renderPlain(c.md); got != c.want {
			t.Errorf("%s: %q\nwant %q", c.name, got, c.want)
		}
	}
	doc := renderDocument("# Café 👍🏽\n\ntext\n\n### Deep ##\n")
	if len(doc.headings) != 2 || utf16Len(doc.text[:doc.headings[1].offset]) != 17 ||
		doc.headings[0].level != 1 || doc.headings[1].level != 3 || doc.headings[1].title != "Deep" {
		t.Fatalf("headings = %+v", doc.headings)
	}
}
