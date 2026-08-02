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
}
