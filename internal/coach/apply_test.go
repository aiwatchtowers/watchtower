package coach

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/prompts"
)

var applyNow = t0.Add(time.Hour)

func newApplier(t *testing.T, d dbs) *Applier {
	t.Helper()
	return &Applier{DB: d.DB, AgentLog: d.al, Home: t.TempDir(), Now: func() time.Time { return applyNow }}
}

func propose(t *testing.T, d dbs, p db.CoachProposal) int64 {
	t.Helper()
	if p.Fingerprint == "" {
		p.Fingerprint = p.Destination + "|" + p.AfterText
	}
	if p.Kind == "" {
		p.Kind = "add"
	}
	if p.Metric == "" {
		p.Metric = "corrections"
	}
	p.Title, p.Why, p.Sources = "title", "why", 3
	id, err := d.InsertCoachProposal(p, t0)
	require.NoError(t, err)
	require.NotZero(t, id)
	return id
}

func proposal(t *testing.T, d dbs, id int64) db.CoachProposal {
	t.Helper()
	p, err := d.GetCoachProposal(id)
	require.NoError(t, err)
	return p
}

func TestAccept_WritesOwnerTextAndBaseline(t *testing.T) {
	d := openDBs(t)
	wb, ids := d.workbench(t, "a", 1)
	d.session(t, wb, "s", ids, 2, 1.0)
	require.NoError(t, d.SetWorkbenchInstruction(wb, db.InstructionProcedure, "Run the tests."))
	id := propose(t, d, db.CoachProposal{Destination: DestProcedure, WorkbenchID: wb,
		BeforeText: "Run the tests.", AfterText: "Run the tests.\nKeep diffs small."})

	require.NoError(t, newApplier(t, d).Accept(id, ""))

	got, err := d.GetWorkbenchInstructions(wb)
	require.NoError(t, err)
	assert.Equal(t, "Run the tests.\nKeep diffs small.", got.Procedure)
	p := proposal(t, d, id)
	assert.Equal(t, "accepted", p.Status)
	assert.True(t, p.DecidedAt.Equal(applyNow))
	require.NotNil(t, p.Baseline, "2 interrupts over 1 task in the last 14 days")
	assert.InDelta(t, 2.0, *p.Baseline, 1e-9)
	assert.Equal(t, 1, p.BaselineN)

	// Nothing measurable in scope: a NULL baseline, n 0.
	require.NoError(t, d.SetOwnerInstruction(db.InstructionChat, "Be brief."))
	id2 := propose(t, d, db.CoachProposal{Destination: DestChat, Metric: "review_findings",
		BeforeText: "Be brief.", AfterText: "Be brief. Answer in English."})
	require.NoError(t, newApplier(t, d).Accept(id2, ""))
	p2 := proposal(t, d, id2)
	assert.Equal(t, "accepted", p2.Status)
	assert.Nil(t, p2.Baseline)
	assert.Zero(t, p2.BaselineN)

	assert.Error(t, newApplier(t, d).Accept(id, ""), "accepted once only")
}

func TestAccept_StaleTextSupersedes(t *testing.T) {
	d := openDBs(t)
	require.NoError(t, d.SetOwnerInstruction(db.InstructionSession, "Old text."))
	id := propose(t, d, db.CoachProposal{Destination: DestSession, BeforeText: "Old text.", AfterText: "Old text. More."})
	// The owner edits the text before accepting.
	require.NoError(t, d.SetOwnerInstruction(db.InstructionSession, "The owner's own text."))

	err := newApplier(t, d).Accept(id, "")
	require.ErrorIs(t, err, ErrStale)
	assert.NotContains(t, err.Error(), "owner's own", "no owner text in errors")

	got, err := d.GetOwnerInstructions()
	require.NoError(t, err)
	assert.Equal(t, "The owner's own text.", got.Session, "the owner's edit is never overwritten")
	assert.Equal(t, "superseded", proposal(t, d, id).Status)
}

