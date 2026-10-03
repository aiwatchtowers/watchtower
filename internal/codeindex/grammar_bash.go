//go:build codegrammars && cgo

package codeindex

import "github.com/alexaandru/go-sitter-forest/bash"

func init() { registerGrammar("bash", bash.GetLanguage) }
