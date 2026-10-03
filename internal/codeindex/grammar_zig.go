//go:build codegrammars && cgo

package codeindex

import "github.com/alexaandru/go-sitter-forest/zig"

func init() { registerGrammar("zig", zig.GetLanguage) }
