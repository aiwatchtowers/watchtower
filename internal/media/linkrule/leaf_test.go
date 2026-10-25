package linkrule

import (
	"go/parser"
	"go/token"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// TestLinkrule_IsLeaf pins Ruling 13: the link rules import the standard
// library and golang.org/x/net/idna only, so connectors can use them without
// pulling the media pipeline.
func TestLinkrule_IsLeaf(t *testing.T) {
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	fset := token.NewFileSet()
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		pf, err := parser.ParseFile(fset, f, nil, parser.ImportsOnly)
		if err != nil {
			t.Fatal(err)
		}
		for _, imp := range pf.Imports {
			p, _ := strconv.Unquote(imp.Path.Value)
			first, _, _ := strings.Cut(p, "/")
			if p != "golang.org/x/net/idna" && strings.Contains(first, ".") || strings.HasPrefix(p, "watchtower/") {
				t.Errorf("%s imports %s; linkrule must stay a leaf", f, p)
			}
		}
	}
}
