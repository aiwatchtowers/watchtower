// Package reviewai holds the diff reviewer's model calls: the pre-read
// overview and the "find repeats" lessons. Replies are validated entry by
// entry; the model never decides what the Desktop trusts.
package reviewai

import (
	"log"

	"watchtower/internal/digest"
	"watchtower/internal/prompts"
)

// Pipeline runs the reviewer's model calls through a digest.Generator.
type Pipeline struct {
	gen   digest.Generator
	store *prompts.Store
}

func New(gen digest.Generator) *Pipeline { return &Pipeline{gen: gen} }

// SetPromptStore lets Settings → Prompts tune the templates.
func (p *Pipeline) SetPromptStore(s *prompts.Store) { p.store = s }

func (p *Pipeline) getPrompt(id string) string {
	tmpl, _, err := prompts.Resolve(p.store, id, "")
	if err != nil {
		log.Printf("reviewai: prompt %s: %v (using the fallback)", id, err)
	}
	return tmpl
}
