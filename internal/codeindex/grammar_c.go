//go:build codegrammars && cgo

package codeindex

import "github.com/alexaandru/go-sitter-forest/c"

func init() { registerGrammar("c", c.GetLanguage) }
