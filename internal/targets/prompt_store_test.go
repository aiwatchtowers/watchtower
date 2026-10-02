package targets

import (
	"context"
	"strings"
	"testing"

	"watchtower/internal/db"
	"watchtower/internal/prompts"

	"github.com/stretchr/testify/require"
)

// TestPipeline_Extract_UsesPromptStoreOverride pins the targets.extract
// SetPromptStore seam (wired 2026-09-23): when a prompt store is set and carries a
// customized targets.extract row, Extract must render that customized
// template instead of the registered prompts.Defaults[targets.extract].
//
// Both directions are asserted in one test on purpose — asserting only "the
// distinctive sentence appears" would also pass a build that ignores the
// store entirely but happens to prepend it somewhere; asserting only "the
// default's own sentence is absent" would pass a build that sends an empty or
// unrelated prompt. The pair together requires the true resolved template to
// reach the AI call. Asserting mere non-emptiness or "Generate was called
// once" would pass against an unwired seam — see the paired
// TestPipeline_Extract_FallsBackToRegistryDefaultWithoutStore for the "no
// store" half of the contract.
func TestPipeline_Extract_UsesPromptStoreOverride(t *testing.T) {
	d, err := db.Open(":memory:")
	require.NoError(t, err)
	defer d.Close()

	// The sentinel must appear nowhere in the registered default, or "the
	// store was consulted" would also be satisfied by getPrompt falling
	// through to the fallback.
	const sentinel = "SENTINEL-CUSTOMIZED-TARGETS-EXTRACT-7C2E"
	require.NotContains(t, prompts.Defaults[prompts.TargetsExtract], sentinel)

	verbs := strings.Count(prompts.Defaults[prompts.TargetsExtract], "%s")
	require.Greater(t, verbs, 0, "the targets.extract default must carry %%s verbs")
	customTmpl := sentinel + "\n" + strings.Repeat("%s\n", verbs)

	store := prompts.New(d, nil)
	require.NoError(t, store.Seed())
	require.NoError(t, store.Update(prompts.TargetsExtract, customTmpl, "test customization"))

	gen := &mockGenerator{responses: []string{`{"extracted": [], "omitted_count": 0, "notes": ""}`}}
	p := New(d, nil, gen, nil, "", nil)
	p.SetPromptStore(store)

	_, err = p.Extract(context.Background(), ExtractRequest{RawText: "ship the thing"})
	require.NoError(t, err)

	require.Contains(t, gen.lastSystem, sentinel,
		"the customized template must reach the AI call; the registered default was used instead")
	require.NotContains(t, gen.lastSystem, "You are a goal-extraction assistant",
		"the registered default's own opening sentence must not leak through a customized store")
}

// TestPipeline_Extract_FallsBackToRegistryDefaultWithoutStore is the
// no-store-set companion of the above: with SetPromptStore never called,
// Extract must render the registered targets.extract default.
func TestPipeline_Extract_FallsBackToRegistryDefaultWithoutStore(t *testing.T) {
	d, err := db.Open(":memory:")
	require.NoError(t, err)
	defer d.Close()

	gen := &mockGenerator{responses: []string{`{"extracted": [], "omitted_count": 0, "notes": ""}`}}
	p := New(d, nil, gen, nil, "", nil)

	_, err = p.Extract(context.Background(), ExtractRequest{RawText: "ship the thing"})
	require.NoError(t, err)

	require.Contains(t, gen.lastSystem, "You are a goal-extraction assistant",
		"with no prompt store set, Extract must fall back to the registered targets.extract default")
}

// TestPipeline_LinkExisting_UsesPromptStoreOverride is the targets.link
// analogue of TestPipeline_Extract_UsesPromptStoreOverride.
func TestPipeline_LinkExisting_UsesPromptStoreOverride(t *testing.T) {
	d, err := db.Open(":memory:")
	require.NoError(t, err)
	defer d.Close()

	targetID, err := d.CreateTarget(db.Target{
		Text:        "Write API spec",
		Level:       "week",
		PeriodStart: "2026-04-21",
		PeriodEnd:   "2026-04-27",
		Status:      "todo",
		Priority:    "medium",
		Ownership:   "mine",
		SourceType:  "manual",
	})
	require.NoError(t, err)

	const sentinel = "SENTINEL-CUSTOMIZED-TARGETS-LINK-3B9F"
	require.NotContains(t, prompts.Defaults[prompts.TargetsLink], sentinel)

	// The targets.link fmt.Sprintf call site takes one %d (target.ID)
	// followed by eight %s verbs (see buildLinkPrompt) — mirrored exactly
	// here rather than derived by counting, since the template mixes verb
	// kinds.
	customTmpl := sentinel + "\n%d %s %s %s %s %s %s %s %s\n"

	store := prompts.New(d, nil)
	require.NoError(t, store.Seed())
	require.NoError(t, store.Update(prompts.TargetsLink, customTmpl, "test customization"))

	gen := &mockGenerator{responses: []string{`{"parent_id": null, "secondary_links": []}`}}
	p := New(d, nil, gen, nil, "", nil)
	p.SetPromptStore(store)

	_, err = p.LinkExisting(context.Background(), targetID)
	require.NoError(t, err)

	require.Contains(t, gen.lastSystem, sentinel,
		"the customized template must reach the AI call; the registered default was used instead")
	require.NotContains(t, gen.lastSystem, "You are a goal-linking assistant",
		"the registered default's own opening sentence must not leak through a customized store")
}

// TestPipeline_LinkExisting_FallsBackToRegistryDefaultWithoutStore is the
// no-store-set companion of the above.
func TestPipeline_LinkExisting_FallsBackToRegistryDefaultWithoutStore(t *testing.T) {
	d, err := db.Open(":memory:")
	require.NoError(t, err)
	defer d.Close()

	targetID, err := d.CreateTarget(db.Target{
		Text:        "Write API spec",
		Level:       "week",
		PeriodStart: "2026-04-21",
		PeriodEnd:   "2026-04-27",
		Status:      "todo",
		Priority:    "medium",
		Ownership:   "mine",
		SourceType:  "manual",
	})
	require.NoError(t, err)

	gen := &mockGenerator{responses: []string{`{"parent_id": null, "secondary_links": []}`}}
	p := New(d, nil, gen, nil, "", nil)

	_, err = p.LinkExisting(context.Background(), targetID)
	require.NoError(t, err)

	require.Contains(t, gen.lastSystem, "You are a goal-linking assistant",
		"with no prompt store set, LinkExisting must fall back to the registered targets.link default")
}
