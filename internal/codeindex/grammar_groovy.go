//go:build codegrammars && cgo

package codeindex

import "github.com/alexaandru/go-sitter-forest/groovy"

func init() { registerGrammar("groovy", groovy.GetLanguage) }
