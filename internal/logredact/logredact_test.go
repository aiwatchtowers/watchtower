package logredact

import (
	"bytes"
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

func TestDetail_RedactCutsKeptTextToExcerpt(t *testing.T) {
	body := `{"errorMessages":["the plan for project zeta"]}`
	err := fmt.Errorf("GET /x: status 500: %s", Detail(body))
	require.Contains(t, err.Error(), "project zeta", "the error keeps the full text")

	line := []byte("warning: " + err.Error() + "\n")
	got := string(Redact(line))
	require.NotContains(t, got, "project zeta")
	require.Equal(t, "warning: GET /x: status 500: "+Excerpt(body)+"\n", got)

	var buf bytes.Buffer
	_, werr := Writer(&buf).Write(line)
	require.NoError(t, werr)
	require.Equal(t, got, buf.String())
}

func TestDetail_PlainShortTextIsNotKept(t *testing.T) {
	Detail("HTTP 429")
	require.Equal(t, "status HTTP 429", string(Redact([]byte("status HTTP 429"))))
}

func TestDetail_KeepsABoundedSet(t *testing.T) {
	first := `"first ` + strings.Repeat("x", 200) + `"`
	Detail(first)
	for i := range maxKept + 1 {
		Detail(fmt.Sprintf(`"filler %d %s"`, i, strings.Repeat("y", 200)))
	}
	require.Equal(t, first, string(Redact([]byte(first))), "the oldest kept text was evicted")
}