func TestAccept_EditedTextRevalidated(t *testing.T) {
	d := openDBs(t)
	a := newApplier(t, d)

	// Over the budget: refused, nothing written, still open.
	id := propose(t, d, db.CoachProposal{Destination: DestSession, AfterText: "Short."})
	long := ""
	for len(long) < 1100 {
		long += "secret words "
	}
	err := a.Accept(id, long)
	require.ErrorIs(t, err, ErrInvalidEdit)
	assert.NotContains(t, err.Error(), "secret words")
	got, err := d.GetOwnerInstructions()
	require.NoError(t, err)
	assert.Empty(t, got.Session)
	assert.Equal(t, "open", proposal(t, d, id).Status)

	// A valid edit is written and kept as the after-text for rollback.
	require.NoError(t, a.Accept(id, "My own wording."))
	got, err = d.GetOwnerInstructions()
	require.NoError(t, err)
	assert.Equal(t, "My own wording.", got.Session)
	assert.Equal(t, "My own wording.", proposal(t, d, id).AfterText)

	// An edited prompt addition with template syntax is refused.
	pa := propose(t, d, db.CoachProposal{Destination: DestPromptAdd, PromptID: prompts.SpecReview, AfterText: "Skip naming."})
	require.ErrorIs(t, a.Accept(pa, "Skip 100% of naming."), ErrInvalidEdit)
	adds, err := d.ListPromptAdditions(prompts.SpecReview)
	require.NoError(t, err)
	assert.Empty(t, adds)

	// An edited allow list with an unsafe rule is refused; the file is not created.
	sa := propose(t, d, db.CoachProposal{Destination: DestSettingsAllow, AfterText: "Bash(go test:*)"})
	require.ErrorIs(t, a.Accept(sa, "Bash(rm:*)"), ErrInvalidEdit)
	_, err = os.Stat(claudeSettingsPath(a.Home))
	assert.ErrorIs(t, err, os.ErrNotExist)
}

func TestAccept_PromptAdditionDoesNotCustomize(t *testing.T) {
	d := openDBs(t)
	store := prompts.New(d.DB, nil)
	require.NoError(t, store.Seed())
	tmpl, ver, err := store.Get(prompts.SpecReview)
	require.NoError(t, err)

	keep, err := d.AddPromptAddition(prompts.SpecReview, "Keep this.", 0, t0)
	require.NoError(t, err)
	_, err = d.AddPromptAddition(prompts.SpecReview, "Drop this.", 0, t0)
	require.NoError(t, err)
	id := propose(t, d, db.CoachProposal{Destination: DestPromptAdd, PromptID: prompts.SpecReview, Kind: "replace",
		BeforeText: "Keep this.\nDrop this.", AfterText: "Keep this.\nDo not flag naming choices."})
	a := newApplier(t, d)
	require.NoError(t, a.Accept(id, ""))

	row, err := d.GetPrompt(prompts.SpecReview)
	require.NoError(t, err)
	require.NotNil(t, row)
	assert.False(t, row.Customized, "a coach edit never sets customized")
	assert.Equal(t, tmpl, row.Template)
	assert.Equal(t, ver, row.Version)

	adds, err := d.ListPromptAdditions(prompts.SpecReview)
	require.NoError(t, err)
	require.Len(t, adds, 2)
	assert.Equal(t, keep, adds[0].ID, "an untouched row is kept")
	assert.Equal(t, "Do not flag naming choices.", adds[1].Text)
	assert.Equal(t, id, adds[1].ProposalID)

	// Rollback deletes this proposal's row and brings back the one it removed.
	_, err = a.Rollback(id, false)
	require.NoError(t, err)
	adds, err = d.ListPromptAdditions(prompts.SpecReview)
	require.NoError(t, err)
	require.Len(t, adds, 2)
	assert.Equal(t, "Keep this.", adds[0].Text)
	assert.Equal(t, "Drop this.", adds[1].Text)
	assert.Equal(t, "rolled_back", proposal(t, d, id).Status)
}

func TestDecline_Final(t *testing.T) {
	d := openDBs(t)
	a := newApplier(t, d)
	id := propose(t, d, db.CoachProposal{Destination: DestSession, AfterText: "New."})
	require.NoError(t, a.Decline(id))
	assert.Equal(t, "declined", proposal(t, d, id).Status)
	require.ErrorIs(t, a.Decline(id), db.ErrCoachStateChanged)
	require.ErrorIs(t, a.Accept(id, ""), db.ErrCoachStateChanged)
	got, err := d.GetOwnerInstructions()
	require.NoError(t, err)
	assert.Empty(t, got.Session)
}

