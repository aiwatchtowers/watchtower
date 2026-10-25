package confluence

import (
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// moduleImports returns the watchtower/... imports of the non-test Go files
// of the package at dir.
func moduleImports(t *testing.T, dir string) []string {
	t.Helper()
	files, err := filepath.Glob(filepath.Join(dir, "*.go"))
	if err != nil {
		t.Fatal(err)
	}
	var out []string
	fset := token.NewFileSet()
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		pf, err := parser.ParseFile(fset, f, nil, parser.ImportsOnly)
		if err != nil {
			t.Fatalf("parse %s: %v", f, err)
		}
		for _, imp := range pf.Imports {
			p, _ := strconv.Unquote(imp.Path.Value)
			if strings.HasPrefix(p, "watchtower/") {
				out = append(out, p)
			}
		}
	}
	return out
}

// TestConfluence_DoesNotImportMediaPipeline pins Ruling 13: the connector
// reads the link rules from the leaf internal/media/linkrule only. Importing
// internal/media (or any other media package) pulls the describe pipeline,
// the model clients and the knowledge index into every Confluence build.
// The walk is transitive over the module's own packages.
func TestConfluence_DoesNotImportMediaPipeline(t *testing.T) {
	root, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(root, "go.mod")); err != nil {
		t.Fatalf("module root not found at %s: %v", root, err)
	}
	forbidden := []string{
		"watchtower/internal/digest", "watchtower/internal/codex",
		"watchtower/internal/kb",
	}
	seen := map[string]string{"watchtower/internal/confluence": ""}
	queue := []string{"watchtower/internal/confluence"}
	for len(queue) > 0 {
		pkg := queue[0]
		queue = queue[1:]
		dir := filepath.Join(root, strings.TrimPrefix(pkg, "watchtower/"))
		for _, imp := range moduleImports(t, dir) {
			if _, ok := seen[imp]; ok {
				continue
			}
			seen[imp] = pkg
			queue = append(queue, imp)
		}
	}
	for imp, from := range seen {
		if (imp == "watchtower/internal/media" || strings.HasPrefix(imp, "watchtower/internal/media/")) &&
			imp != "watchtower/internal/media/linkrule" {
			t.Errorf("internal/confluence depends on %s (imported by %s); use internal/media/linkrule", imp, from)
		}
		for _, f := range forbidden {
			if imp == f {
				t.Errorf("internal/confluence depends on %s (imported by %s)", imp, from)
			}
		}
	}
	if _, ok := seen["watchtower/internal/media/linkrule"]; !ok {
		t.Error("expected internal/confluence to use internal/media/linkrule; update this guard if the link rules moved")
	}
}
