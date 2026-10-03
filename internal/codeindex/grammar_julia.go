//go:build codegrammars && cgo

package codeindex

import "github.com/alexaandru/go-sitter-forest/julia"

func init() { registerGrammar("julia", julia.GetLanguage) }
