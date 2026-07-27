package meeting

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/memory"
	"watchtower/internal/prompts"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// capturingGenerator records the system prompt handed to Generate so tests can
// assert on the attendee memory block reaching the model.
type capturingGenerator struct {
	response     string
	systemPrompt string
}

func (g *capturingGenerator) Generate(_ context.Context, system, _, _ string) (string, *digest.Usage, string, error) {
	g.systemPrompt = system
	return g.response, &digest.Usage{}, "", nil
}

// memCtxCfg returns a meeting config whose WorkspaceDir lands under a temp HOME,
// with the memory.surfaces.meeting_prep gate set to the caller's choice.
func memCtxCfg(t *testing.T, gateOn bool) *config.Config {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	c := &config.Config{
		ActiveWorkspace: "default",
		Digest:          config.DigestConfig{Language: "English"},
	}
	c.Memory.Surfaces.MeetingPrep = gateOn
	return c
}

// memVaultPath is <WorkspaceDir>/memory.
func memVaultPath(cfg *config.Config) string {
	return filepath.Join(cfg.WorkspaceDir(), "memory")
}

// initMemVault initializes an empty memory vault at <WorkspaceDir>/memory.
func initMemVault(t *testing.T, cfg *config.Config) string {
	t.Helper()
	require.NoError(t, os.MkdirAll(cfg.WorkspaceDir(), 0o755))
	vp := memVaultPath(cfg)
	_, err := memory.OpenVault(vp)
	require.NoError(t, err)
	return vp
}

// writePersonEntity writes an ACTIVE person entity node with What/Current/Facts
// sections and the given aliases, mirroring it into the SQLite index so Resolve
// can find it.
func writePersonEntity(t *testing.T, d *db.DB, vaultPath, id, title, what, current string, facts, aliases []string) {
	t.Helper()
	var b strings.Builder
	b.WriteString("# " + title + "\n\n## What\n" + what + "\n\n## Current\n" + current + "\n\n## Facts\n")
	for _, f := range facts {
		b.WriteString("- " + f + "\n")
	}
	b.WriteString("\n## Links\n\n## Open loops\n")
	body := b.String()
	n := memory.Node{
		ID: id, Type: "entity", Tier: "long", Status: "active",
		Title: title, Aliases: aliases, Body: body,
	}
	require.NoError(t, os.WriteFile(filepath.Join(vaultPath, "entities", id+".md"), n.Render(), 0o644))
	require.NoError(t, d.UpsertMemoryNode(db.MemoryNodeRow{
		ID: id, Type: "entity", Tier: "long", Status: "active", Title: title,
		Path: "entities/" + id + ".md", ContentHash: "h-" + id, IndexedAt: "2026-07-16T00:00:00Z",
	}, body, aliases))
}

// writeBelief writes a belief node (subject/confidence/status) and mirrors it
// into the index with the subject + confidence index columns populated.
func writeBelief(t *testing.T, d *db.DB, vaultPath, id, title, subject, status string, confidence float64) {
	t.Helper()
	body := "# " + title + "\n\n## Statement\n" + title + "\n"
	n := memory.Node{
		ID: id, Type: "belief", Tier: "long", Status: status,
		Title: title, Subject: subject, Confidence: confidence, Body: body,
	}
	require.NoError(t, os.WriteFile(filepath.Join(vaultPath, "beliefs", id+".md"), n.Render(), 0o644))
	require.NoError(t, d.UpsertMemoryNode(db.MemoryNodeRow{
		ID: id, Type: "belief", Tier: "long", Status: status, Title: title,
		Path: "beliefs/" + id + ".md", ContentHash: "h-" + id, IndexedAt: "2026-07-16T00:00:00Z",
		Subject: subject, Confidence: confidence,
	}, body, nil))
}

// aliceAttendees is a two-attendee event: Alice (Slack U123 + email) and Bob
// (email only).
func aliceAttendees() []attendeeEntry {
	return []attendeeEntry{
		{Email: "alice@example.com", DisplayName: "Alice", SlackUserID: "U123"},
		{Email: "bob@example.com", DisplayName: "Bob"},
	}
}

func memGitHeadCount(t *testing.T, vaultPath string) string {
	t.Helper()
	out, err := exec.Command("git", "-C", vaultPath, "rev-list", "--count", "HEAD").Output()
	require.NoError(t, err)
	return strings.TrimSpace(string(out))
}

func TestGatherMemoryContext_GateOffReturnsSentinel(t *testing.T) {
	cfg := memCtxCfg(t, false)
	vp := initMemVault(t, cfg)
	d := openTestDB(t)
	writePersonEntity(t, d, vp, "ent_alice", "Alice", "Backend lead", "Owns the migration", []string{"prefers async"}, []string{"U123", "alice@example.com"})

	p := New(d, cfg, &mockGenerator{}, nil)
	assert.Equal(t, "(no memory context)", p.gatherMemoryContext(aliceAttendees()))
}

