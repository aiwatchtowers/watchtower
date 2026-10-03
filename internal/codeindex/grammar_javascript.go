//go:build codegrammars && cgo

package codeindex

import "github.com/alexaandru/go-sitter-forest/javascript"

func init() { registerGrammar("javascript", javascript.GetLanguage) }
