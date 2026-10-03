//go:build codegrammars && cgo

package codeindex

import "github.com/alexaandru/go-sitter-forest/scala"

func init() { registerGrammar("scala", scala.GetLanguage) }
