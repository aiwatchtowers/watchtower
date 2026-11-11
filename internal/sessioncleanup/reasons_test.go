package sessioncleanup

import (
	"encoding/json"
	"flag"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"testing"
)

var updateReasonCodes = flag.Bool("update", false, "rewrite testdata/reason_codes.json")

const reasonCodesFixture = "testdata/reason_codes.json"

// TestReasonCodesFixture keeps testdata/reason_codes.json — read by the
// Desktop's SessionAutoCleanupOutcomeTests, which fail when a code has no
// group — equal to allReasonCodes, and allReasonCodes equal to every
// Reason* constant of the package, so a new reason code cannot skip the
// Desktop's table.
func TestReasonCodesFixture(t *testing.T) {
	codes := allReasonCodes()
	if declared := declaredReasonCodes(t); !slices.Equal(sortedCopy(codes), declared) {
		t.Fatalf("allReasonCodes() = %v, the package declares %v: add the new code to reasons.go", sortedCopy(codes), declared)
	}
	want, err := json.MarshalIndent(map[string][]string{"reason_codes": codes}, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	want = append(want, '\n')
	if *updateReasonCodes {
		if err := os.MkdirAll(filepath.Dir(reasonCodesFixture), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(reasonCodesFixture, want, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	got, err := os.ReadFile(reasonCodesFixture)
	if err != nil {
		t.Fatalf("%v (run go test ./internal/sessioncleanup -run TestReasonCodesFixture -update)", err)
	}
	if string(got) != string(want) {
		t.Fatalf("%s is stale: run go test ./internal/sessioncleanup -run TestReasonCodesFixture -update", reasonCodesFixture)
	}
}

// declaredReasonCodes is the sorted values of the package's string
// constants named Reason*, read from its non-test sources.
func declaredReasonCodes(t *testing.T) []string {
	t.Helper()
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	fset := token.NewFileSet()
	var codes []string
	for _, name := range files {
		if strings.HasSuffix(name, "_test.go") {
			continue
		}
		f, err := parser.ParseFile(fset, name, nil, 0)
		if err != nil {
			t.Fatal(err)
		}
		for _, decl := range f.Decls {
			gen, ok := decl.(*ast.GenDecl)
			if !ok || gen.Tok != token.CONST {
				continue
			}
			for _, spec := range gen.Specs {
				vs, ok := spec.(*ast.ValueSpec)
				if !ok {
					continue
				}
				for i, id := range vs.Names {
					if !strings.HasPrefix(id.Name, "Reason") || i >= len(vs.Values) {
						continue
					}
					lit, ok := vs.Values[i].(*ast.BasicLit)
					if !ok || lit.Kind != token.STRING {
						continue
					}
					code, err := strconv.Unquote(lit.Value)
					if err != nil {
						t.Fatal(err)
					}
					codes = append(codes, code)
				}
			}
		}
	}
	slices.Sort(codes)
	return codes
}

func sortedCopy(s []string) []string {
	c := slices.Clone(s)
	slices.Sort(c)
	return c
}
