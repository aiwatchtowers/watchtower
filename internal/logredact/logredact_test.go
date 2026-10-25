package logredact

import (
	"errors"
	"fmt"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/stretchr/testify/require"
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

func TestErrorf_ErrorShowsFingerprintFullShowsText(t *testing.T) {
	body := `{"errorMessages":["the plan for project zeta"]}`
	err := Errorf("GET /x: status %d: %s", 500, Text(body))
	require.NotContains(t, err.Error(), "project zeta")
	require.Contains(t, err.Error(), "GET /x: status 500: [")
	require.Equal(t, "GET /x: status 500: "+body, Full(err))
}

func TestErrorf_ShortUnquotedBodyIsNotShownInFull(t *testing.T) {
	err := Errorf("status 404: %s", Text("Issue PROJ-1 payroll fix not found"))
	require.NotContains(t, err.Error(), "payroll")
	require.Contains(t, Full(err), "Issue PROJ-1 payroll fix not found")
}

func TestErrorf_EveryFormatStaysSafe(t *testing.T) {
	err := Errorf("failed: %s", Text(`secret words`))
	for _, s := range []string{
		fmt.Sprintf("%v", err), fmt.Sprintf("%q", err), fmt.Sprintf("%s", err), fmt.Sprintf("%+v", err),
		fmt.Errorf("outer: %w", err).Error(),
	} {
		require.NotContains(t, s, "secret words", s)
	}
}

func TestErrorf_WrapsAndFullSeesThroughWrappers(t *testing.T) {
	sentinel := errors.New("sentinel")
	inner := Errorf("codex error: %s", Text("inner secret"))
	mid := Errorf("%w (stderr: %s): %w", inner, Text("stderr secret"), sentinel)
	outer := fmt.Errorf("digest: %w", mid)

	require.ErrorIs(t, outer, sentinel)
	require.ErrorIs(t, outer, inner)
	var d *DetailError
	require.ErrorAs(t, outer, &d)
	require.NotContains(t, outer.Error(), "secret")
	require.Equal(t, "digest: codex error: inner secret (stderr: stderr secret): sentinel", Full(outer))
	require.Equal(t, "plain", Full(errors.New("plain")))
	require.Empty(t, Full(nil))
}
