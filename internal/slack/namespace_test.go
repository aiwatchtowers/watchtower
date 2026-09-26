package slack

import "testing"

func TestNamespace(t *testing.T) {
	if got := Namespace(2, "C0123"); got != "2:C0123" {
		t.Fatalf("got %q", got)
	}
	if got := Namespace(2, ""); got != "" {
		t.Fatalf("empty raw id must stay empty, got %q", got)
	}
}

func TestSplitAccountID(t *testing.T) {
	acct, raw, ok := SplitAccountID("2:C0123")
	if !ok || acct != 2 || raw != "C0123" {
		t.Fatalf("got acct=%d raw=%q ok=%v", acct, raw, ok)
	}
	if _, _, ok := SplitAccountID("C0123"); ok {
		t.Fatal("no colon prefix should not parse as namespaced")
	}
	if _, _, ok := SplitAccountID(""); ok {
		t.Fatal("empty string should not parse")
	}
	// A colon-containing but non-numeric prefix (e.g. a Jira issue key or a
	// gmail:/imap: source discriminator) must not parse as a namespaced
	// Slack id — this is the exact shape migration 00048's exclusions must
	// tell apart from a real "<accountID>:<rawID>" string.
	if _, _, ok := SplitAccountID("gmail:1:th1"); ok {
		t.Fatal("non-numeric colon prefix should not parse as namespaced")
	}
}

func TestRawIDsJSON(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string
	}{
		{"namespaced", `["1:U456"]`, `["U456"]`},
		{"bare", `["U456"]`, `["U456"]`},
		{"mixed", `["1:U456","U789"]`, `["U456","U789"]`},
		{"empty array", `[]`, `[]`},
		{"empty string", ``, ``},
		{"malformed", `not json`, `not json`},
		{"non-array JSON", `{"a":1}`, `{"a":1}`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := RawIDsJSON(tc.in); got != tc.want {
				t.Fatalf("RawIDsJSON(%q) = %q, want %q", tc.in, got, tc.want)
			}
		})
	}
}

func TestMentionPatterns(t *testing.T) {
	tests := []struct {
		name       string
		userID     string
		wantStrict string
		wantPipe   string
	}{
		{"namespaced id reduces to raw", "1:U123", "%<@U123>%", "%<@U123|%"},
		{"bare id passes through", "U123", "%<@U123>%", "%<@U123|%"},
		{"multi-digit account prefix", "12:U123", "%<@U123>%", "%<@U123|%"},
		{"empty id", "", "%<@>%", "%<@|%"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			strict, pipe := MentionPatterns(tc.userID)
			if strict != tc.wantStrict || pipe != tc.wantPipe {
				t.Fatalf("MentionPatterns(%q) = (%q, %q), want (%q, %q)", tc.userID, strict, pipe, tc.wantStrict, tc.wantPipe)
			}
		})
	}
}

func TestMentionTag(t *testing.T) {
	if got := MentionTag("1:U123"); got != "<@U123>" {
		t.Fatalf("got %q", got)
	}
	if got := MentionTag("U123"); got != "<@U123>" {
		t.Fatalf("got %q", got)
	}
}
