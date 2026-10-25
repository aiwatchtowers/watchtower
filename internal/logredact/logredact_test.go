package logredact

import (
	"strings"
	"testing"
	"unicode/utf8"
)

func TestExcerpt_ScrubsQuotedText(t *testing.T) {
	cases := map[string]string{
		`error: channel "secret-plan" not found`: `error: channel "…" not found`,
		`bad 'x y' and ` + "`cmd`" + ` here`:     `bad "…" and "…" here`,
		`can't open "a"`:                         `can't open "…"`,
		`unterminated "rest of it`:               `unterminated "…"`,
		`json {"errorMessages":["boom"]}`:        `json {"…":["…"]}`,
	}
	for in, want := range cases {
		if got := Excerpt(in); got != want {
			t.Errorf("Excerpt(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestExcerpt_CollapsesWhitespace(t *testing.T) {
	if got := Excerpt("  a\n\tb   c  "); got != "a b c" {
		t.Errorf("got %q", got)
	}
}

func TestExcerpt_Caps(t *testing.T) {
	got := Excerpt(strings.Repeat("ж", 500))
	if n := utf8.RuneCountInString(got); n != ExcerptRunes+1 {
		t.Fatalf("rune count = %d, want %d", n, ExcerptRunes+1)
	}
	if !strings.HasSuffix(got, "…") {
		t.Errorf("missing ellipsis: %q", got)
	}
}

func TestExcerpt_KeepsShortPlain(t *testing.T) {
	if got := Excerpt("HTTP 429"); got != "HTTP 429" {
		t.Errorf("got %q", got)
	}
}

func TestBody_IsFingerprint(t *testing.T) {
	got := Body([]byte(`{"text":"private words"}`))
	if strings.Contains(got, "private") || !strings.Contains(got, "sha256:") {
		t.Errorf("Body = %q", got)
	}
}
