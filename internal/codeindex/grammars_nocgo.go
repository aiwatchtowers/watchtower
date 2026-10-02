//go:build !cgo

package codeindex

// A CGO_ENABLED=0 build has no grammars: every file but a line-scanned one
// (Markdown) reports lang "" with no symbols, and the build and the tools
// still compile.

type noGrammars struct{}

func newParser() parser { return noGrammars{} }

func (noGrammars) parse(*langSpec, []byte) ([]Symbol, bool, error) { return nil, false, nil }

func (noGrammars) close() {}
