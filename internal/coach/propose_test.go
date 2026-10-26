package coach

import (
	"bytes"
	"context"
	"log"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/prompts"
)

// proposeInputs is the shared input of the Validate tests: sessions s1-s3 (s1
// has two lines), a chat, three spec reviews, one review round with two
// comments, and five current texts.
func proposeInputs() Inputs {
	return Inputs{
		Signals: []Signal{
			{Ref: "s1", Kind: KindOwnerLine, WorkbenchID: 1, Text: "only run the package tests"},
			{Ref: "s1", Kind: KindOwnerLine, WorkbenchID: 1, Text: "again: just the package"},
			{Ref: "s2", Kind: KindOwnerLine, WorkbenchID: 1, Text: "run the package tests only"},
			{Ref: "s3", Kind: KindOwnerLine, WorkbenchID: 1, Text: "no full suite please"},
			{Ref: "c7", Kind: KindOwnerLine, Text: "shorter answers"},
			{Ref: "ask:10#ag:1", Kind: KindSpecNoise, WorkbenchID: 1, Text: "coverage numbers missing"},
			{Ref: "ask:11#bs:2", Kind: KindSpecNoise, WorkbenchID: 1, Text: "no coverage target"},
			{Ref: "ask:12#ck:1", Kind: KindSpecNoise, WorkbenchID: 1, Text: "coverage not stated"},
			{Ref: "round:5#c1", Kind: KindCodeReview, WorkbenchID: 1, Text: "do not rename this"},
			{Ref: "round:5#c2", Kind: KindCodeReview, WorkbenchID: 1, Text: "rename again?"},
		},
		Texts: []CurrentText{
			{Destination: DestSession, Text: "Run tests. Run lint.\nKeep commits small.", Budget: 1000},
			{Destination: DestProcedure, WorkbenchID: 1, Budget: 1000},
			{Destination: DestChat, Budget: 1000},
			{Destination: DestPromptAdd, PromptID: prompts.SpecReview, Text: "Do not flag naming choices.", Budget: prompts.MaxAdditionRunes},
			{Destination: DestSettingsAllow, Text: "Bash(ls:*)"},
		},
	}
}

func fixture(t *testing.T, name string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", name))
	require.NoError(t, err)
	return string(b)
}

func titles(ps []db.CoachProposal) []string {
	var out []string
	for _, p := range ps {
		out = append(out, p.Title)
	}
	return out
}

func TestValidate_DropsUnknownRefs(t *testing.T) {
	got, err := Validate(fixture(t, "propose_unknown_refs.json"), proposeInputs())
	require.NoError(t, err)
	require.Len(t, got, 1, "the proposal resting on invented sessions is dropped")
	p := got[0]
	assert.Equal(t, "Run only the touched package's tests", p.Title)
	assert.Equal(t, []db.CoachEvidence{{Kind: "session", Ref: "s1"}, {Kind: "session", Ref: "s2"}, {Kind: "session", Ref: "s3"}}, p.Evidence)
	assert.Equal(t, 3, p.Sources)
	assert.Equal(t, "Run tests. Run lint.\nKeep commits small.", p.BeforeText)
	assert.Equal(t, "Run tests. Run lint.\nKeep commits small.\nRun only the tests of the package you changed.", p.AfterText)
	assert.Equal(t, DestSession, p.Destination)
	assert.NotEmpty(t, p.Fingerprint)
}

func TestValidate_RecountsSources(t *testing.T) {
	// The model claims six occurrences; the refs are one session and one
	// review round.
	got, err := Validate(fixture(t, "propose_recount.json"), proposeInputs())
	require.NoError(t, err)
	assert.Empty(t, got)
}

func TestValidate_FindMustMatchOnce(t *testing.T) {
	got, err := Validate(fixture(t, "propose_find_once.json"), proposeInputs())
	require.NoError(t, err)
	require.Equal(t, []string{"Smaller commits"}, titles(got))
	assert.Equal(t, "Run tests. Run lint.\nKeep commits small and focused.", got[0].AfterText)
}

func TestValidate_OverBudgetDropped(t *testing.T) {
	in := proposeInputs()
	in.Texts[0].Budget = 60
	got, err := Validate(fixture(t, "propose_over_budget.json"), in)
	require.NoError(t, err)
	assert.Empty(t, got)

	in.Texts[0].Budget = 1000
	got, err = Validate(fixture(t, "propose_over_budget.json"), in)
	require.NoError(t, err)
	assert.Len(t, got, 1, "the same edit fits a larger budget")
}