func TestRollback_RestoresBefore(t *testing.T) {
	d := openDBs(t)
	a := newApplier(t, d)
	require.NoError(t, d.SetOwnerInstruction(db.InstructionProcedure, "Before."))
	id := propose(t, d, db.CoachProposal{Destination: DestProcedure, BeforeText: "Before.", AfterText: "Before. After."})
	_, err := a.Rollback(id, false)
	require.ErrorIs(t, err, db.ErrCoachStateChanged, "only an accepted proposal rolls back")

	require.NoError(t, a.Accept(id, ""))
	diff, err := a.Rollback(id, false)
	require.NoError(t, err)
	assert.Empty(t, diff)
	got, err := d.GetOwnerInstructions()
	require.NoError(t, err)
	assert.Equal(t, "Before.", got.Procedure)
	assert.Equal(t, "rolled_back", proposal(t, d, id).Status)

	// The allow list: the added rule goes, the owner's rules and keys stay.
	path := claudeSettingsPath(a.Home)
	require.NoError(t, os.MkdirAll(filepath.Dir(path), 0o700))
	require.NoError(t, os.WriteFile(path, []byte(`{"model":"x","permissions":{"allow":["Read"],"deny":["Bash(rm:*)"]}}`), 0o644))
	sa := propose(t, d, db.CoachProposal{Destination: DestSettingsAllow, BeforeText: "Read", AfterText: "Read\nBash(go test:*)"})
	require.NoError(t, a.Accept(sa, ""))
	rules, err := readAllowRules(path)
	require.NoError(t, err)
	assert.Equal(t, []string{"Read", "Bash(go test:*)"}, rules)
	_, err = a.Rollback(sa, false)
	require.NoError(t, err)
	raw, err := os.ReadFile(path)
	require.NoError(t, err)
	doc, err := parseSettings(raw)
	require.NoError(t, err)
	assert.Equal(t, []string{"Read"}, doc.allow)
	assert.JSONEq(t, `"x"`, string(doc.top["model"]))
	assert.JSONEq(t, `["Bash(rm:*)"]`, string(doc.perms["deny"]))
	fi, err := os.Stat(path)
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o644), fi.Mode().Perm(), "the file mode is kept")
}

func TestRollback_ChangedSinceNeedsForce(t *testing.T) {
	d := openDBs(t)
	a := newApplier(t, d)
	require.NoError(t, d.SetOwnerInstruction(db.InstructionSession, "One."))
	id := propose(t, d, db.CoachProposal{Destination: DestSession, BeforeText: "One.", AfterText: "One.\nTwo."})
	require.NoError(t, a.Accept(id, ""))
	require.NoError(t, d.SetOwnerInstruction(db.InstructionSession, "One.\nTwo.\nThree."))

	diff, err := a.Rollback(id, false)
	require.ErrorIs(t, err, ErrChangedSince)
	assert.NotContains(t, err.Error(), "Three")
	assert.Equal(t, "--- accepted\n+++ now\n@@ -1,2 +1,3 @@\n One.\n Two.\n+Three.\n", diff)
	got, err := d.GetOwnerInstructions()
	require.NoError(t, err)
	assert.Equal(t, "One.\nTwo.\nThree.", got.Session, "nothing written without force")
	assert.Equal(t, "accepted", proposal(t, d, id).Status)

	_, err = a.Rollback(id, true)
	require.NoError(t, err)
	got, err = d.GetOwnerInstructions()
	require.NoError(t, err)
	assert.Equal(t, "One.", got.Session)
	assert.Equal(t, "rolled_back", proposal(t, d, id).Status)
}

func TestAccept_EmptyBeforeRollsBackToEmpty(t *testing.T) {
	d := openDBs(t)
	wb, _ := d.workbench(t, "a", 0)
	a := newApplier(t, d)
	id := propose(t, d, db.CoachProposal{Destination: DestSession, WorkbenchID: wb, AfterText: "Start with the tests."})
	require.NoError(t, a.Accept(id, ""))
	got, err := d.GetWorkbenchInstructions(wb)
	require.NoError(t, err)
	assert.Equal(t, "Start with the tests.", got.Session)
	_, err = a.Rollback(id, false)
	require.NoError(t, err)
	got, err = d.GetWorkbenchInstructions(wb)
	require.NoError(t, err)
	assert.Empty(t, got.Session)

	// The allow list on a home without settings.json: Accept creates it, and
	// the rollback leaves an empty list.
	sa := propose(t, d, db.CoachProposal{Destination: DestSettingsAllow, AfterText: "Bash(go test:*)"})
	require.NoError(t, a.Accept(sa, ""))
	rules, err := readAllowRules(claudeSettingsPath(a.Home))
	require.NoError(t, err)
	assert.Equal(t, []string{"Bash(go test:*)"}, rules)
	_, err = a.Rollback(sa, false)
	require.NoError(t, err)
	rules, err = readAllowRules(claudeSettingsPath(a.Home))
	require.NoError(t, err)
	assert.Empty(t, rules)
}

