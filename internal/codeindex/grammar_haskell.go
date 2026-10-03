//go:build codegrammars && cgo

package codeindex

import "github.com/alexaandru/go-sitter-forest/haskell"

func init() { registerGrammar("haskell", haskell.GetLanguage) }
