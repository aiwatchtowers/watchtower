//go:build codegrammars && cgo

package codeindex

import "github.com/alexaandru/go-sitter-forest/r"

func init() { registerGrammar("r", r.GetLanguage) }
