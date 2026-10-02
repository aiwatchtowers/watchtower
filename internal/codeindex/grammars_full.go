//go:build codegrammars && cgo

package codeindex

import (
	"unsafe"

	golang "github.com/alexaandru/go-sitter-forest/go"
	"github.com/alexaandru/go-sitter-forest/python"
	"github.com/alexaandru/go-sitter-forest/rust"
	"github.com/alexaandru/go-sitter-forest/swift"
)

// grammars are the languages this build parses: the release build's full
// set (`-tags codegrammars`). Each language joins with its query and its
// golden fixture.
var grammars = map[string]func() unsafe.Pointer{
	"go":     golang.GetLanguage,
	"python": python.GetLanguage,
	"rust":   rust.GetLanguage,
	"swift":  swift.GetLanguage,
}
