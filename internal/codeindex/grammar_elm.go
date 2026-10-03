//go:build codegrammars && cgo

package codeindex

import "github.com/alexaandru/go-sitter-forest/elm"

func init() { registerGrammar("elm", elm.GetLanguage) }