func TestAccept_ClaudeMDNotSupportedYet(t *testing.T) {
	d := openDBs(t)
	id := propose(t, d, db.CoachProposal{Destination: DestClaudeMDUser, AfterText: "x"})
	require.ErrorIs(t, newApplier(t, d).Accept(id, ""), errNotSupported)
	assert.Equal(t, "open", proposal(t, d, id).Status)
}

func TestAccept_StatusFailureRestoresBefore(t *testing.T) {
	d := openDBs(t)
	a := newApplier(t, d)
	require.NoError(t, d.SetOwnerInstruction(db.InstructionSession, "Before."))
	id := propose(t, d, db.CoachProposal{Destination: DestSession, BeforeText: "Before.", AfterText: "After."})
	// Another writer closes the proposal between the write and the status CAS.
	p := proposal(t, d, id)
	cur, err := a.readCurrent(p)
	require.NoError(t, err)
	w, err := a.writeDestination(p, cur, "After.", applyNow)
	require.NoError(t, err)
	require.NoError(t, d.DecideCoachProposal(id, "open", "declined", applyNow))
	require.ErrorIs(t, d.MarkCoachAccepted(id, w.result, nil, 0, applyNow), db.ErrCoachStateChanged)
	require.NoError(t, w.undo())
	got, err := d.GetOwnerInstructions()
	require.NoError(t, err)
	assert.Equal(t, "Before.", got.Session)

	// The settings undo puts the exact before bytes back, or removes a file it created.
	path := claudeSettingsPath(a.Home)
	sp := db.CoachProposal{Destination: DestSettingsAllow}
	w, err = a.writeDestination(sp, CurrentText{Destination: DestSettingsAllow}, "Bash(go test:*)", applyNow)
	require.NoError(t, err)
	require.FileExists(t, path)
	require.NoError(t, w.undo())
	assert.NoFileExists(t, path)
}

func TestUnifiedDiff_EmptySides(t *testing.T) {
	assert.Equal(t, "--- accepted\n+++ now\n@@ -1,1 +0,0 @@\n-a\n", unifiedDiff("a", ""))
	assert.Equal(t, "--- accepted\n+++ now\n@@ -1,1 +1,1 @@\n-a\n+b\n", unifiedDiff("a", "b"))
}

func TestAccept_TextChangedBetweenReadAndWriteIsStale(t *testing.T) {
	d := openDBs(t)
	a := newApplier(t, d)
	wb, _ := d.workbench(t, "a", 0)
	for _, scope := range []int64{0, wb} {
		set := func(body string) {
			if scope == 0 {
				require.NoError(t, d.SetOwnerInstruction(db.InstructionSession, body))
			} else {
				require.NoError(t, d.SetWorkbenchInstruction(scope, db.InstructionSession, body))
			}
		}
		set("Before.")
		p := db.CoachProposal{Destination: DestSession, WorkbenchID: scope, BeforeText: "Before.", AfterText: "After."}
		cur, err := a.readCurrent(p)
		require.NoError(t, err)
		set("The owner's edit.") // lands after the stale check
		_, err = a.writeDestination(p, cur, "After.", applyNow)
		require.ErrorIs(t, err, ErrStale)
		got, err := a.readCurrent(p)
		require.NoError(t, err)
		assert.Equal(t, "The owner's edit.", got.Text, "scope %d: the owner's edit is never overwritten", scope)
	}
}

func TestAccept_AfterTextAlreadyLiveFinishesStatus(t *testing.T) {
	d := openDBs(t)
	require.NoError(t, d.SetOwnerInstruction(db.InstructionSession, "Before."))
	id := propose(t, d, db.CoachProposal{Destination: DestSession, BeforeText: "Before.", AfterText: "Before. After."})
	// An earlier Accept wrote the text, then failed to record the status.
	require.NoError(t, d.SetOwnerInstruction(db.InstructionSession, "Before. After."))

	require.NoError(t, newApplier(t, d).Accept(id, ""))
	p := proposal(t, d, id)
	assert.Equal(t, "accepted", p.Status, "not superseded")
	assert.Equal(t, "Before. After.", p.AfterText)
	got, err := d.GetOwnerInstructions()
	require.NoError(t, err)
	assert.Equal(t, "Before. After.", got.Session)
}

