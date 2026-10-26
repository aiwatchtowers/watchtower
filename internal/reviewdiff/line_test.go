package reviewdiff

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestDeliveryLine_Fixtures(t *testing.T) {
	paths, _ := filepath.Glob("testdata/lines/*.json")
	if len(paths) < 4 {
		t.Fatal("fixtures missing")
	}
	for _, p := range paths {
		var fx struct {
			RoundID  int64  `json:"round_id"`
			Kind     string `json:"kind"`
			Comments int    `json:"comments"`
			Line     string `json:"line"`
		}
		b, _ := os.ReadFile(p)
		if err := json.Unmarshal(b, &fx); err != nil {
			t.Fatal(err)
		}
		got := DeliveryLine(fx.RoundID, fx.Comments)
		if fx.Kind == "approved" {
			got = ApprovedLine(fx.RoundID)
		}
		if got != fx.Line {
			t.Errorf("%s: %q, want %q", p, got, fx.Line)
		}
	}
}
