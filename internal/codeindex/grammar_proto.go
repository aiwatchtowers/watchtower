//go:build codegrammars && cgo

package codeindex

import "github.com/alexaandru/go-sitter-forest/proto"

func init() { registerGrammar("proto", proto.GetLanguage) }
