//go:build codegrammars && cgo

package codeindex

import "github.com/alexaandru/go-sitter-forest/sql"

func init() { registerGrammar("sql", sql.GetLanguage) }
