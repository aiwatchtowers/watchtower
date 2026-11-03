package wire_test

import (
	"strings"
	"testing"

	"github.com/rivo/uniseg"

	"watchtower/internal/hub/wire"
)

// twin of HubHeartbeatTests.testMacNameOf70CharactersIsClippedTo60AtAGraphemeBoundary
func TestMacNameOf70CharactersIsClippedTo60AtAGraphemeBoundary(t *testing.T) {
	family := "👩‍👩‍👧‍👦" // one cluster, seven runes
	name := strings.Repeat("a", 59) + family + strings.Repeat("b", 10)
	if n := uniseg.GraphemeClusterCount(name); n != 70 {
		t.Fatalf("fixture has %d clusters", n)
	}

	clipped := wire.ClipMacName(name)

	if n := uniseg.GraphemeClusterCount(clipped); n != 60 {
		t.Fatalf("clipped to %d clusters, want 60", n)
	}
	if !strings.HasSuffix(clipped, family) {
		t.Fatalf("the ZWJ sequence was split: %q", clipped)
	}
	if got := wire.ClipMacName(strings.Repeat("x", 70)); len(got) != 60 {
		t.Fatalf("plain name clipped to %d", len(got))
	}
	if short := "Mac acme"; wire.ClipMacName(short) != short {
		t.Fatal("a short name changed")
	}
}

// twin of HubHeartbeatTests.testBuildFlavorMapsToTheWireFlavor
func TestBuildFlavorMapsToTheWireFlavor(t *testing.T) {
	for in, want := range map[string]string{"": wire.FlavorDefault, "dev": wire.FlavorDefault, "acme": wire.FlavorCorp} {
		if got := wire.FlavorOf(in); got != want {
			t.Errorf("FlavorOf(%q) = %q, want %q", in, got, want)
		}
	}
}
