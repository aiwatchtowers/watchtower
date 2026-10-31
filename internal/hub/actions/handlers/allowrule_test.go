package handlers

import (
	"encoding/json"
	"os"
	"testing"
)

// TestAllowBlockSharedCases: Go's AllowBlock and the Kit's
// PermissionAllowBlock.check read the same cases (PermissionAllowRuleTests'
// testSharedAllowBlockCases): one rule for the phone's card and the hub.
func TestAllowBlockSharedCases(t *testing.T) {
	raw, err := os.ReadFile("../../../../WatchtowerKit/Tests/Fixtures/permissions/allow_block_cases.json")
	if err != nil {
		t.Fatal(err)
	}
	var f struct {
		Cases []struct {
			Name, Tool, Summary string
			Clipped             bool
			Block               *string
		}
	}
	if err := json.Unmarshal(raw, &f); err != nil {
		t.Fatal(err)
	}
	if len(f.Cases) == 0 {
		t.Fatal("no cases")
	}
	for _, c := range f.Cases {
		block, blocked := AllowBlock(c.Tool, c.Summary, c.Clipped)
		want := ""
		if c.Block != nil {
			want = *c.Block
		}
		if block != want || blocked != (c.Block != nil) {
			t.Errorf("%s: AllowBlock(%q, %q, %v) = %q, %v; want %q", c.Name, c.Tool, c.Summary, c.Clipped, block, blocked, want)
		}
	}
}

// Every block has the Kit's note.
func TestAllowBlockNotes(t *testing.T) {
	for _, b := range []string{AllowBlockClipped, AllowBlockSettingsPath} {
		if allowBlockNotes[b] == "" {
			t.Fatalf("%s has no note", b)
		}
	}
}
