//go:build codegrammars && cgo

package codeindex

import "github.com/alexaandru/go-sitter-forest/tsx"

func init() { registerGrammar("tsx", tsx.GetLanguage) }
