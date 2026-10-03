//go:build codegrammars && cgo

package codeindex

import "github.com/alexaandru/go-sitter-forest/erlang"

func init() { registerGrammar("erlang", erlang.GetLanguage) }
