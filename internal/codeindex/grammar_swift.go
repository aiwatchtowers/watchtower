//go:build codegrammars && cgo

package codeindex

import "github.com/alexaandru/go-sitter-forest/swift"

func init() { registerGrammar("swift", swift.GetLanguage) }
