package prompts

import (
	"strings"
	"testing"
)

func TestDirectiveFallsBackToDefault(t *testing.T) {
	cases := []struct{ name, lang string }{
		{"empty", ""},
		{"whitespace", "   "},
		{"tab+newline", "\t\n"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := Directive(tc.lang)
			if !strings.Contains(got, DefaultLanguage) {
				t.Fatalf("Directive(%q) = %q; want it to contain default %q", tc.lang, got, DefaultLanguage)
			}
			if !HasDirective(got) {
				t.Fatalf("HasDirective(%q) = false; want true", got)
			}
		})
	}
}

func TestDirectiveHonoursExplicitLanguage(t *testing.T) {
	cases := []string{"English", "Russian", "Spanish", "Português"}
	for _, lang := range cases {
		t.Run(lang, func(t *testing.T) {
			got := Directive(lang)
			if !strings.Contains(got, lang) {
				t.Fatalf("Directive(%q) = %q; want it to contain %q", lang, got, lang)
			}
			if !HasDirective(got) {
				t.Fatalf("HasDirective(%q) = false; want true", got)
			}
		})
	}
}

func TestDirectiveTrimsWhitespace(t *testing.T) {
	got := Directive("  Russian  ")
	if strings.Contains(got, "  Russian") {
		t.Fatalf("Directive should trim whitespace; got %q", got)
	}
	if !strings.Contains(got, "Russian") {
		t.Fatalf("Directive should still contain Russian; got %q", got)
	}
}

func TestHasDirectiveOnUnrelatedString(t *testing.T) {
	if HasDirective("hello world") {
		t.Fatal("HasDirective should be false for unrelated text")
	}
	if HasDirective("Respond in Russian") {
		t.Fatal("HasDirective should be false for the older 'Respond in X' wording")
	}
}
