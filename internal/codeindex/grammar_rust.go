//go:build codegrammars && cgo

package codeindex

import "github.com/alexaandru/go-sitter-forest/rust"

func init() { registerGrammar("rust", rust.GetLanguage) }
