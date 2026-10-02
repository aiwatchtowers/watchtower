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

func TestDefaultLanguageIsEnglish(t *testing.T) {
	if DefaultLanguage != "English" {
		t.Fatalf("DefaultLanguage = %q; want English", DefaultLanguage)
	}
}

func TestChatDirectiveFollowsTheOwner(t *testing.T) {
	got := ChatDirective("Ukrainian")
	if !HasChatDirective(got) {
		t.Fatalf("HasChatDirective(%q) = false; want true", got)
	}
	if !strings.Contains(got, "Ukrainian") {
		t.Fatalf("ChatDirective should name the fallback language; got %q", got)
	}
	// The chat directive is not the strict one: background-pipeline guards
	// must not accept it, and the strict one is not a chat directive.
	if HasDirective(got) {
		t.Fatalf("HasDirective(%q) = true; the chat directive must not pass the strict guard", got)
	}
	if HasChatDirective(Directive("Ukrainian")) {
		t.Fatal("HasChatDirective should be false for the strict directive")
	}
}

func TestChatDirectiveFallsBackToDefault(t *testing.T) {
	for _, lang := range []string{"", "   "} {
		got := ChatDirective(lang)
		if !strings.Contains(got, DefaultLanguage) || !HasChatDirective(got) {
			t.Fatalf("ChatDirective(%q) = %q; want the %q fallback", lang, got, DefaultLanguage)
		}
	}
}
