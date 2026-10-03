//go:build codegrammars && cgo

package codeindex

import csharp "github.com/alexaandru/go-sitter-forest/c_sharp"

func init() { registerGrammar("c_sharp", csharp.GetLanguage) }