func TestValidate_AdditionWithPercentDropped(t *testing.T) {
	// Percent, braces, part of a line and a built-in-owned prompt are dropped;
	// the clean whole-line addition is kept.
	got, err := Validate(fixture(t, "propose_addition.json"), proposeInputs())
	require.NoError(t, err)
	require.Equal(t, []string{"Skip test-coverage findings"}, titles(got))
	assert.Equal(t, "Do not flag naming choices.\nDo not flag missing test coverage numbers.", got[0].AfterText)
	assert.Equal(t, prompts.SpecReview, got[0].PromptID)
	assert.Equal(t, []db.CoachEvidence{{Kind: "ask", Ref: "ask:10#ag:1"}, {Kind: "ask", Ref: "ask:11#bs:2"},
		{Kind: "ask", Ref: "ask:12#ck:1"}}, got[0].Evidence)
}

func TestValidate_AdditionsOverBudgetDropped(t *testing.T) {
	in := proposeInputs()
	in.Texts[3].Text = strings.Repeat("x", prompts.MaxAdditionRunes-10)
	got, err := Validate(fixture(t, "propose_addition.json"), in)
	require.NoError(t, err)
	assert.Empty(t, got)
}

func TestValidate_BareBashAllowDropped(t *testing.T) {
	// A bare Bash, an unsafe verb, a removal and a workbench id the allow list
	// does not have: only the safe add survives, as a global edit.
	got, err := Validate(fixture(t, "propose_allow.json"), proposeInputs())
	require.NoError(t, err)
	require.Equal(t, []string{"Allow the package tests"}, titles(got))
	assert.Equal(t, "Bash(ls:*)\nBash(go test:*)", got[0].AfterText)
	assert.Zero(t, got[0].WorkbenchID)
}

func TestValidate_DeclinedFingerprintDropped(t *testing.T) {
	in := proposeInputs()
	first, err := Validate(fixture(t, "propose_find_once.json"), in)
	require.NoError(t, err)
	require.Len(t, first, 1)

	in.Declined = []db.CoachProposal{{ID: 4, Fingerprint: first[0].Fingerprint, Destination: DestSession, Status: "declined"}}
	got, err := Validate(fixture(t, "propose_find_once.json"), in)
	require.NoError(t, err)
	assert.Empty(t, got)
}

func TestValidate_WiderFindSameFingerprint(t *testing.T) {
	in := proposeInputs()
	narrow, err := Validate(fixture(t, "propose_find_once.json"), in)
	require.NoError(t, err)
	wide, err := Validate(fixture(t, "propose_wider_find.json"), in)
	require.NoError(t, err)
	require.Len(t, narrow, 1)
	require.Len(t, wide, 1)
	assert.Equal(t, narrow[0].AfterText, wide[0].AfterText)
	assert.Equal(t, narrow[0].Fingerprint, wide[0].Fingerprint, "the same edit with a wider find is the same edit")

	in.Declined = []db.CoachProposal{{ID: 4, Fingerprint: narrow[0].Fingerprint, Destination: DestSession, Status: "declined"}}
	got, err := Validate(fixture(t, "propose_wider_find.json"), in)
	require.NoError(t, err)
	assert.Empty(t, got, "a declined edit does not come back under a wider find")
}

func TestFingerprint_PartsCannotBeConfused(t *testing.T) {
	k := keyOf(DestSession, 0, "")
	// Removing " a b" and turning "a" into "b" normalise to the same words;
	// their fingerprints must still differ.
	cut, ok := fingerprint(k, "keep a b", "keep")
	require.True(t, ok)
	swap, ok := fingerprint(k, "keep a", "keep b")
	require.True(t, ok)
	assert.NotEqual(t, cut, swap)

	// Spacing and case do not change the fingerprint.
	a, _ := fingerprint(k, "Keep it.", "Keep it.\nRun   the TESTS.")
	b, _ := fingerprint(k, "Keep it.", "Keep it.\nrun the tests")
	assert.Equal(t, a, b)

	_, ok = fingerprint(k, "Keep it small.", "Keep  it small")
	assert.False(t, ok, "a spacing or punctuation change is no edit")
}

func TestValidate_KeepsAtMostSlots(t *testing.T) {
	in := proposeInputs()
	in.Open = []db.CoachProposal{{ID: 1, Fingerprint: "other", Destination: DestProcedure, WorkbenchID: 1, Status: "open"}}
	got, err := Validate(fixture(t, "propose_slots.json"), in)
	require.NoError(t, err)
	assert.Equal(t, []string{"One", "Two"}, titles(got), "two free slots, best first")

	in.Open = append(in.Open, db.CoachProposal{ID: 2, Fingerprint: "o2", Destination: DestSession, Status: "open"})
	got, err = Validate(fixture(t, "propose_slots.json"), in)
	require.NoError(t, err)
	assert.Equal(t, []string{"Two"}, titles(got), "a text with an open proposal is not edited twice")
}

func TestValidate_MalformedReply(t *testing.T) {
	_, err := Validate("no json here", proposeInputs())
	require.Error(t, err)
	_, err = Validate(`{"other": []}`, proposeInputs())
	require.Error(t, err)
}

