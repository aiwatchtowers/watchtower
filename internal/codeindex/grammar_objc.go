//go:build codegrammars && cgo

package codeindex

import "github.com/alexaandru/go-sitter-forest/objc"

func init() { registerGrammar("objc", objc.GetLanguage) }
