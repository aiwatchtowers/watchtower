//go:build codegrammars && cgo

package codeindex

import "github.com/alexaandru/go-sitter-forest/java"

func init() { registerGrammar("java", java.GetLanguage) }
