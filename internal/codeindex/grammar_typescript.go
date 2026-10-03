//go:build codegrammars && cgo

package codeindex

import "github.com/alexaandru/go-sitter-forest/typescript"

func init() { registerGrammar("typescript", typescript.GetLanguage) }