func TestRollback_PromptAdditionSurvivesLaterAdditions(t *testing.T) {
	d := openDBs(t)
	a := newApplier(t, d)
	id := propose(t, d, db.CoachProposal{Destination: DestPromptAdd, PromptID: prompts.SpecReview, AfterText: "Skip naming."})
	require.NoError(t, a.Accept(id, ""))
	_, err := d.AddPromptAddition(prompts.SpecReview, "A later line.", 0, applyNow)
	require.NoError(t, err)

	diff, err := a.Rollback(id, false)
	require.NoError(t, err, "the proposal's own row is intact")
	assert.Empty(t, diff)
	adds, err := d.ListPromptAdditions(prompts.SpecReview)
	require.NoError(t, err)
	require.Len(t, adds, 1)
	assert.Equal(t, "A later line.", adds[0].Text)

	// Its own row edited away: a plain rollback refuses.
	id2 := propose(t, d, db.CoachProposal{Destination: DestPromptAdd, PromptID: prompts.SpecReview,
		BeforeText: "A later line.", AfterText: "A later line.\nSkip style."})
	require.NoError(t, a.Accept(id2, ""))
	adds, err = d.ListPromptAdditions(prompts.SpecReview)
	require.NoError(t, err)
	_, err = d.Exec(`UPDATE prompt_additions SET text = 'Skip style, mostly.' WHERE id = ?`, adds[1].ID)
	require.NoError(t, err)
	_, err = a.Rollback(id2, false)
	require.ErrorIs(t, err, ErrChangedSince)
	assert.Equal(t, "accepted", proposal(t, d, id2).Status)
}

func TestRollback_AllowRuleSurvivesLaterRules(t *testing.T) {
	d := openDBs(t)
	a := newApplier(t, d)
	path := claudeSettingsPath(a.Home)
	id := propose(t, d, db.CoachProposal{Destination: DestSettingsAllow, AfterText: "Bash(go test:*)"})
	require.NoError(t, a.Accept(id, ""))
	_, _, err := AppendAllowRules(path, []string{"Bash(ls:*)"}) // Claude Code adds one later
	require.NoError(t, err)

	_, err = a.Rollback(id, false)
	require.NoError(t, err)
	rules, err := readAllowRules(path)
	require.NoError(t, err)
	assert.Equal(t, []string{"Bash(ls:*)"}, rules)

	// The proposal's rule gone already: a plain rollback refuses.
	id2 := propose(t, d, db.CoachProposal{Destination: DestSettingsAllow, BeforeText: "Bash(ls:*)", AfterText: "Bash(ls:*)\nBash(go vet:*)"})
	require.NoError(t, a.Accept(id2, ""))
	_, _, err = removeAllowRules(path, []string{"Bash(go vet:*)"})
	require.NoError(t, err)
	_, err = a.Rollback(id2, false)
	require.ErrorIs(t, err, ErrChangedSince)
}

func TestAccept_AllowRecordsOnlyItsOwnRules(t *testing.T) {
	d := openDBs(t)
	a := newApplier(t, d)
	path := claudeSettingsPath(a.Home)
	require.NoError(t, os.MkdirAll(filepath.Dir(path), 0o700))
	// The file gains a rule after the read and before the append.
	require.NoError(t, os.WriteFile(path, []byte(`{"permissions":{"allow":["Read","Bash(ls:*)"]}}`), 0o600))
	p := db.CoachProposal{Destination: DestSettingsAllow, BeforeText: "Read", AfterText: "Read\nBash(go test:*)"}
	w, err := a.writeDestination(p, CurrentText{Destination: DestSettingsAllow, Text: "Read"}, p.AfterText, applyNow)
	require.NoError(t, err)
	assert.Equal(t, "Read\nBash(go test:*)", w.result)
	rules, err := readAllowRules(path)
	require.NoError(t, err)
	assert.Equal(t, []string{"Read", "Bash(ls:*)", "Bash(go test:*)"}, rules)
}

func TestAccept_AllowListMayOnlyGrow(t *testing.T) {
	require.Error(t, ValidateAfter(CurrentText{Destination: DestSettingsAllow, Text: "Read\nBash(ls:*)"}, "Bash(ls:*)"))

	d := openDBs(t)
	a := newApplier(t, d)
	path := claudeSettingsPath(a.Home)
	require.NoError(t, os.MkdirAll(filepath.Dir(path), 0o700))
	orig := []byte(`{"permissions":{"allow":["Read"]}}`)
	require.NoError(t, os.WriteFile(path, orig, 0o600))
	id := propose(t, d, db.CoachProposal{Destination: DestSettingsAllow, BeforeText: "Read", AfterText: "Read\nBash(go test:*)"})
	require.ErrorIs(t, a.Accept(id, "Bash(go test:*)"), ErrInvalidEdit)
	raw, err := os.ReadFile(path)
	require.NoError(t, err)
	assert.Equal(t, orig, raw)
}
