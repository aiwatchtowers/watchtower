//go:build !codegrammars && cgo

package codeindex

import (
	"unsafe"

	golang "github.com/alexaandru/go-sitter-forest/go"
	"github.com/alexaandru/go-sitter-forest/python"
	"github.com/alexaandru/go-sitter-forest/swift"
)

// grammars are the languages this build parses: an untagged cgo build (CI,
// the inner loop) carries only the three the index's own tests need.
var grammars = map[string]func() unsafe.Pointer{
	"go":     golang.GetLanguage,
	"python": python.GetLanguage,
	"swift":  swift.GetLanguage,
}