func TestGatherMemoryContext_GateOnRendersPageAndBelief(t *testing.T) {
	cfg := memCtxCfg(t, true)
	vp := initMemVault(t, cfg)
	d := openTestDB(t)
	writePersonEntity(t, d, vp, "ent_alice", "Alice", "Backend lead", "Owns the migration", []string{"prefers async comms", "based in Berlin"}, []string{"U123", "alice@example.com"})
	writeBelief(t, d, vp, "bel_a1", "Alice dislikes long meetings", "ent_alice", "active", 0.6)

	p := New(d, cfg, &mockGenerator{}, nil)
	got := p.gatherMemoryContext(aliceAttendees())

	assert.NotEqual(t, "(no memory context)", got)
	assert.Contains(t, got, "Backend lead")
	assert.Contains(t, got, "Owns the migration")
	assert.Contains(t, got, "prefers async comms")
	assert.Contains(t, got, "Alice dislikes long meetings")
	assert.Contains(t, got, "0.6")
	// Bob has no entity → a clean absence line, never an error.
	assert.Contains(t, got, "Bob")
}

func TestGatherMemoryContext_AttendeeNoEntityAbsenceLine(t *testing.T) {
	cfg := memCtxCfg(t, true)
	initMemVault(t, cfg)
	d := openTestDB(t)

	p := New(d, cfg, &mockGenerator{}, nil)
	got := p.gatherMemoryContext(aliceAttendees())

	// No entities at all: both attendees get absence lines, no error, not the
	// whole-block sentinel.
	assert.Contains(t, got, "Alice")
	assert.Contains(t, got, "Bob")
	assert.NotContains(t, got, "%!")
}

func TestGatherMemoryContext_ShakenBeliefShownAsShaken(t *testing.T) {
	cfg := memCtxCfg(t, true)
	vp := initMemVault(t, cfg)
	d := openTestDB(t)
	writePersonEntity(t, d, vp, "ent_alice", "Alice", "Backend lead", "Owns the migration", nil, []string{"U123"})
	writeBelief(t, d, vp, "bel_shk", "Alice wants to move teams", "ent_alice", "shaken", 0.4)

	p := New(d, cfg, &mockGenerator{}, nil)
	got := p.gatherMemoryContext(aliceAttendees())

	assert.Contains(t, got, "Alice wants to move teams")
	assert.Contains(t, got, "shaken")
}

func TestGatherMemoryContext_EmailFallback(t *testing.T) {
	cfg := memCtxCfg(t, true)
	vp := initMemVault(t, cfg)
	d := openTestDB(t)
	// Entity aliased ONLY by lower-cased email; attendee carries no Slack id.
	writePersonEntity(t, d, vp, "ent_carol", "Carol", "Design lead", "Owns the rebrand", nil, []string{"carol@example.com"})

	p := New(d, cfg, &mockGenerator{}, nil)
	got := p.gatherMemoryContext([]attendeeEntry{{Email: "Carol@Example.com", DisplayName: "Carol"}})

	assert.Contains(t, got, "Design lead")
	assert.Contains(t, got, "Owns the rebrand")
}

func TestGatherMemoryContext_VaultAbsentReturnsSentinel(t *testing.T) {
	cfg := memCtxCfg(t, true) // gate on, but no vault initialized
	d := openTestDB(t)

	p := New(d, cfg, &mockGenerator{}, nil)
	assert.Equal(t, "(no memory context)", p.gatherMemoryContext(aliceAttendees()))

	_, err := os.Stat(memVaultPath(cfg))
	assert.True(t, os.IsNotExist(err), "gather must never create a vault")
}

func TestGatherMemoryContext_Capped(t *testing.T) {
	cfg := memCtxCfg(t, true)
	vp := initMemVault(t, cfg)
	d := openTestDB(t)
	facts := make([]string, 0, 400)
	for i := 0; i < 400; i++ {
		facts = append(facts, "a very long fact line about the attendee that keeps going and going")
	}
	writePersonEntity(t, d, vp, "ent_alice", "Alice", "Backend lead", "Owns the migration", facts, []string{"U123"})

	p := New(d, cfg, &mockGenerator{}, nil)
	got := p.gatherMemoryContext(aliceAttendees())

	assert.LessOrEqual(t, len(got), 4096, "attendee memory block must be capped at ~4 KB")
}

func TestPrepareForEvent_GateOnCarriesMemoryBlock(t *testing.T) {
	cfg := memCtxCfg(t, true)
	vp := initMemVault(t, cfg)
	d := openTestDB(t)
	seedTestEvent(t, d)
	writePersonEntity(t, d, vp, "ent_alice", "Alice", "Backend lead", "Owns the migration", []string{"prefers async comms"}, []string{"U123", "alice@example.com"})
	writeBelief(t, d, vp, "bel_a1", "Alice dislikes long meetings", "ent_alice", "active", 0.6)

	gen := &capturingGenerator{response: `{"event_id":"evt1"}`}
	p := New(d, cfg, gen, nil)

	_, err := p.PrepareForEvent(context.Background(), "evt1", "")
	require.NoError(t, err)

	// "Backend lead" and the belief only reach the prompt via the memory block.
	// (The sentinel string itself appears in the template's rule instruction
	// regardless of the gate, so it is not a discriminating check here.)
	assert.Contains(t, gen.systemPrompt, "Backend lead")
	assert.Contains(t, gen.systemPrompt, "Alice dislikes long meetings")
	assert.NotContains(t, gen.systemPrompt, "%!")
}

