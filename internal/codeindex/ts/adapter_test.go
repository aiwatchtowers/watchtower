//go:build cgo

package ts

import (
	"testing"

	golang "github.com/alexaandru/go-sitter-forest/go"
)

func TestNewGrammar_BadQueryIsAnError(t *testing.T) {
	g, err := NewGrammar(golang.GetLanguage(), "(no_such_node) @x")
	if err == nil || g != nil {
		t.Fatalf("NewGrammar = %v, %v; want an error", g, err)
	}
}

func TestParser_EachMatchesAndReportsErrors(t *testing.T) {
	g, err := NewGrammar(golang.GetLanguage(), "(function_declaration name: (identifier) @name)")
	if err != nil {
		t.Fatal(err)
	}
	defer g.Close()
	p := NewParser()
	defer p.Close()

	for _, tc := range []struct {
		src     string
		names   []string
		wantErr bool
	}{
		{"package a\nfunc A() {}\nfunc B() {}\n", []string{"A", "B"}, false},
		{"package a\nfunc A() {\nfunc B() {}\n", nil, true}, // errors stay local
	} {
		var names []string
		hasError, err := p.Each(g, []byte(tc.src), func(_ *Node, caps []Capture) {
			for _, c := range caps {
				if c.Name == "name" {
					names = append(names, c.Node.Utf8Text([]byte(tc.src)))
				}
			}
		})
		if err != nil {
			t.Fatal(err)
		}
		if hasError != tc.wantErr {
			t.Errorf("%q: hasError = %v, want %v", tc.src, hasError, tc.wantErr)
		}
		if tc.names != nil && len(names) != len(tc.names) {
			t.Errorf("%q: names = %v, want %v", tc.src, names, tc.names)
		}
	}
	p.Close() // a second Close is a no-op
	g.Close()
}
