package handlers

import (
	"context"
	"testing"

	"watchtower/internal/asks"
)

// A phone answer over a finished author loop places the loop's comment as
// Core's SpecReviewAnswer does: the raw-markdown quote found in the rendered
// snapshot, with its context. The case and its anchor are the shared
// fixture's; Core's SpecReviewTests pins the Swift side on the same case.
func TestSpecReviewAnswerCarriesContextLikeDesktop(t *testing.T) {
	var markdown string
	var want asks.Comment
	for _, c := range loadAnchorFixtures(t).Cases {
		if c.Name == "spec_review_comment_on_a_rendered_list_item" {
			markdown = c.Markdown
			want = asks.Comment{Quote: c.Anchor.Quote, Prefix: c.Anchor.Prefix, Suffix: c.Anchor.Suffix, Heading: c.Anchor.Heading,
				Body: "Reviewer is right: No rollback — needed now"}
		}
	}
	if markdown == "" {
		t.Fatal("the fixture has no spec_review_comment_on_a_rendered_list_item case")
	}
	e := newEnv(t)
	s := e.seedAsk(asks.KindReview, "{}")
	e.exec(`UPDATE owner_asks SET doc_snapshot = ? WHERE id = ?`, markdown, s.ask)
	e.exec(`INSERT INTO spec_reviews (ask_id, status, queued_at, loop, ledger) VALUES (?, 'done', '2026-10-25T10:00:00Z', 'owner', ?)`, s.ask,
		`[{"key":"bs:1","text":"No rollback","where":{"heading":"## Steps","quote":"Copy the **users** table"},
		  "reply":{"reply":"disagree","note":"later"},"verdict":"disputed","verdict_note":"needed now","settled":2}]`)
	e.exec(`INSERT INTO spec_review_marks (ask_id, item_key, state, body, about, updated_at)
		VALUES (?, 'bs:1', 'comment', '', 'No rollback', '2026-10-25T10:00:00Z')`, s.ask)

	got := e.h.askAnswer(context.Background(), e.answerAction(s, review("changes")))

	st, raw := e.stored(s.ask)
	if st == "open" {
		t.Fatalf("not stored: %+v", got)
	}
	a, err := asks.ParseAnswer([]byte(raw))
	if err != nil {
		t.Fatal(err)
	}
	if len(a.Comments) != 1 || a.Comments[0] != want {
		t.Fatalf("comments = %+v\nwant %+v", a.Comments, want)
	}
}

// The first-heading fallback's quote (the first body line, markers rendered
// away) is found again, under the rendered heading nearest before it.
func TestSpecReviewFallbackAnchorIsRelocated(t *testing.T) {
	snapshot := "# Spec\n\n## Behaviour\n\n- Muting lasts **twenty-four** hours\n"
	anchor := firstHeadingAnchor(snapshot)
	if anchor != [2]string{"Spec", "Muting lasts twenty-four hours"} {
		t.Fatalf("anchor = %q", anchor)
	}
	doc := renderDocument(snapshot)
	c := placeComment(anchor[0], anchor[1], "b", &doc)
	want := asks.Comment{Heading: "Behaviour", Quote: "Muting lasts twenty-four hours", Prefix: "Spec\n\nBehaviour\n\n• ", Suffix: "\n\n", Body: "b"}
	if c != want {
		t.Fatalf("comment = %+v\nwant %+v", c, want)
	}
}