func TestPrepareForEvent_GateOffPromptHasSentinel(t *testing.T) {
	cfg := memCtxCfg(t, false)
	vp := initMemVault(t, cfg)
	d := openTestDB(t)
	seedTestEvent(t, d)
	writePersonEntity(t, d, vp, "ent_alice", "Alice", "Backend lead", "Owns the migration", []string{"prefers async comms"}, []string{"U123", "alice@example.com"})
	writeBelief(t, d, vp, "bel_a1", "Alice dislikes long meetings", "ent_alice", "active", 0.6)

	gen := &capturingGenerator{response: `{"event_id":"evt1"}`}
	p := New(d, cfg, gen, nil)

	_, err := p.PrepareForEvent(context.Background(), "evt1", "")
	require.NoError(t, err)

	// Gate off: no attendee page or belief content reaches the prompt; the
	// ATTENDEE MEMORY section renders only the sentinel.
	assert.Contains(t, gen.systemPrompt, "(no memory context)")
	assert.NotContains(t, gen.systemPrompt, "Backend lead")
	assert.NotContains(t, gen.systemPrompt, "Alice dislikes long meetings")
	assert.NotContains(t, gen.systemPrompt, "%!")
}

func TestPrepareForEvent_LeavesVaultGitLogUnchanged(t *testing.T) {
	cfg := memCtxCfg(t, true)
	vp := initMemVault(t, cfg)
	d := openTestDB(t)
	seedTestEvent(t, d)
	writePersonEntity(t, d, vp, "ent_alice", "Alice", "Backend lead", "Owns the migration", []string{"prefers async comms"}, []string{"U123", "alice@example.com"})

	before := memGitHeadCount(t, vp)
	gen := &capturingGenerator{response: `{"event_id":"evt1"}`}
	p := New(d, cfg, gen, nil)
	_, err := p.PrepareForEvent(context.Background(), "evt1", "")
	require.NoError(t, err)
	after := memGitHeadCount(t, vp)

	assert.Equal(t, before, after, "a prep run must not write the vault")
}

// TestGatherMemoryContext_CompareShadowWrittenContextUnchanged: with
// memory.retrieve.meeting_prep_compare on, gatherMemoryContext ALSO runs
// RetrieveBySubject per attendee and writes a memory_retrieve_shadow row —
// but the rendered ATTENDEE MEMORY block is byte-identical to the flag-off
// legacy render (the single most important behavioral guarantee).
func TestGatherMemoryContext_CompareShadowWrittenContextUnchanged(t *testing.T) {
	cfg := memCtxCfg(t, true)
	vp := initMemVault(t, cfg)
	d := openTestDB(t)
	writePersonEntity(t, d, vp, "ent_alice", "Alice", "Backend lead", "Owns the migration", []string{"prefers async comms"}, []string{"U123", "alice@example.com"})
	writeBelief(t, d, vp, "bel_a1", "Alice dislikes long meetings", "ent_alice", "active", 0.6)

	p := New(d, cfg, &mockGenerator{}, nil)
	baseline := p.gatherMemoryContext(aliceAttendees())

	cfg.Memory.Retrieve.MeetingPrepCompare = true
	compared := p.gatherMemoryContext(aliceAttendees())

	require.Equal(t, baseline, compared, "compare mode must not change the rendered attendee memory block")

	rows, err := d.ListMemoryRetrieveShadow("meeting_prep", time.Time{})
	require.NoError(t, err)
	require.Len(t, rows, 1, "one shadow row for the one attendee with a resolved entity (Bob has none)")

	var diff memory.SubjectDiff
	require.NoError(t, json.Unmarshal([]byte(rows[0].DiffMetricsJSON), &diff))
	assert.Equal(t, "ent_alice", diff.Subject)
	assert.Contains(t, diff.OldBeliefIDs, "bel_a1")
}

// TestGatherMemoryContext_CompareGateOffWritesNoShadow: without the flag, no
// memory_retrieve_shadow row is ever written.
func TestGatherMemoryContext_CompareGateOffWritesNoShadow(t *testing.T) {
	cfg := memCtxCfg(t, true) // meeting_prep surface on, retrieve-compare off
	vp := initMemVault(t, cfg)
	d := openTestDB(t)
	writePersonEntity(t, d, vp, "ent_alice", "Alice", "Backend lead", "Owns the migration", nil, []string{"U123"})

	p := New(d, cfg, &mockGenerator{}, nil)
	p.gatherMemoryContext(aliceAttendees())

	rows, err := d.ListMemoryRetrieveShadow("meeting_prep", time.Time{})
	require.NoError(t, err)
	assert.Empty(t, rows)
}

func TestMeetingPrepVersionBumpedToFour(t *testing.T) {
	assert.Equal(t, 4, prompts.DefaultVersions[prompts.MeetingPrep])
}
