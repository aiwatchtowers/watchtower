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
