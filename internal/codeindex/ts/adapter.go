//go:build cgo

// Package ts is the only user of the official tree-sitter runtime
// (github.com/tree-sitter/go-tree-sitter). That binding has no finalizers:
// a parser, tree, query or query cursor that is not closed leaks C memory.
// This adapter owns every Close(): a tree lives only for the duration of
// one Parser.Each call, and the parser closes its own query cursor.
//
// It deliberately avoids the binding's ParseWithOptions (it registers its
// options in a pointer table it never releases — one leaked entry per
// parse) and the deprecated cancellation flag; callers cancel between files.
package ts

import (
	"fmt"
	"unsafe"

	sitter "github.com/tree-sitter/go-tree-sitter"
)

// Node is a syntax node. It is valid only inside the Each callback that
// handed it out: its tree is closed when Each returns.
type Node = sitter.Node

// Capture is one named capture of a query match.
type Capture struct {
	Name string
	Node Node
}

// Grammar is a language with its compiled tags query. It is built once per
// language and shared by every parser (a compiled query is immutable and
// safe to use from several cursors at once).
type Grammar struct {
	lang  *sitter.Language
	query *sitter.Query
	names []string
}

// NewGrammar wraps a grammar's TSLanguage pointer (a go-sitter-forest
// GetLanguage result) and compiles query against it.
func NewGrammar(language unsafe.Pointer, query string) (*Grammar, error) {
	lang := sitter.NewLanguage(language)
	q, qerr := sitter.NewQuery(lang, query)
	if qerr != nil {
		return nil, fmt.Errorf("compiling query: %w", qerr)
	}
	return &Grammar{lang: lang, query: q, names: q.CaptureNames()}, nil
}

// Close frees the compiled query. Grammars normally live for the process.
func (g *Grammar) Close() {
	if g.query != nil {
		g.query.Close()
		g.query = nil
	}
}

// Parser is one worker's parser and query cursor, reused across files.
// It is not safe for concurrent use.
type Parser struct {
	p  *sitter.Parser
	qc *sitter.QueryCursor
}

// NewParser allocates a parser and a query cursor; Close frees both.
func NewParser() *Parser {
	return &Parser{p: sitter.NewParser(), qc: sitter.NewQueryCursor()}
}

// Close frees the parser and its cursor.
func (p *Parser) Close() {
	if p.p != nil {
		p.qc.Close()
		p.p.Close()
		p.p, p.qc = nil, nil
	}
}

// Each parses src with g and calls fn once per query match, in document
// order. The tree is closed when Each returns, so neither the root nor any
// captured node may be kept past fn. hasError reports ERROR or MISSING
// nodes in the tree; a file with them is still matched for what parsed.
func (p *Parser) Each(g *Grammar, src []byte, fn func(root *Node, captures []Capture)) (hasError bool, err error) {
	if err := p.p.SetLanguage(g.lang); err != nil {
		return false, fmt.Errorf("setting language: %w", err)
	}
	tree := p.p.Parse(src, nil)
	if tree == nil {
		return false, fmt.Errorf("parse returned no tree")
	}
	defer tree.Close()
	root := tree.RootNode()
	matches := p.qc.Matches(g.query, root, src)
	var caps []Capture
	for m := matches.Next(); m != nil; m = matches.Next() {
		caps = caps[:0]
		for _, c := range m.Captures {
			caps = append(caps, Capture{Name: g.names[c.Index], Node: c.Node})
		}
		fn(root, caps)
	}
	return root.HasError(), nil
}
