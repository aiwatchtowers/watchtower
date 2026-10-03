//go:build codegrammars && cgo

package codeindex

import "github.com/alexaandru/go-sitter-forest/ocaml"

func init() { registerGrammar("ocaml", ocaml.GetLanguage) }
