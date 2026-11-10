package cmd

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

// TestReviewGoldens_SwiftCopiesMatch keeps the WatchtowerCore fixtures equal
// to the Go goldens they copy: the Desktop decodes exactly what the CLI prints.
func TestReviewGoldens_SwiftCopiesMatch(t *testing.T) {
	pairs := map[string]string{
		"testdata/review-map.golden.json":       "review-map.json",
		"testdata/review-overview-stream.jsonl": "review-overview-stream.jsonl",
	}
	for golden, copyName := range pairs {
		want, err := os.ReadFile(golden)
		if err != nil {
			t.Fatal(err)
		}
		got, err := os.ReadFile(filepath.Join("..", "WatchtowerDesktop", "Tests", "Core", "Fixtures", copyName))
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(want, got) {
			t.Errorf("WatchtowerDesktop/Tests/Core/Fixtures/%s differs from cmd/%s: copy the golden after -update", copyName, golden)
		}
	}
}
