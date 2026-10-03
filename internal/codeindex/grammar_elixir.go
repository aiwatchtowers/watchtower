//go:build codegrammars && cgo

package codeindex

import "github.com/alexaandru/go-sitter-forest/elixir"

func init() { registerGrammar("elixir", elixir.GetLanguage) }
