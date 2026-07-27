package briefing

import (
	"context"
	"encoding/json"
	"io"
	"log"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/memory"
	"watchtower/internal/prompts"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// validBriefingResponse is a minimal well-formed AI reply so RunForDate reaches
// the Generate call and stores a briefing.
const validBriefingResponse = `{
	"attention": [],
	"your_day": [],
	"what_happened": [{"text": "release scheduled", "digest_id": 1, "channel_name": "#c1", "item_type": "decision", "importance": "high"}],
	"team_pulse": [],
	"coaching": []
}`

// setupBriefingWithVault wires a temp HOME so WorkspaceDir lands in a temp dir,
// seeds a workspace/user/digest (so the briefing has data), and initializes an
// empty memory vault at <WorkspaceDir>/memory. The briefing gate is ON.
func setupBriefingWithVault(t *testing.T) (*db.DB, *config.Config, string) {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)

	database := testDB(t)
	require.NoError(t, database.UpsertWorkspace(db.Workspace{ID: "T1", Name: "test", Domain: "test"}))
	require.NoError(t, database.SetCurrentUserID("U001"))
	require.NoError(t, database.UpsertUser(db.User{ID: "U001", Name: "alice", DisplayName: "Alice"}))

	now := time.Now()
	dayStart := time.Date(now.Year(), now.Month(), now.Day()-1, 0, 0, 0, 0, now.Location())
	dayEnd := time.Date(now.Year(), now.Month(), now.Day()+1, 0, 0, 0, 0, now.Location())
	_, err := database.UpsertDigest(db.Digest{
		ChannelID:    "C1",
		Type:         "channel",
		PeriodFrom:   float64(dayStart.Unix()),
		PeriodTo:     float64(dayEnd.Unix()),
		Summary:      "Feature release discussion",
		Topics:       `["release"]`,
		Decisions:    `[]`,
		ActionItems:  `[]`,
		MessageCount: 15,
	})
	require.NoError(t, err)

	cfg := testConfig()
	cfg.ActiveWorkspace = "default"
	cfg.Memory.Surfaces.Briefing = true

	require.NoError(t, os.MkdirAll(cfg.WorkspaceDir(), 0o755))
	vaultPath := filepath.Join(cfg.WorkspaceDir(), "memory")
	_, err = memory.OpenVault(vaultPath)
	require.NoError(t, err)

	return database, cfg, vaultPath
}

// writeBelief writes a belief node to the vault worktree and mirrors it into the
// SQLite index so ListMemoryNodes returns it and ReadNode can parse it.
func writeBelief(t *testing.T, database *db.DB, vaultPath, id, title, status string, confidence float64, history string) {
	t.Helper()
	body := "# " + title + "\n\n## Evidence\n- observed for C1 100\n\n## History\n" + history
	n := memory.Node{
		ID:         id,
		Type:       "belief",
		Tier:       "long",
		Status:     status,
		Confidence: confidence,
		Subject:    "ent_bob",
		Title:      title,
		Body:       body,
	}
	rel := filepath.Join(vaultPath, "beliefs", id+".md")
	require.NoError(t, os.WriteFile(rel, n.Render(), 0o644))
	require.NoError(t, database.UpsertMemoryNode(db.MemoryNodeRow{
		ID:          id,
		Type:        "belief",
		Tier:        "long",
		Status:      status,
		Title:       title,
		Path:        "beliefs/" + id + ".md",
		ContentHash: "h-" + id,
		IndexedAt:   "2026-07-16T00:00:00Z",
		Subject:     "ent_bob",
		Confidence:  confidence,
	}, body, nil))
}

// runBriefingCapturing runs the pipeline with a capturing generator and returns
// the system prompt it was asked to generate from.
func runBriefingCapturing(t *testing.T, database *db.DB, cfg *config.Config) string {
	t.Helper()
	gen := &capturingGenerator{response: validBriefingResponse}
	pipe := New(database, cfg, gen, log.New(io.Discard, "", 0))
	today := time.Now().Format("2006-01-02")
	_, err := pipe.RunForDate(context.Background(), today)
	require.NoError(t, err)
	return gen.systemMsg
}

// memoryRevisionsSection returns the text after the "=== MEMORY REVISIONS ==="
// header (that section is rendered last in the template).
func memoryRevisionsSection(t *testing.T, prompt string) string {
	t.Helper()
	const header = "=== MEMORY REVISIONS ==="
	idx := strings.Index(prompt, header)
	require.GreaterOrEqual(t, idx, 0, "prompt must carry a MEMORY REVISIONS section")
	return strings.TrimSpace(prompt[idx+len(header):])
}

func TestGatherMemoryRevisions_StatusTransitionSurfaces(t *testing.T) {
	database, cfg, vaultPath := setupBriefingWithVault(t)
	today := time.Now().UTC().Format("2006-01-02")

	writeBelief(t, database, vaultPath, "bel_shaken", "Bob prefers async reviews", "shaken", 0.4,
		"- 2020-01-01: created — first observed\n- "+today+": shake — evidence now conflicts with recent messages\n")

	prompt := runBriefingCapturing(t, database, cfg)
	section := memoryRevisionsSection(t, prompt)

	assert.Contains(t, section, "Bob prefers async reviews")
	assert.Contains(t, section, "shaken")
	assert.NotContains(t, section, "(no notable revisions)")
}

