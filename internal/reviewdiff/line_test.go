package reviewdiff

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestDeliveryLine_Fixtures(t *testing.T) {
	paths, _ := filepath.Glob("testdata/lines/*.json")
	if len(paths) < 3 {
		t.Fatal("fixtures missing")
	}
	for _, p := range paths {
		var fx struct {
			RoundID  int64  `json:"round_id"`
			Comments int    `json:"comments"`
			Line     string `json:"line"`
		}
		b, _ := os.ReadFile(p)
		if err := json.Unmarshal(b, &fx); err != nil {
			t.Fatal(err)
		}
		if got := DeliveryLine(fx.RoundID, fx.Comments); got != fx.Line {
			t.Errorf("%s: %q, want %q", p, got, fx.Line)
		}
	}
}
