package wire

import (
	"strings"
	"testing"
)

// The Mac name is clipped by grapheme cluster, as the Kit's LinkPayload and
// the Swift HubIdentity.clipMacName (String.prefix) do: a name of combining
// marks or ZWJ emoji keeps MaxMacNameLength whole clusters.
func TestClipMacNameCountsGraphemes(t *testing.T) {
	accent := "é"
	family := "\U0001F468‍\U0001F469‍\U0001F467"
	for name, unit := range map[string]string{"ascii": "m", "combining": accent, "zwj": family} {
		at := strings.Repeat(unit, MaxMacNameLength)
		if got := ClipMacName(at); got != at {
			t.Errorf("%s: %d clusters were clipped to %q", name, MaxMacNameLength, got)
		}
		if got := ClipMacName(at + unit + "tail"); got != at {
			t.Errorf("%s: clipped to %q, want %d whole clusters", name, got, MaxMacNameLength)
		}
	}
	if got := ClipGraphemes("ab"+family+"cd", 3); got != "ab"+family {
		t.Errorf("a family emoji split: %q", got)
	}
	if ClipGraphemes("acme", 0) != "" || ClipGraphemes("", 5) != "" {
		t.Error("empty cases")
	}
}
