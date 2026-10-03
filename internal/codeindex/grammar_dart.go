//go:build codegrammars && cgo

package codeindex

import "github.com/alexaandru/go-sitter-forest/dart"

func init() { registerGrammar("dart", dart.GetLanguage) }
