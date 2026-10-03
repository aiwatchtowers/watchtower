//go:build !cgo

package codeindex

import "testing"

// Without cgo there are no grammars: a Go file reports lang "" with no
// symbols, while Markdown (a line scan) still yields its headings.
func TestNoCgo_ReportsNoLanguage(t *testing.T) {
	root := t.TempDir()
	write(t, root, "main.go", []byte("package main\n\nfunc main() {}\n"))
	write(t, root, "a.md", []byte("# A\n"))
	got := collect(t, root, nil, nil)
	if r := got["main.go"]; r.Lang != "" || len(r.Symbols) != 0 {
		t.Errorf("main.go = %+v, want lang \"\" and no symbols", r)
	}
	if r := got["a.md"]; r.Lang != "markdown" || len(r.Symbols) != 1 {
		t.Errorf("a.md = %+v", r)
	}
}
