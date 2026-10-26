package digest_test

import (
	"testing"
	"time"

	"watchtower/internal/digest"
	"watchtower/internal/ollama"
	"watchtower/internal/sessions"
)

// The daemon hands pipelines the pooled, call-bounded generator; an image
// pass must still find the Claude generator's image call through both
// wrappers, and must find none behind a text-only provider.
func TestImageCapable_ThroughPooled(t *testing.T) {
	pool := sessions.NewSessionPool(1)
	t.Cleanup(pool.Close)
	wrap := func(g digest.Generator) digest.Generator {
		return digest.NewPooledGenerator(digest.WithCallTimeout(g, time.Minute), pool)
	}

	claude := digest.NewClaudeGenerator("l", "s", "")
	if _, ok := digest.ImageCapable(claude); !ok {
		t.Error("a bare Claude generator is not image capable")
	}
	if _, ok := digest.ImageCapable(wrap(claude)); !ok {
		t.Error("a pooled, call-bounded Claude generator is not image capable")
	}
	if _, ok := digest.ImageCapable(wrap(ollama.NewGenerator("l", "s", "http://localhost:11434"))); ok {
		t.Error("a pooled Ollama generator reports image capable")
	}
	if _, ok := digest.ImageCapable(ollama.NewGenerator("l", "s", "http://localhost:11434")); ok {
		t.Error("a bare Ollama generator reports image capable")
	}
}
