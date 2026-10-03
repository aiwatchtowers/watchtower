//go:build codegrammars && cgo

package codeindex

import "github.com/alexaandru/go-sitter-forest/lua"

func init() { registerGrammar("lua", lua.GetLanguage) }
