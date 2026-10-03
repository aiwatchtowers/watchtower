//go:build codegrammars && cgo

package codeindex

import "github.com/alexaandru/go-sitter-forest/kotlin"

func init() { registerGrammar("kotlin", kotlin.GetLanguage) }
