package codeindex

import "encoding/json"

// Kind is a symbol's kind — a closed set (spec §6.1). A query capture that
// maps to none of them is dropped.
type Kind string

// The kinds a symbol can have.
const (
	KindFunction  Kind = "function"
	KindMethod    Kind = "method"
	KindClass     Kind = "class"
	KindStruct    Kind = "struct"
	KindEnum      Kind = "enum"
	KindProtocol  Kind = "protocol"
	KindInterface Kind = "interface"
	KindType      Kind = "type"
	KindConst     Kind = "const"
	KindVar       Kind = "var"
	KindField     Kind = "field"
	KindModule    Kind = "module"
	KindMacro     Kind = "macro"
)

// kinds is the closed set, for validating a capture name.
var kinds = map[Kind]bool{
	KindFunction: true, KindMethod: true, KindClass: true, KindStruct: true, KindEnum: true,
	KindProtocol: true, KindInterface: true, KindType: true, KindConst: true, KindVar: true,
	KindField: true, KindModule: true, KindMacro: true,
}

// containerKinds are the kinds whose name becomes the container of the
// symbols defined inside them.
var containerKinds = map[Kind]bool{
	KindClass: true, KindStruct: true, KindEnum: true, KindProtocol: true,
	KindInterface: true, KindType: true, KindModule: true,
}

// Symbol is one definition (spec §6.1, the Go↔Swift contract).
type Symbol struct {
	Name string `json:"name"`
	Kind Kind   `json:"kind"`
	// Path is relative to the indexed folder, slash-separated.
	Path string `json:"path"`
	// Line and EndLine are 1-based; Col is the 1-based UTF-16 column of
	// the name (what Monaco and NSString count).
	Line    int `json:"line"`
	Col     int `json:"col"`
	EndLine int `json:"end_line"`
	// Container is the nearest enclosing type or module, "" at top level.
	Container string `json:"container"`
	// Signature is the definition up to its body, whitespace collapsed,
	// at most 200 characters.
	Signature string `json:"signature"`
	// Doc is the first sentence of the doc comment, at most 200 characters.
	Doc  string `json:"doc"`
	Lang string `json:"lang"`
	// Outline marks a document-outline entry (a Markdown heading): shown
	// in the jump bar, kept out of Open Quickly's Symbols scope.
	Outline bool `json:"outline,omitempty"`
}

// FileResult is one file's line of the index stream.
type FileResult struct {
	File string
	// Lang is "" for a file this build cannot index.
	Lang    string
	Symbols []Symbol
	// Deleted: a path asked for by name is no longer a file.
	Deleted bool
}

// MarshalJSON writes {"file","lang","symbols"} — symbols always a list —
// or {"file","deleted":true} for a deleted path (spec §6.2).
func (r FileResult) MarshalJSON() ([]byte, error) {
	if r.Deleted {
		return json.Marshal(struct {
			File    string `json:"file"`
			Deleted bool   `json:"deleted"`
		}{r.File, true})
	}
	syms := r.Symbols
	if syms == nil {
		syms = []Symbol{}
	}
	return json.Marshal(struct {
		File    string   `json:"file"`
		Lang    string   `json:"lang"`
		Symbols []Symbol `json:"symbols"`
	}{r.File, r.Lang, syms})
}

// Summary totals one run.
type Summary struct {
	// Files counts the file lines emitted, deleted ones included.
	Files   int
	Symbols int
}
