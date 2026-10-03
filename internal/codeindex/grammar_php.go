//go:build codegrammars && cgo

package codeindex

import "github.com/alexaandru/go-sitter-forest/php"

func init() { registerGrammar("php", php.GetLanguage) }
