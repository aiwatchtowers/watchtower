//go:build codegrammars && cgo

package codeindex

import "github.com/alexaandru/go-sitter-forest/python"

func init() { registerGrammar("python", python.GetLanguage) }
