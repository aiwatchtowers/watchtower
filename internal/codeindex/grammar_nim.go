//go:build codegrammars && cgo

package codeindex

import "github.com/alexaandru/go-sitter-forest/nim"

func init() { registerGrammar("nim", nim.GetLanguage) }
