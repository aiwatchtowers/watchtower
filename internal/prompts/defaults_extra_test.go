package prompts

import (
	"fmt"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestDefaultFor_KnownKey(t *testing.T) {
	got := DefaultFor(DigestChannel)
	assert.NotEmpty(t, got, "known prompt key should return a non-empty default")
}

func TestDefaultFor_UnknownKey(t *testing.T) {
	got := DefaultFor("nonexistent.prompt.key")
	assert.Empty(t, got)
}

func TestDefaultFor_AllKnownKeysHaveDefaults(t *testing.T) {
	// Every key listed in CurrentVersions must have a non-empty default.
	for key := range DefaultVersions {
		assert.NotEmpty(t, DefaultFor(key), "missing default for known key %q", key)
	}
}

// TestMemorySemanticPromptsRegistered pins the Phase-3 semantic-tier prompts
// (plus the Phase-4 reflection prompt) into every registration surface:
// constant → Defaults template, AllIDs display order, DefaultVersions (v1),
// and Descriptions. Each template must open with the language Directive
// placeholder and must never begin with a dash (the claude-CLI argv gotcha
// guarded for the extract builders).
func TestMemorySemanticPromptsRegistered(t *testing.T) {
	ids := []string{MemoryEntityRewrite, MemoryReviseBeliefs, MemoryRenderMap, MemoryReflect}

	allIDs := make(map[string]bool, len(AllIDs))
	for _, id := range AllIDs {
		allIDs[id] = true
	}

	for _, id := range ids {
		t.Run(id, func(t *testing.T) {
			tmpl, ok := Defaults[id]
			assert.True(t, ok, "Defaults must contain %q", id)
			assert.NotEmpty(t, tmpl, "template for %q must be non-empty", id)
			assert.True(t, allIDs[id], "AllIDs must contain %q", id)
			assert.Equal(t, 1, DefaultVersions[id], "%q must be registered at v1", id)
			assert.NotEmpty(t, Descriptions[id], "Descriptions must contain %q", id)

			// Language directive slot: the template's first verb is filled by
			// prompts.Directive, so rendering it must produce a directive.
			rendered := DefaultFor(id)
			assert.True(t, HasDirective(fmt.Sprintf(rendered, Directive(""))),
				"%q must carry the language directive placeholder", id)
			assert.False(t, strings.HasPrefix(rendered, "-"),
				"%q template must not begin with a dash", id)
		})
	}
}

// TestMemoryRenderPromptRegistered pins the Phase-5 slice-3 channel-digest
// render prompt into all four registration surfaces (Defaults, AllIDs,
// DefaultVersions v1, Descriptions), carrying the language directive and never
// beginning with a dash.
func TestMemoryRenderPromptRegistered(t *testing.T) {
	id := MemoryRenderChannelDigest

	allIDs := make(map[string]bool, len(AllIDs))
	for _, x := range AllIDs {
		allIDs[x] = true
	}

	tmpl, ok := Defaults[id]
	assert.True(t, ok, "Defaults must contain %q", id)
	assert.NotEmpty(t, tmpl)
	assert.True(t, allIDs[id], "AllIDs must contain %q", id)
	assert.Equal(t, 1, DefaultVersions[id], "%q must be registered at v1", id)
	assert.NotEmpty(t, Descriptions[id], "Descriptions must contain %q", id)

	rendered := DefaultFor(id)
	assert.True(t, HasDirective(fmt.Sprintf(rendered, Directive(""))),
		"%q must carry the language directive placeholder", id)
	assert.False(t, strings.HasPrefix(rendered, "-"), "%q must not begin with a dash", id)
}
