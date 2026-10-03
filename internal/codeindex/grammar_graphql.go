//go:build codegrammars && cgo

package codeindex

import "github.com/alexaandru/go-sitter-forest/graphql"

func init() { registerGrammar("graphql", graphql.GetLanguage) }
