//go:build codegrammars && cgo

package codeindex

import golang "github.com/alexaandru/go-sitter-forest/go"

func init() { registerGrammar("go", golang.GetLanguage) }
