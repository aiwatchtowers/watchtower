//go:build codegrammars && cgo

package codeindex

import (
	"unsafe"

	"github.com/alexaandru/go-sitter-forest/c"
	csharp "github.com/alexaandru/go-sitter-forest/c_sharp"
	"github.com/alexaandru/go-sitter-forest/cpp"
	"github.com/alexaandru/go-sitter-forest/dart"
	"github.com/alexaandru/go-sitter-forest/elixir"
	"github.com/alexaandru/go-sitter-forest/elm"
	golang "github.com/alexaandru/go-sitter-forest/go"
	"github.com/alexaandru/go-sitter-forest/java"
	"github.com/alexaandru/go-sitter-forest/javascript"
	"github.com/alexaandru/go-sitter-forest/lua"
	"github.com/alexaandru/go-sitter-forest/ocaml"
	"github.com/alexaandru/go-sitter-forest/php"
	"github.com/alexaandru/go-sitter-forest/python"
	"github.com/alexaandru/go-sitter-forest/r"
	"github.com/alexaandru/go-sitter-forest/ruby"
	"github.com/alexaandru/go-sitter-forest/rust"
	"github.com/alexaandru/go-sitter-forest/scala"
	"github.com/alexaandru/go-sitter-forest/swift"
	"github.com/alexaandru/go-sitter-forest/tsx"
	"github.com/alexaandru/go-sitter-forest/typescript"
)

// grammars are the languages this build parses: the release build's full
// set (`-tags codegrammars`). Each language joins with its query and its
// golden fixture.
var grammars = map[string]func() unsafe.Pointer{
	"c":          c.GetLanguage,
	"c_sharp":    csharp.GetLanguage,
	"cpp":        cpp.GetLanguage,
	"dart":       dart.GetLanguage,
	"elixir":     elixir.GetLanguage,
	"elm":        elm.GetLanguage,
	"go":         golang.GetLanguage,
	"java":       java.GetLanguage,
	"javascript": javascript.GetLanguage,
	"lua":        lua.GetLanguage,
	"ocaml":      ocaml.GetLanguage,
	"php":        php.GetLanguage,
	"python":     python.GetLanguage,
	"r":          r.GetLanguage,
	"ruby":       ruby.GetLanguage,
	"rust":       rust.GetLanguage,
	"scala":      scala.GetLanguage,
	"swift":      swift.GetLanguage,
	"tsx":        tsx.GetLanguage,
	"typescript": typescript.GetLanguage,
}
