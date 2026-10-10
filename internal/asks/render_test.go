package asks

import (
	"flag"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

var update = flag.Bool("update", false, "rewrite testdata/render golden files")

func TestRenderGolden(t *testing.T) {
	for name, f := range loadAnswerFixtures(t) {
		if !strings.HasPrefix(name, "valid_") {
			continue
		}
		t.Run(name, func(t *testing.T) {
			a, err := checkAnswer(f)
			if err != nil {
				t.Fatal(err)
			}
			got := Render(f.Kind, f.Payload, a)
			path := filepath.Join("testdata", "render", name+".txt")
			if *update {
				if err := os.WriteFile(path, []byte(got), 0o644); err != nil {
					t.Fatal(err)
				}
			}
			want, err := os.ReadFile(path)
			if err != nil {
				t.Fatalf("%v (run with -update to create)", err)
			}
			if got != string(want) {
				t.Fatalf("render mismatch\n got:\n%s\nwant:\n%s", got, want)
			}
		})
	}
}

// Board #502: each step reads as the Desktop's button the owner pressed —
// a note goes after its label on any state, and a step the answer left out
// reads as not checked.
func TestRenderChecklistReadsAsTheOwnersButtons(t *testing.T) {
	p := Payload{Checklist: []ChecklistItem{{ID: "1", Text: "Launch"}, {ID: "2", Text: "Quit"}, {ID: "3", Text: "Undo"}}}
	a := Answer{Checklist: []CheckAnswer{
		{ID: "1", State: StateOK, Note: "fast"},
		{ID: "2", State: StateSkipped, Note: "no time"},
	}}
	want := "Checklist: Works 1, Doesn't work 0, Didn't check 2\n" +
		"- Launch → Works: fast\n" +
		"- Quit → Didn't check: no time\n" +
		"- Undo → Didn't check"
	if got := Render(KindCheck, p, a); got != want {
		t.Fatalf("got:\n%s\nwant:\n%s", got, want)
	}
}
