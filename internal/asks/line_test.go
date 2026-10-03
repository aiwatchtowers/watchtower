package asks

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// lineFixture is one testdata/lines file: the delivery line for an answered
// ask, which the Swift OwnerAskPrompt reproduces.
type lineFixture struct {
	ID     int64           `json:"id"`
	Kind   string          `json:"kind"`
	Answer json.RawMessage `json:"answer"`
	Line   string          `json:"line"`
}

func TestDeliveryLineFixtures(t *testing.T) {
	files, err := filepath.Glob(filepath.Join("testdata", "lines", "*.json"))
	if err != nil || len(files) == 0 {
		t.Fatalf("no line fixtures: %v", err)
	}
	for _, path := range files {
		t.Run(filepath.Base(path), func(t *testing.T) {
			raw, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			var f lineFixture
			if err := json.Unmarshal(raw, &f); err != nil {
				t.Fatal(err)
			}
			a, err := ParseAnswer(f.Answer)
			if err != nil {
				t.Fatal(err)
			}
			if got := DeliveryLine(f.ID, f.Kind, a); got != f.Line {
				t.Fatalf("got  %q\nwant %q", got, f.Line)
			}
		})
	}
}

// The line is typed into a terminal: nothing in it may submit early or carry
// an escape. Every control scalar (C0, DEL, C1, format) and line separator
// becomes a space — the WorkbenchCommentPrompt rule.
func TestDeliveryLineIsOneLine(t *testing.T) {
	kind := "re\nvi\rew\x1b[31m\u0085x\u009by\x7fz\u2028w\u200bv"
	got := DeliveryLine(5, kind, Answer{Verdict: VerdictApproved})
	want := "Ask #5 answered (re vi ew [31m x y z w v: answered) — read it with get_ask 5 using the watchtower-workbench skill."
	if got != want {
		t.Fatalf("got  %q\nwant %q", got, want)
	}
}
