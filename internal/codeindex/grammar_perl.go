//go:build codegrammars && cgo

package codeindex

import "github.com/alexaandru/go-sitter-forest/perl"

func init() { registerGrammar("perl", perl.GetLanguage) }
