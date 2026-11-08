package identity

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const stagingTag = "relaystaging"

// TestNoReleasePathSetsRelayStaging: the relaystaging tag (a 10-minute epoch,
// 30-minute retention) appears only on the Makefile's hub-staging target;
// no script and no workflow, release.yml above all (it builds with its own
// -tags), sets it (ask #1077).
func TestNoReleasePathSetsRelayStaging(t *testing.T) {
	root := filepath.Join("..", "..", "..")
	makefile, err := os.ReadFile(filepath.Join(root, "Makefile"))
	if err != nil {
		t.Fatal(err)
	}
	target, found := "", false
	for i, line := range strings.Split(string(makefile), "\n") {
		if line != "" && !strings.HasPrefix(line, "\t") && !strings.HasPrefix(line, "#") && !strings.HasPrefix(line, " ") {
			if name, _, ok := strings.Cut(line, ":"); ok && !strings.ContainsAny(name, "=?") {
				target = strings.TrimSpace(name)
			} else {
				target = ""
			}
		}
		if !strings.Contains(line, stagingTag) || strings.HasPrefix(strings.TrimSpace(line), "#") {
			continue
		}
		if target != "hub-staging" || !strings.HasPrefix(line, "\t") {
			t.Fatalf("Makefile:%d sets %s outside the hub-staging recipe: %q", i+1, stagingTag, line)
		}
		found = true
	}
	if !found {
		t.Fatal("the Makefile has no hub-staging target building with -tags relaystaging")
	}
	var others []string
	for _, pattern := range []string{"scripts/*.sh", ".github/workflows/*.yml", ".github/workflows/*.yaml"} {
		m, err := filepath.Glob(filepath.Join(root, pattern))
		if err != nil {
			t.Fatal(err)
		}
		others = append(others, m...)
	}
	if !containsSuffix(others, filepath.Join(".github", "workflows", "release.yml")) {
		t.Fatal("release.yml was not read")
	}
	for _, f := range others {
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(string(b), stagingTag) {
			t.Fatalf("%s mentions %s: no release path may set it", f, stagingTag)
		}
	}
}

func containsSuffix(paths []string, suffix string) bool {
	for _, p := range paths {
		if strings.HasSuffix(p, suffix) {
			return true
		}
	}
	return false
}
