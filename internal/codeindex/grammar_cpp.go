//go:build codegrammars && cgo

package codeindex

import "github.com/alexaandru/go-sitter-forest/cpp"

func init() { registerGrammar("cpp", cpp.GetLanguage) }
