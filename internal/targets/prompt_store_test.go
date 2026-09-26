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
// template instead of the compiled-in ExtractPromptTemplate const.
//
// Both directions are asserted in one test on purpose — asserting only "the
// distinctive sentence appears" would also pass a build that ignores the
// store entirely but happens to prepend it somewhere; asserting only "the
// const's own sentence is absent" would pass a build that sends an empty or
// unrelated prompt. The pair together requires the true resolved template to
// reach the AI call. Asserting mere non-emptiness or "Generate was called
// once" would pass against an unwired seam — see the paired
// TestPipeline_Extract_FallsBackToCompiledConstWithoutStore for the "no
// store" half of the contract.
func TestPipeline_Extract_UsesPromptStoreOverride(t *testing.T) {
	d, err := db.Open(":memory:")
	require.NoError(t, err)
	defer d.Close()

	// The sentinel must appear nowhere in the compiled-in const, or "the
	// store was consulted" would also be satisfied by getPrompt falling
	// through to the fallback.
	const sentinel = "SENTINEL-CUSTOMIZED-TARGETS-EXTRACT-7C2E"
	require.NotContains(t, ExtractPromptTemplate, sentinel)

	verbs := strings.Count(ExtractPromptTemplate, "%s")
	require.Greater(t, verbs, 0, "ExtractPromptTemplate must carry %%s verbs")
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
		"the customized template must reach the AI call; the compiled const was used instead")
	require.NotContains(t, gen.lastSystem, "You are a goal-extraction assistant",
		"the compiled ExtractPromptTemplate's own opening sentence must not leak through a customized store")
}

// TestPipeline_Extract_FallsBackToCompiledConstWithoutStore is the
// no-store-set companion of the above: with SetPromptStore never called,
// Extract must render the compiled-in ExtractPromptTemplate.
func TestPipeline_Extract_FallsBackToCompiledConstWithoutStore(t *testing.T) {
	d, err := db.Open(":memory:")
	require.NoError(t, err)
	defer d.Close()

	gen := &mockGenerator{responses: []string{`{"extracted": [], "omitted_count": 0, "notes": ""}`}}
	p := New(d, nil, gen, nil, "", nil)

	_, err = p.Extract(context.Background(), ExtractRequest{RawText: "ship the thing"})
	require.NoError(t, err)

	require.Contains(t, gen.lastSystem, "You are a goal-extraction assistant",
		"with no prompt store set, Extract must fall back to the compiled ExtractPromptTemplate")
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
	require.NotContains(t, LinkPromptTemplate, sentinel)

	// LinkPromptTemplate's fmt.Sprintf call site takes one %d (target.ID)
	// followed by eight %s verbs (see buildLinkPrompt) — mirrored exactly
	// here rather than derived by counting, since the const mixes verb
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
		"the customized template must reach the AI call; the compiled const was used instead")
	require.NotContains(t, gen.lastSystem, "You are a goal-linking assistant",
		"the compiled LinkPromptTemplate's own opening sentence must not leak through a customized store")
}

// TestPipeline_LinkExisting_FallsBackToCompiledConstWithoutStore is the
// no-store-set companion of the above.
func TestPipeline_LinkExisting_FallsBackToCompiledConstWithoutStore(t *testing.T) {
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
		"with no prompt store set, LinkExisting must fall back to the compiled LinkPromptTemplate")
}

// TestExtractPromptTemplate_MatchesRegistryDefault is the drift guard from
// the 2026-09-23 reconciliation: internal/targets/prompts.go's compiled
// ExtractPromptTemplate (used as the getPrompt fallback only when no store
// is set, or when a store.Get call itself errors — with a store set and no
// row for the id, Store.Get returns prompts.Defaults[id] instead, never this
// const) and internal/prompts/defaults.go's registered defaultTargetsExtract
// (what Store.Get falls back to with no row, what Seed writes into a fresh
// targets.extract row, and what every non-customized row upgrades to on a
// version bump) must stay byte-identical — see prompts.Store.Seed and
// prompts.Store.Get. Before this reconciliation the two had drifted: the
// compiled const carried the GROUPING/sub_items/LANGUAGE rules added by fix
// b7640c0b, the registry default did not. This test fails the day either
// copy is edited without the other.
func TestExtractPromptTemplate_MatchesRegistryDefault(t *testing.T) {
	require.Equal(t, ExtractPromptTemplate, prompts.Defaults[prompts.TargetsExtract],
		"ExtractPromptTemplate (getPrompt's fallback) has drifted from prompts.Defaults[targets.extract] "+
			"(what Seed writes/upgrades a non-customized row to) — update both copies together")
}

// TestLinkPromptTemplate_MatchesRegistryDefault is the targets.link analogue
// of TestExtractPromptTemplate_MatchesRegistryDefault. The two copies were
// already byte-identical when the prompt-store seam was wired on 2026-09-23;
// this test pins that so a future edit to one copy alone is caught
// immediately rather than silently drifting like targets.extract did.
func TestLinkPromptTemplate_MatchesRegistryDefault(t *testing.T) {
	require.Equal(t, LinkPromptTemplate, prompts.Defaults[prompts.TargetsLink],
		"LinkPromptTemplate (getPrompt's fallback) has drifted from prompts.Defaults[targets.link] "+
			"(what Seed writes/upgrades a non-customized row to) — update both copies together")
}
