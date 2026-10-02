//go:build codegrammars && cgo

package codeindex

import (
	"unsafe"

	"github.com/alexaandru/go-sitter-forest/bash"
	"github.com/alexaandru/go-sitter-forest/c"
	csharp "github.com/alexaandru/go-sitter-forest/c_sharp"
	"github.com/alexaandru/go-sitter-forest/clojure"
	"github.com/alexaandru/go-sitter-forest/cpp"
	"github.com/alexaandru/go-sitter-forest/dart"
	"github.com/alexaandru/go-sitter-forest/elixir"
	"github.com/alexaandru/go-sitter-forest/elm"
	"github.com/alexaandru/go-sitter-forest/erlang"
	golang "github.com/alexaandru/go-sitter-forest/go"
	"github.com/alexaandru/go-sitter-forest/graphql"
	"github.com/alexaandru/go-sitter-forest/groovy"
	"github.com/alexaandru/go-sitter-forest/haskell"
	"github.com/alexaandru/go-sitter-forest/hcl"
	"github.com/alexaandru/go-sitter-forest/java"
	"github.com/alexaandru/go-sitter-forest/javascript"
	"github.com/alexaandru/go-sitter-forest/julia"
	"github.com/alexaandru/go-sitter-forest/kotlin"
	"github.com/alexaandru/go-sitter-forest/lua"
	"github.com/alexaandru/go-sitter-forest/nim"
	"github.com/alexaandru/go-sitter-forest/objc"
	"github.com/alexaandru/go-sitter-forest/ocaml"
	"github.com/alexaandru/go-sitter-forest/perl"
	"github.com/alexaandru/go-sitter-forest/php"
	"github.com/alexaandru/go-sitter-forest/proto"
	"github.com/alexaandru/go-sitter-forest/python"
	"github.com/alexaandru/go-sitter-forest/r"
	"github.com/alexaandru/go-sitter-forest/ruby"
	"github.com/alexaandru/go-sitter-forest/rust"
	"github.com/alexaandru/go-sitter-forest/scala"
	"github.com/alexaandru/go-sitter-forest/sql"
	"github.com/alexaandru/go-sitter-forest/swift"
	"github.com/alexaandru/go-sitter-forest/tsx"
	"github.com/alexaandru/go-sitter-forest/typescript"
	"github.com/alexaandru/go-sitter-forest/zig"
)

// grammars are the languages this build parses: the release build's full
// set (`-tags codegrammars`). Each language joins with its query and its
// golden fixture.
var grammars = map[string]func() unsafe.Pointer{
	"bash":       bash.GetLanguage,
	"c":          c.GetLanguage,
	"c_sharp":    csharp.GetLanguage,
	"clojure":    clojure.GetLanguage,
	"cpp":        cpp.GetLanguage,
	"dart":       dart.GetLanguage,
	"elixir":     elixir.GetLanguage,
	"elm":        elm.GetLanguage,
	"erlang":     erlang.GetLanguage,
	"go":         golang.GetLanguage,
	"graphql":    graphql.GetLanguage,
	"groovy":     groovy.GetLanguage,
	"haskell":    haskell.GetLanguage,
	"hcl":        hcl.GetLanguage,
	"java":       java.GetLanguage,
	"javascript": javascript.GetLanguage,
	"julia":      julia.GetLanguage,
	"kotlin":     kotlin.GetLanguage,
	"lua":        lua.GetLanguage,
	"nim":        nim.GetLanguage,
	"objc":       objc.GetLanguage,
	"ocaml":      ocaml.GetLanguage,
	"perl":       perl.GetLanguage,
	"php":        php.GetLanguage,
	"proto":      proto.GetLanguage,
	"python":     python.GetLanguage,
	"r":          r.GetLanguage,
	"ruby":       ruby.GetLanguage,
	"rust":       rust.GetLanguage,
	"scala":      scala.GetLanguage,
	"sql":        sql.GetLanguage,
	"swift":      swift.GetLanguage,
	"tsx":        tsx.GetLanguage,
	"typescript": typescript.GetLanguage,
	"zig":        zig.GetLanguage,
}
