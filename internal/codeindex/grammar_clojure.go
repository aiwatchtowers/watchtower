//go:build codegrammars && cgo

package codeindex

import "github.com/alexaandru/go-sitter-forest/clojure"

func init() { registerGrammar("clojure", clojure.GetLanguage) }
