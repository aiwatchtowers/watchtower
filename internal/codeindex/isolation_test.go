//go:build cgo

package codeindex

import (
	"strings"
	"sync"
	"testing"

	"watchtower/internal/codeindex/ts"
)

// A language whose query does not compile against its grammar degrades to
// lang "" for its files, with one note per run; the other languages are
// indexed as usual (ruling R17).
func TestRun_BrokenQueryDegradesOnlyItsLanguage(t *testing.T) {
	compiled.Store("python", sync.OnceValues(func() (*ts.Grammar, error) {
		return ts.NewGrammar(grammars["python"](), "(no_such_node) @name")
	}))
	t.Cleanup(func() { compiled.Delete("python") })

	root := t.TempDir()
	write(t, root, "a.py", []byte("def a():\n    pass\n"))
	write(t, root, "b.py", []byte("def b():\n    pass\n"))
	write(t, root, "c.go", []byte("package c\n\nfunc C() {}\n"))
	warned := captureWarnings(t)
	got := collect(t, root, nil, nil)
	for _, f := range []string{"a.py", "b.py"} {
		if r := got[f]; r.Lang != "" || len(r.Symbols) != 0 {
			t.Errorf("%s = %+v, want lang \"\" with no symbols", f, r)
		}
	}
	if r := got["c.go"]; r.Lang != "go" || len(r.Symbols) != 1 {
		t.Errorf("c.go = %+v, want its function", r)
	}
	if w := warned.String(); strings.Count(w, "\n") != 1 || !strings.Contains(w, "python files") {
		t.Errorf("warnings = %q, want one line naming the python files", w)
	}
}
