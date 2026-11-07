package cmd

import (
	"go/ast"
	"go/parser"
	"go/token"
	"path/filepath"
	"strings"
	"testing"
)

// TestSessionAgent_OneStateEntryPoint (spec 2026-11-05 §3.5, PROJ-11): a
// hook's event (push) and an adapter's pull event reach the row's state
// through one entry point. recordAgentState is called from
// recordAgentEvent only, and that takes the sessionagent.Event it records.
func TestSessionAgent_OneStateEntryPoint(t *testing.T) {
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	fset := token.NewFileSet()
	var callers []string
	var entryTakesEvent bool
	for _, name := range files {
		if strings.HasSuffix(name, "_test.go") {
			continue
		}
		f, err := parser.ParseFile(fset, name, nil, parser.SkipObjectResolution)
		if err != nil {
			t.Fatal(err)
		}
		for _, decl := range f.Decls {
			fn, ok := decl.(*ast.FuncDecl)
			if !ok || fn.Body == nil {
				continue
			}
			if fn.Name.Name == "recordAgentEvent" {
				for _, p := range fn.Type.Params.List {
					if id, ok := p.Type.(*ast.Ident); ok && id.Name == "hookEvent" {
						entryTakesEvent = true
					}
					if sel, ok := p.Type.(*ast.SelectorExpr); ok && sel.Sel.Name == "Event" {
						if pkg, ok := sel.X.(*ast.Ident); ok && pkg.Name == "sessionagent" {
							entryTakesEvent = true
						}
					}
				}
			}
			ast.Inspect(fn.Body, func(n ast.Node) bool {
				call, ok := n.(*ast.CallExpr)
				if !ok {
					return true
				}
				if id, ok := call.Fun.(*ast.Ident); ok && id.Name == "recordAgentState" {
					callers = append(callers, name+":"+fn.Name.Name)
				}
				return true
			})
		}
	}
	if !entryTakesEvent {
		t.Error("recordAgentEvent must take the sessionagent.Event it records")
	}
	for _, c := range callers {
		if !strings.HasSuffix(c, ":recordAgentEvent") {
			t.Errorf("recordAgentState called from %s: go through recordAgentEvent", c)
		}
	}
	if len(callers) != 1 {
		t.Errorf("recordAgentState has %d call sites (%v), want exactly one", len(callers), callers)
	}
}
