//go:build codegrammars && cgo

package codeindex

import "github.com/alexaandru/go-sitter-forest/hcl"

func init() { registerGrammar("hcl", hcl.GetLanguage) }