func TestGatherMemoryRevisions_SubThresholdConfidenceWiggleOmitted(t *testing.T) {
	database, cfg, vaultPath := setupBriefingWithVault(t)
	today := time.Now().UTC().Format("2006-01-02")

	// Old creation is out of window; a single in-window confirm moves confidence
	// by 0.1 only — below the 0.2 notability threshold and not a status change.
	writeBelief(t, database, vaultPath, "bel_wiggle", "Alice owns the deploy pipeline", "active", 0.6,
		"- 2020-01-01: created — first observed\n- "+today+": confirm — one more supporting message\n")

	prompt := runBriefingCapturing(t, database, cfg)
	section := memoryRevisionsSection(t, prompt)

	assert.Equal(t, "(no notable revisions)", section)
}

func TestGatherMemoryRevisions_CapsAtFive(t *testing.T) {
	database, cfg, vaultPath := setupBriefingWithVault(t)
	today := time.Now().UTC().Format("2006-01-02")

	for _, id := range []string{"bel_1", "bel_2", "bel_3", "bel_4", "bel_5", "bel_6"} {
		writeBelief(t, database, vaultPath, id, "Belief "+id, "shaken", 0.4,
			"- "+today+": shake — evidence conflicts\n")
	}

	prompt := runBriefingCapturing(t, database, cfg)
	section := memoryRevisionsSection(t, prompt)

	var lines []string
	for _, l := range strings.Split(section, "\n") {
		if strings.TrimSpace(l) != "" {
			lines = append(lines, l)
		}
	}
	assert.Len(t, lines, 5, "at most 5 revision lines")
}

func TestGatherMemoryRevisions_GateOffRendersPlaceholder(t *testing.T) {
	database, cfg, vaultPath := setupBriefingWithVault(t)
	cfg.Memory.Surfaces.Briefing = false
	today := time.Now().UTC().Format("2006-01-02")

	writeBelief(t, database, vaultPath, "bel_shaken", "Bob prefers async reviews", "shaken", 0.4,
		"- "+today+": shake — evidence conflicts\n")

	prompt := runBriefingCapturing(t, database, cfg)

	assert.Contains(t, prompt, "(no notable revisions)")
	assert.NotContains(t, prompt, "%!s(MISSING)", "arg count must still match with the gate off")
	assert.NotContains(t, prompt, "Bob prefers async reviews")
}

// TestGatherMemoryRevisions_CompareShadowWrittenJournalUnchanged: with
// memory.retrieve.briefing_compare on, gatherMemoryRevisions ALSO runs
// RetrieveRevisions and writes one memory_retrieve_shadow row — but the
// rendered "Memory revisions" journal text is byte-identical to the flag-off
// legacy render (the single most important behavioral guarantee).
func TestGatherMemoryRevisions_CompareShadowWrittenJournalUnchanged(t *testing.T) {
	database, cfg, vaultPath := setupBriefingWithVault(t)
	today := time.Now().UTC().Format("2006-01-02")
	writeBelief(t, database, vaultPath, "bel_shaken", "Bob prefers async reviews", "shaken", 0.4,
		"- 2020-01-01: created — first observed\n- "+today+": shake — evidence now conflicts\n")

	baseline := runBriefingCapturing(t, database, cfg)
	baselineSection := memoryRevisionsSection(t, baseline)

	// RunForDate dedupes on an existing briefings row for (user, date) and
	// returns the cached briefing without regenerating — clear it so the
	// second run actually re-invokes gatherMemoryRevisions instead of
	// short-circuiting with an empty (never-called) capturing generator.
	_, err := database.Exec("DELETE FROM briefings")
	require.NoError(t, err)

	cfg.Memory.Retrieve.BriefingCompare = true
	compared := runBriefingCapturing(t, database, cfg)
	comparedSection := memoryRevisionsSection(t, compared)

	require.Equal(t, baselineSection, comparedSection, "compare mode must not change the rendered journal")

	rows, err := database.ListMemoryRetrieveShadow("briefing", time.Time{})
	require.NoError(t, err)
	require.Len(t, rows, 1, "exactly one briefing shadow row from the compare-mode run")

	var diff memory.RevisionDiff
	require.NoError(t, json.Unmarshal([]byte(rows[0].DiffMetricsJSON), &diff))
	assert.Contains(t, diff.OldIDs, "bel_shaken")
}

// TestGatherMemoryRevisions_CompareGateOffWritesNoShadow: without the flag,
// no memory_retrieve_shadow row is ever written — byte-identical to before
// this task existed.
func TestGatherMemoryRevisions_CompareGateOffWritesNoShadow(t *testing.T) {
	database, cfg, vaultPath := setupBriefingWithVault(t)
	today := time.Now().UTC().Format("2006-01-02")
	writeBelief(t, database, vaultPath, "bel_shaken", "Bob prefers async reviews", "shaken", 0.4,
		"- "+today+": shake — evidence conflicts\n")

	runBriefingCapturing(t, database, cfg)

	rows, err := database.ListMemoryRetrieveShadow("briefing", time.Time{})
	require.NoError(t, err)
	assert.Empty(t, rows)
}

func TestBriefingDailyVersionBumpedToSix(t *testing.T) {
	assert.Equal(t, 6, prompts.DefaultVersions[prompts.BriefingDaily])
}
