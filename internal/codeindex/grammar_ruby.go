//go:build codegrammars && cgo

package codeindex

import "github.com/alexaandru/go-sitter-forest/ruby"

func init() { registerGrammar("ruby", ruby.GetLanguage) }