func TestSafeAllowRule(t *testing.T) {
	for rule, want := range map[string]bool{
		"Bash(go test:*)":             true,
		"Bash(cat:*)":                 true,
		"Bash":                        false,
		"Bash(*)":                     false,
		"Bash(:*)":                    false,
		"Bash(rm:*)":                  false,
		"Bash(git push:*)":            false,
		"Bash(sed:*)":                 false,
		"Bash(sed -i:*)":              false,
		"Bash(find:*)":                false,
		"Bash(find . -delete:*)":      false,
		"Bash(find . -exec rm -rf:*)": false,
		"Bash(make:*)":                false,
		"Bash(npm run:*)":             false,
		"Bash(rg:*)":                  false,
		"Bash(rg foo:*)":              false,
		"Bash(go test; rm:*)":         false,
		"Bash(go  test:*)":            false,
		"Read":                        false,
		"Write":                       false,
		"mcp__x__send":                false,
	} {
		assert.Equal(t, want, SafeAllowRule(rule), rule)
	}
}

// countingGen counts calls and returns a fixed reply.
type countingGen struct {
	calls        int
	source, user string
	out          string
}

func (g *countingGen) Generate(ctx context.Context, _, user, _ string) (string, *digest.Usage, string, error) {
	g.calls++
	g.source, _ = digest.SourceFromContext(ctx)
	g.user = user
	return g.out, &digest.Usage{}, "", nil
}

func TestProposer_NoCallWhenFull(t *testing.T) {
	d := openDBs(t)
	gen := &countingGen{out: fixture(t, "propose_slots.json")}
	p := &Proposer{DB: d.DB, Gen: gen, Now: func() time.Time { return sigNow }}

	in := proposeInputs()
	in.Open = []db.CoachProposal{{ID: 1}, {ID: 2}, {ID: 3}}
	n, usage, err := p.Run(context.Background(), in)
	require.NoError(t, err)
	assert.Zero(t, n)
	assert.Nil(t, usage)

	in = proposeInputs()
	in.Signals = in.Signals[:3] // s1 twice and s2: two sources
	n, _, err = p.Run(context.Background(), in)
	require.NoError(t, err)
	assert.Zero(t, n)
	assert.Zero(t, gen.calls, "no model call without a free slot or three sources")
}

func TestProposer_RunWritesValidProposals(t *testing.T) {
	d := openDBs(t)
	gen := &countingGen{out: fixture(t, "propose_slots.json")}
	var logs bytes.Buffer
	p := &Proposer{DB: d.DB, Gen: gen, Now: func() time.Time { return sigNow }, Logger: log.New(&logs, "", 0), Lang: "Russian"}

	n, _, err := p.Run(context.Background(), proposeInputs())
	require.NoError(t, err)
	assert.Equal(t, 3, n)
	assert.Equal(t, 1, gen.calls)
	assert.Equal(t, "coach.propose", gen.source)
	assert.Contains(t, gen.user, "=== DATA ===")
	assert.Contains(t, gen.user, "SLOTS: 3\nLANGUAGE: Russian\n")
	assert.Contains(t, gen.user, "--- text destination=session workbench_id=0 prompt_id= budget=1000 used=40\nRun tests. Run lint.\nKeep commits small.\n--- end\n")
	assert.Contains(t, gen.user, "s1 (owner_line, workbench 1): only run the package tests\n")
	assert.NotContains(t, logs.String(), "package tests", "no owner text in logs")

	open, err := d.ListCoachProposals("open")
	require.NoError(t, err)
	require.Len(t, open, 3)

	// A second run with the same reply: the fingerprints are known, nothing new.
	in := proposeInputs()
	n, _, err = p.Run(context.Background(), in)
	require.NoError(t, err)
	assert.Zero(t, n)
}

func TestProposer_PreviewWritesNothing(t *testing.T) {
	d := openDBs(t)
	gen := &countingGen{out: fixture(t, "propose_slots.json")}
	p := &Proposer{DB: d.DB, Gen: gen, Now: func() time.Time { return sigNow }, Logger: log.New(&bytes.Buffer{}, "", 0)}

	props, _, err := p.Preview(context.Background(), proposeInputs())
	require.NoError(t, err)
	assert.Len(t, props, 3)
	open, err := d.ListCoachProposals()
	require.NoError(t, err)
	assert.Empty(t, open, "a preview stores nothing")
}

func TestChangedLines(t *testing.T) {
	removed, added := ChangedLines("Keep it short.\nUse tests.", "Keep it short.\nUse table tests.\nRun them.")
	assert.Equal(t, []string{"Use tests."}, removed)
	assert.Equal(t, []string{"Use table tests.", "Run them."}, added)

	removed, added = ChangedLines("", "Be brief.")
	assert.Empty(t, removed)
	assert.Equal(t, []string{"Be brief."}, added)

	removed, added = ChangedLines("A\nB\nC", "A\nC")
	assert.Equal(t, []string{"B"}, removed)
	assert.Empty(t, added)

	removed, added = ChangedLines("same", "same")
	assert.Empty(t, removed)
	assert.Empty(t, added)
}
