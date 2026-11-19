package tools

import (
	"strings"
	"testing"

	"github.com/rivo/uniseg"
)

// TestArgsDisplay: indented JSON, the stored text when it is not JSON, and a
// cut at MaxArgsDisplay characters (grapheme clusters, never inside one) that
// ends with "…" and reports the text as not whole.
func TestArgsDisplay(t *testing.T) {
	if got, whole := ArgsDisplay(`{"a":1}`); got != "{\n  \"a\": 1\n}" || !whole {
		t.Fatalf("indented %q %v", got, whole)
	}
	if got, whole := ArgsDisplay("not json"); got != "not json" || !whole {
		t.Fatalf("raw %q %v", got, whole)
	}
	exact := strings.Repeat("a", MaxArgsDisplay)
	if got, whole := ArgsDisplay(exact); got != exact || !whole {
		t.Fatal("a text of exactly the cap was cut")
	}
	flag := "🇺🇦"
	got, whole := ArgsDisplay(strings.Repeat(flag, MaxArgsDisplay+5))
	if whole || uniseg.GraphemeClusterCount(got) != MaxArgsDisplay || !strings.HasSuffix(got, "…") ||
		!strings.HasPrefix(strings.TrimSuffix(got, "…"), flag) || strings.Count(got, flag) != MaxArgsDisplay-1 {
		t.Fatalf("cut: %d clusters, whole %v", uniseg.GraphemeClusterCount(got), whole)
	}
}
