package diagnostics

import (
	"flag"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

var updateTextGolden = flag.Bool("update", false, "rewrite testdata/text.golden")

// TestDiagnosticsText_Pinned pins every fixed text of the report: each
// constant in text.go is listed as `name = value` in testdata/text.golden.
// A constant must be a plain string literal, so the golden file is the
// whole vocabulary of the report and nothing is built at run time.
func TestDiagnosticsText_Pinned(t *testing.T) {
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, "text.go", nil, 0)
	if err != nil {
		t.Fatalf("parse text.go: %v", err)
	}
	var b strings.Builder
	n := 0
	for _, decl := range f.Decls {
		gd, ok := decl.(*ast.GenDecl)
		if !ok || gd.Tok != token.CONST {
			continue
		}
		for _, spec := range gd.Specs {
			vs := spec.(*ast.ValueSpec)
			for i, name := range vs.Names {
				if i >= len(vs.Values) {
					t.Fatalf("const %s has no value of its own", name.Name)
				}
				lit, ok := vs.Values[i].(*ast.BasicLit)
				if !ok || lit.Kind != token.STRING {
					t.Fatalf("const %s must be a plain string literal", name.Name)
				}
				v, err := strconv.Unquote(lit.Value)
				if err != nil {
					t.Fatalf("const %s: %v", name.Name, err)
				}
				fmt.Fprintf(&b, "%s = %q\n", name.Name, v)
				n++
			}
		}
	}
	if n == 0 {
		t.Fatal("text.go declares no constants")
	}
	got := b.String()
	path := filepath.Join("testdata", "text.golden")
	if *updateTextGolden {
		if err := os.MkdirAll("testdata", 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(got), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read golden (run with -update to create it): %v", err)
	}
	if got != string(want) {
		t.Errorf("text.go differs from %s; a changed report text needs -update and a reviewed golden diff\n--- got ---\n%s", path, got)
	}
}

func TestDiagnosticsText_Helpers(t *testing.T) {
	cases := []struct{ name, got, want string }{
		{"JoinParts skips empty", JoinParts("a", "", "b"), "a · b"},
		{"Unknown", Unknown(ReasonDatabaseBusy), UnknownDatabaseBusy},
		{"WorkspaceNotChosen", WorkspaceNotChosen(2), "not chosen (2 found)"},
		{"Schema", Schema(181), "schema 181"},
		{"SchemaUnknownBecause", SchemaUnknownBecause(UnknownDatabaseBusy), "schema unknown (database busy)"},
		{"PipelineRunsUnknown", PipelineRunsUnknown(UnknownDatabaseBusy), "  pipeline runs unknown (database busy)"},
		{"Managed", Managed(ManagedYesWithErrors), "managed by organization: yes (with errors)"},
		{"LastCycle", LastCycle("5m", CycleDone), "last cycle 5m ago, done"},
		{"CrashFound", CrashFound(2, "2026-11-04 09:12Z", "watchtower/internal/sync.run"), "2 in the logs, last after 2026-11-04 09:12Z, in watchtower/internal/sync.run"},
		{"CrashFoundTimeUnknown", CrashFoundTimeUnknown(1, CrashLocationUnknown), "1 in the logs, last time unknown, in location unknown"},
		{"CrashScanStopped", CrashScanStopped(3), " (scan stopped after 3 MB)"},
		{"CrashNoneScanStopped", CrashNoneScanStopped(3), "none in the first 3 MB of the logs (scan stopped)"},
		{"Reserve", Reserve(ProviderCodex, ReserveAutomatic), "reserve Codex, automatic"},
		{"Version", Version("1.2.3", "abc", FlavorDefault, ""), "Watchtower 1.2.3 (commit abc, flavor: default)"},
		{"Version app", Version("1.2.3", "abc", FlavorCorp, "1.2.4"), "Watchtower 1.2.3 (commit abc, flavor: corp) · app 1.2.4"},
		{"MacOS", MacOS("15.5"), "macOS 15.5"},
	}
	for _, c := range cases {
		if c.got != c.want {
			t.Errorf("%s: got %q, want %q", c.name, c.got, c.want)
		}
	}
}
