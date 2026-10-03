//go:build codegrammars && cgo

package codeindex

import (
	"fmt"
	"unsafe"
)

// grammars are the languages this build parses: the release build's full
// set (`-tags codegrammars`). Each language registers itself from its own
// grammar_<id>.go (one import per file, so no file is a dependency hub),
// joining with its query and its golden fixture. It is a map filled by
// init functions: the order they run in changes nothing.
var grammars = map[string]func() unsafe.Pointer{}

// registerGrammar adds language id's grammar; a second registration of the
// same id is a programming error.
func registerGrammar(id string, lang func() unsafe.Pointer) {
	if _, dup := grammars[id]; dup {
		panic(fmt.Sprintf("codeindex: grammar %q registered twice", id))
	}
	grammars[id] = lang
}
