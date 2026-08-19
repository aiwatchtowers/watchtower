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

// TestPersonaMergeVersionFloors pins the floors set by the 2026-08-19 persona
// merge: every prompt whose default text was reworded (secretary → assistant)
// carries at least the bumped version, so Seed's auto-upgrade
// (existing.Version < defaultVer) reaches installed non-customized rows.
// Silently reverting a bump would leave installs on the pre-merge wording and
// fail here; a later intentional bump only raises a version and still passes.
func TestPersonaMergeVersionFloors(t *testing.T) {
	floors := map[string]int{
		BriefingDaily:              7,
		InboxTriage:                2,
		MeetingPrep:                5,
		DayPlanGenerate:            4,
		InboxCompose:               4,
		InboxSituationCard:         2,
		MemoryExtractEpisodes:      2,
		MemoryExtractEpisodesBatch: 3,
		MemoryExtractEmailEpisodes: 2,
		MemoryEntityRewrite:        2,
		MemoryReviseBeliefs:        2,
		MemoryRenderMap:            2,
		MemoryReflect:              2,
		MemoryRenderChannelDigest:  2,
		IdeasDigestEmail:           2,
		IdeasDigestJira:            2,
		IdeasConsolidate:           4,
	}
	for id, floor := range floors {
		assert.GreaterOrEqual(t, DefaultVersions[id], floor,
			"%q was reworded by the persona merge and must stay at v%d or later", id, floor)
	}
}

// TestMemorySemanticPromptsRegistered pins the Phase-3 semantic-tier prompts
// (plus the Phase-4 reflection prompt) into every registration surface:
// constant → Defaults template, AllIDs display order, DefaultVersions,
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
			assert.GreaterOrEqual(t, DefaultVersions[id], 1, "%q must be registered in DefaultVersions", id)
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
// DefaultVersions, Descriptions), carrying the language directive and never
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
	assert.GreaterOrEqual(t, DefaultVersions[id], 1, "%q must be registered in DefaultVersions", id)
	assert.NotEmpty(t, Descriptions[id], "Descriptions must contain %q", id)

	rendered := DefaultFor(id)
	assert.True(t, HasDirective(fmt.Sprintf(rendered, Directive(""))),
		"%q must carry the language directive placeholder", id)
	assert.False(t, strings.HasPrefix(rendered, "-"), "%q must not begin with a dash", id)
}

// TestDictationCleanPromptRegistered pins the dictation.clean light-tier prompt
// into all four registration surfaces (Defaults, AllIDs, DefaultVersions v1,
// Descriptions), carrying mode instructions and language directive placeholders
// and never beginning with a dash.
func TestDictationCleanPromptRegistered(t *testing.T) {
	id := DictationClean
	tmpl, ok := Defaults[id]
	if !ok {
		t.Fatalf("Defaults is missing %q", id)
	}
	if !contains(AllIDs, id) {
		t.Fatalf("AllIDs is missing %q", id)
	}
	if DefaultVersions[id] != 1 {
		t.Fatalf("DefaultVersions[%q] = %d, want 1", id, DefaultVersions[id])
	}
	if _, ok := Descriptions[id]; !ok {
		t.Fatalf("Descriptions is missing %q", id)
	}
	rendered := fmt.Sprintf(tmpl, "MODE INSTRUCTIONS", Directive("Russian"))
	if !HasDirective(rendered) {
		t.Fatalf("rendered template must carry the language directive")
	}
	if strings.HasPrefix(rendered, "-") {
		t.Fatalf("template must not begin with '-' (claude CLI argv gotcha)")
	}
}

// contains checks if a slice contains a string value.
func contains(slice []string, val string) bool {
	for _, v := range slice {
		if v == val {
			return true
		}
	}
	return false
}
