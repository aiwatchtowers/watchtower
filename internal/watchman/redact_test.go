package watchman

import (
	"strings"
	"testing"
)

// The secret shapes are tested in internal/secretredact; this checks the
// watchman's text paths still go through it.
func TestRedact_DelegatesToSecretredact(t *testing.T) {
	in := "use ghp_abcdefghijklmnopqrstuvwxyz0123 and https://bob:pa55@example.com/x" // leak-check:allow
	want := "use [secret] and https://[secret]@example.com/x"
	if got := Redact(in); got != want {
		t.Fatalf("Redact = %q, want %q", got, want)
	}
	if got := clean("  " + in + "  "); got != want {
		t.Fatalf("clean = %q, want %q", got, want)
	}
}

func TestClip_RuneSafe(t *testing.T) {
	if got := Clip("abc", 5); got != "abc" {
		t.Fatalf("got %q", got)
	}
	if got := Clip("héllo wörld", 6); got != "héllo…" {
		t.Fatalf("got %q", got)
	}
	if got := Clip("日本語テキスト", 4); got != "日本語…" {
		t.Fatalf("got %q", got)
	}
	if got := Clip("abc", 0); got != "" {
		t.Fatalf("got %q", got)
	}
}

func TestItemQuestion_RedactsAndClips(t *testing.T) {
	if got := ItemQuestion("  use ghp_abcdefghijklmnopqrstuvwxyz0123 here \n"); got != "use [secret] here" { // leak-check:allow
		t.Fatalf("got %q", got)
	}
	long := ItemQuestion(strings.Repeat("a", ItemQuestionLimit+10))
	if n := len([]rune(long)); n != ItemQuestionLimit {
		t.Fatalf("clipped to %d runes", n)
	}
}
