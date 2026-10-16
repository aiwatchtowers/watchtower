package authoring

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
	"testing"

	"watchtower/internal/automations"
	"watchtower/internal/automations/automationstest"
	"watchtower/internal/db"
	"watchtower/internal/tools"
)

type saveFixture struct {
	d   *db.DB
	ws  string
	reg *tools.Registry
}

// newSaveFixture opens a temp file database and a registry holding only
// save_automation, over a temp workspace.
func newSaveFixture(t *testing.T) *saveFixture {
	t.Helper()
	d, err := db.Open(filepath.Join(t.TempDir(), "watchtower.db"))
	if err != nil {
		t.Fatalf("db.Open: %v", err)
	}
	t.Cleanup(func() { _ = d.Close() })
	f := &saveFixture{d: d, ws: t.TempDir(), reg: tools.New(d)}
	if err := f.reg.Register(NewSaveAutomation(Deps{
		DB: d, WorkspaceDir: f.ws, Enabled: func() bool { return true },
		Clock: automationstest.NewFakeClock(draftNow),
	})); err != nil {
		t.Fatal(err)
	}
	return f
}

// recipePath is slug's personal recipe path as the indexer keys it.
func (f *saveFixture) recipePath(t *testing.T, slug string) string {
	t.Helper()
	dir, err := automations.CanonicalDir(automations.PersonalDir(f.ws))
	if err != nil {
		t.Fatal(err)
	}
	return filepath.Join(dir, slug+".md")
}

// existing writes slug's recipe file by hand, indexes and confirms it.
func (f *saveFixture) existing(t *testing.T, slug, text string) db.Automation {
	t.Helper()
	if err := os.MkdirAll(automations.PersonalDir(f.ws), 0o755); err != nil {
		t.Fatal(err)
	}
	a := f.unconfirmed(t, slug, text)
	if err := f.d.ConfirmAutomation(a.ID, a.ApprovalHash, draftNow); err != nil {
		t.Fatal(err)
	}
	return f.automation(t, slug)
}

// unconfirmed writes slug's recipe file by hand and indexes it without
// confirming it.
func (f *saveFixture) unconfirmed(t *testing.T, slug, text string) db.Automation {
	t.Helper()
	f.writeFile(t, slug, text)
	ix := automations.NewIndexer(f.d, f.ws, automationstest.NewFakeClock(draftNow))
	if _, err := ix.RescanPersonal(context.Background()); err != nil {
		t.Fatal(err)
	}
	return f.automation(t, slug)
}

// insertRunSnapshot records a finished run of automationID that ran text
// under hash — a confirmed-text candidate (automations.ConfirmedRecipe).
func insertRunSnapshot(t *testing.T, d *db.DB, automationID int64, hash, text string) {
	t.Helper()
	if _, err := d.Exec(`INSERT INTO automation_runs (automation_id, trigger, status, recipe_hash, recipe_snapshot)
		VALUES (?, 'manual', 'succeeded', ?, ?)`, automationID, hash, text); err != nil {
		t.Fatal(err)
	}
}

func (f *saveFixture) writeFile(t *testing.T, slug, text string) {
	t.Helper()
	if err := os.MkdirAll(automations.PersonalDir(f.ws), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(automations.PersonalDir(f.ws), slug+".md"), []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
}

func (f *saveFixture) readFile(t *testing.T, slug string) (string, bool) {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(automations.PersonalDir(f.ws), slug+".md"))
	if errors.Is(err, os.ErrNotExist) {
		return "", false
	}
	if err != nil {
		t.Fatal(err)
	}
	return string(b), true
}

func (f *saveFixture) automation(t *testing.T, slug string) db.Automation {
	t.Helper()
	a, err := f.d.GetAutomationBySlug("personal", 0, slug)
	if err != nil {
		t.Fatal(err)
	}
	return *a
}

func (f *saveFixture) proposeErr(args map[string]any) (tools.Receipt, error) {
	raw, err := json.Marshal(args)
	if err != nil {
		return tools.Receipt{}, err
	}
	return f.reg.Propose(context.Background(), "save_automation", raw, tools.Binding{Surface: "main"})
}

// propose records a save of text at slug and returns the row id.
func (f *saveFixture) propose(t *testing.T, slug, text string) int64 {
	t.Helper()
	rc, err := f.proposeErr(map[string]any{"recipe_text": text, "slug": slug, "reason": "the owner asked for it"})
	if err != nil {
		t.Fatalf("propose: %v", err)
	}
	if rc.Status != "pending" {
		t.Fatalf("propose status = %q; want pending", rc.Status)
	}
	return rc.ActionID
}

func (f *saveFixture) pinned(t *testing.T, id int64) savePinned {
	t.Helper()
	row, err := f.d.GetAgentAction(id)
	if err != nil || row == nil {
		t.Fatalf("GetAgentAction(%d): %v", id, err)
	}
	var p savePinned
	if err := json.Unmarshal([]byte(row.ArgsJSON), &p); err != nil {
		t.Fatal(err)
	}
	return p
}

// approveApply approves and applies row id and returns the row after Apply.
func (f *saveFixture) approveApply(t *testing.T, id int64) *db.AgentAction {
	t.Helper()
	ok, err := f.reg.Approve(context.Background(), id, nil)
	if err != nil || !ok {
		t.Fatalf("Approve(%d) = %v, %v", id, ok, err)
	}
	row, err := f.reg.Apply(context.Background(), id)
	if err != nil {
		t.Fatalf("Apply(%d): %v", id, err)
	}
	return row
}

func assertFailedWith(t *testing.T, row *db.AgentAction, msg string) {
	t.Helper()
	if row.Status != "failed" || !strings.Contains(row.Error, msg) {
		t.Fatalf("row = %s %q; want failed with %q", row.Status, row.Error, msg)
	}
}

func parsedHash(t *testing.T, slug, text string) string {
	t.Helper()
	r, err := automations.ParseRecipe(slug, []byte(text), automations.Scope{Kind: automations.ScopePersonal})
	if err != nil {
		t.Fatal(err)
	}
	return automations.ApprovalHash(r)
}

func TestSaveAutomation_AlwaysAskAndPinsHash(t *testing.T) {
	f := newSaveFixture(t)
	if err := f.d.SetToolTrust("save_automation", "main", string(tools.TrustExecute)); err != nil {
		t.Fatal(err)
	}
	text := recipeText([]string{"llm:light", "jira:read@PAY"}, "", `return 1`)
	id := f.propose(t, "foo", text)
	if _, ok := f.readFile(t, "foo"); ok {
		t.Fatal("propose wrote the recipe file")
	}
	if err := f.reg.SetTrust("save_automation", "main", tools.TrustExecute); !errors.Is(err, tools.ErrAlwaysAsk) {
		t.Fatalf("SetTrust execute = %v; want ErrAlwaysAsk", err)
	}
	p := f.pinned(t, id)
	if want := parsedHash(t, "foo", text); p.ApprovalHash != want {
		t.Errorf("approval_hash = %q; want %q", p.ApprovalHash, want)
	}
	if !slices.Equal(p.Widening, []string{"jira:read@PAY", "llm:light"}) {
		t.Errorf("widening = %v; want every permission of a new recipe", p.Widening)
	}
	if p.ExistingContentHash != "" || !p.IsNew || p.PreviousRecipeText != "" {
		t.Errorf("new recipe pinned existing=%q is_new=%v previous=%q; want \"\", true, \"\"", p.ExistingContentHash, p.IsNew, p.PreviousRecipeText)
	}
	if p.Scope != "personal" || p.Path != f.recipePath(t, "foo") || p.Name != "Draft test" || p.TriggerKind != "manual" {
		t.Errorf("pinned scope=%q path=%q name=%q trigger=%q", p.Scope, p.Path, p.Name, p.TriggerKind)
	}
	if !json.Valid(p.TriggerSpec) || len(p.Outputs) != 0 || p.Outputs == nil {
		t.Errorf("trigger_spec=%s outputs=%v; want valid JSON and []", p.TriggerSpec, p.Outputs)
	}
}

func TestSaveAutomation_ApplyWritesIndexesConfirms(t *testing.T) {
	f := newSaveFixture(t)
	text := recipeText([]string{"llm:light"}, "", `return 1`)
	id := f.propose(t, "foo", text)
	row := f.approveApply(t, id)
	if row.Status != "applied" {
		t.Fatalf("Apply = %s %q; want applied", row.Status, row.Error)
	}
	got, ok := f.readFile(t, "foo")
	if !ok || got != text {
		t.Fatalf("file = %q (exists %v); want the recipe text byte for byte", got, ok)
	}
	entries, err := os.ReadDir(automations.PersonalDir(f.ws))
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 {
		t.Errorf("recipe folder holds %d entries; want only foo.md (no temp file left)", len(entries))
	}
	a := f.automation(t, "foo")
	if a.ConfirmedHash == "" || a.ConfirmedHash != a.ApprovalHash || a.ApprovalHash != parsedHash(t, "foo", text) {
		t.Errorf("confirmed=%q approval=%q; want both the parsed hash", a.ConfirmedHash, a.ApprovalHash)
	}
	if a.Enabled || a.Runnable() {
		t.Error("save enabled the automation; it must stay disabled until the owner enables it")
	}
	var res SaveResult
	if err := json.Unmarshal([]byte(row.ResultJSON), &res); err != nil {
		t.Fatal(err)
	}
	if res.AutomationID != a.ID || res.Path != a.Path || res.ApprovalHash != a.ApprovalHash || !res.Confirmed {
		t.Errorf("result = %+v; want the indexed row, confirmed", res)
	}
}

// show --json finds the save by its pinned path and scope, so the pin must
// be the index row's own path.
func TestSaveAutomation_PinnedPathIsTheIndexedPath(t *testing.T) {
	f := newSaveFixture(t)
	text := recipeText([]string{"llm:light"}, "", `return 1`)
	id := f.propose(t, "foo", text)
	f.approveApply(t, id)
	a := f.automation(t, "foo")
	p := f.pinned(t, id)
	if p.Path != a.Path || p.Scope != a.Scope {
		t.Errorf("pinned path=%q scope=%q; indexed path=%q scope=%q", p.Path, p.Scope, a.Path, a.Scope)
	}
	save, err := f.d.LatestAppliedAutomationSave(a.Path, "personal", a.ApprovalHash)
	if err != nil || save == nil {
		t.Fatalf("LatestAppliedAutomationSave = %v, %v; want the applied save", save, err)
	}
}

func TestSaveAutomation_RefusesWhenFileChangedSincePropose(t *testing.T) {
	f := newSaveFixture(t)
	before := f.existing(t, "foo", recipeText([]string{"llm:light"}, "", `return 1`))
	id := f.propose(t, "foo", recipeText([]string{"llm:light"}, "", `return 2`))
	onDisk := recipeText([]string{"llm:light"}, "", `return 3`)
	f.writeFile(t, "foo", onDisk)
	assertFailedWith(t, f.approveApply(t, id), msgRecipeFileChanged)
	if got, _ := f.readFile(t, "foo"); got != onDisk {
		t.Errorf("file = %q; want the on-disk bytes kept", got)
	}
	if a := f.automation(t, "foo"); a.ConfirmedHash != before.ConfirmedHash {
		t.Errorf("confirmed_hash %q → %q; want unchanged", before.ConfirmedHash, a.ConfirmedHash)
	}
}

func TestSaveAutomation_RefusesWhenFileAppearedForNewSlug(t *testing.T) {
	f := newSaveFixture(t)
	id := f.propose(t, "foo", recipeText([]string{"llm:light"}, "", `return 1`))
	byHand := recipeText([]string{"llm:light"}, "", `return 42`)
	f.writeFile(t, "foo", byHand)
	assertFailedWith(t, f.approveApply(t, id), msgRecipeFileChanged)
	if got, _ := f.readFile(t, "foo"); got != byHand {
		t.Errorf("file = %q; want the hand-written file untouched", got)
	}
}

func TestSaveAutomation_RefusesWhenFileVanishedForEdit(t *testing.T) {
	f := newSaveFixture(t)
	f.existing(t, "foo", recipeText([]string{"llm:light"}, "", `return 1`))
	id := f.propose(t, "foo", recipeText([]string{"llm:light"}, "", `return 2`))
	if err := os.Remove(filepath.Join(automations.PersonalDir(f.ws), "foo.md")); err != nil {
		t.Fatal(err)
	}
	assertFailedWith(t, f.approveApply(t, id), msgRecipeFileChanged)
	if _, ok := f.readFile(t, "foo"); ok {
		t.Error("Apply wrote the file after it vanished")
	}
}

func TestSaveAutomation_RefusesHashDrift(t *testing.T) {
	f := newSaveFixture(t)
	id := f.propose(t, "foo", recipeText([]string{"llm:light"}, "", `return 1`))
	if _, err := f.d.Exec(`UPDATE agent_actions SET args_json = json_set(args_json, '$.approval_hash', ?) WHERE id = ?`,
		strings.Repeat("0", 64), id); err != nil {
		t.Fatal(err)
	}
	assertFailedWith(t, f.approveApply(t, id), msgRecipeTextDrifted)
	if _, ok := f.readFile(t, "foo"); ok {
		t.Error("Apply wrote the file under a stale approval hash")
	}
}

// The pinned recipe_text swapped after propose (the pinned hash kept): the
// text no longer hashes to what the owner reviewed — refused, nothing
// written, the confirmed hash untouched.
func TestSaveAutomation_RefusesRecipeTextDrift(t *testing.T) {
	f := newSaveFixture(t)
	before := f.existing(t, "foo", recipeText([]string{"llm:light"}, "", `return 1`))
	id := f.propose(t, "foo", recipeText([]string{"llm:light"}, "", `return 2`))
	swapped := recipeText([]string{"llm:light", "jira:read@*"}, "", `return 3`)
	if _, err := f.d.Exec(`UPDATE agent_actions SET args_json = json_set(args_json, '$.recipe_text', ?) WHERE id = ?`,
		swapped, id); err != nil {
		t.Fatal(err)
	}
	assertFailedWith(t, f.approveApply(t, id), msgRecipeTextDrifted)
	if got, _ := f.readFile(t, "foo"); got != before.RecipeText {
		t.Errorf("file = %q; want it untouched", got)
	}
	if a := f.automation(t, "foo"); a.ConfirmedHash != before.ConfirmedHash {
		t.Errorf("confirmed_hash = %q; want the old %q", a.ConfirmedHash, before.ConfirmedHash)
	}
}

// Anything at the target that is not a regular file — a symlink or a FIFO —
// is refused at propose (no row) and, when swapped in after propose, at
// Execute (nothing written through it, nothing confirmed).
func TestSaveAutomation_RefusesSymlinkOrSpecialFileAtTarget(t *testing.T) {
	text := recipeText([]string{"llm:light"}, "", `return 1`)
	plant := map[string]func(t *testing.T, path string){
		"symlink": func(t *testing.T, path string) {
			outside := filepath.Join(t.TempDir(), "outside.md")
			if err := os.WriteFile(outside, []byte(text), 0o644); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink(outside, path); err != nil {
				t.Fatal(err)
			}
		},
		"fifo": func(t *testing.T, path string) {
			if err := syscall.Mkfifo(path, 0o644); err != nil {
				t.Fatal(err)
			}
		},
	}
	for name, put := range plant {
		t.Run(name+" at propose", func(t *testing.T) {
			f := newSaveFixture(t)
			if err := os.MkdirAll(automations.PersonalDir(f.ws), 0o755); err != nil {
				t.Fatal(err)
			}
			put(t, f.recipePath(t, "foo"))
			_, err := f.proposeErr(map[string]any{"recipe_text": text, "slug": "foo", "reason": "r"})
			var ve *tools.ValidationError
			if !errors.As(err, &ve) {
				t.Fatalf("propose = %v; want a ValidationError", err)
			}
		})
		t.Run(name+" after propose", func(t *testing.T) {
			f := newSaveFixture(t)
			id := f.propose(t, "foo", text)
			if err := os.MkdirAll(automations.PersonalDir(f.ws), 0o755); err != nil {
				t.Fatal(err)
			}
			path := f.recipePath(t, "foo")
			put(t, path)
			assertFailedWith(t, f.approveApply(t, id), msgRecipeFileChanged)
			if info, err := os.Lstat(path); err != nil || info.Mode().IsRegular() {
				t.Errorf("target after Apply: %v, %v; want the planted entry kept", info, err)
			}
			if _, err := f.d.GetAutomationBySlug("personal", 0, "foo"); err == nil {
				t.Error("an automation was indexed")
			}
		})
	}
}

// An assistant save confirms its own text: after a hand edit (no run in
// between), the next save widens from the saved text's permissions, not from
// every permission and not from the text the save replaced (J2).
func TestSaveAutomation_WideningAfterAssistantSaveAndHandEdit(t *testing.T) {
	f := newSaveFixture(t)
	f.existing(t, "foo", recipeText([]string{"llm:light"}, "", `return 1`))
	f.approveApply(t, f.propose(t, "foo", recipeText([]string{"llm:light", "jira:read@PAY"}, "", `return 2`)))
	f.unconfirmed(t, "foo", recipeText([]string{"llm:light", "jira:read@PAY"}, "", `return 3`))
	p := f.pinned(t, f.propose(t, "foo", recipeText([]string{"llm:light", "jira:read@PAY", "jira:read@OPS"}, "", `return 4`)))
	if !slices.Equal(p.Widening, []string{"jira:read@OPS"}) {
		t.Errorf("widening = %v; want [jira:read@OPS] over the saved {llm:light, jira:read@PAY}", p.Widening)
	}
}

func TestSaveAutomation_GrantsNotCarriedOver(t *testing.T) {
	f := newSaveFixture(t)
	before := f.existing(t, "foo", recipeText([]string{"llm:light", "tool:create_target"}, "", `return 1`))
	if err := f.d.SetAutomationToolGrant(before.ID, "create_target", before.ApprovalHash, draftNow); err != nil {
		t.Fatal(err)
	}
	id := f.propose(t, "foo", recipeText([]string{"llm:light", "tool:create_target"}, "", `return 2`))
	if row := f.approveApply(t, id); row.Status != "applied" {
		t.Fatalf("Apply = %s %q", row.Status, row.Error)
	}
	grants, err := f.d.ListAutomationToolGrants(before.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(grants) != 1 || grants[0].Tool != "create_target" || grants[0].GrantHash != before.ApprovalHash {
		t.Fatalf("grants = %+v; want the one old-hash grant", grants)
	}
	if a := f.automation(t, "foo"); a.ApprovalHash == before.ApprovalHash || grants[0].GrantHash == a.ApprovalHash {
		t.Error("the saved script did not change the hash, or the grant follows the new hash")
	}
}

func TestSaveAutomation_PinsPreviousTextAndWideningForEdit(t *testing.T) {
	f := newSaveFixture(t)
	old := recipeText([]string{"llm:light"}, "", `return 1`)
	f.existing(t, "foo", old)
	id := f.propose(t, "foo", recipeText([]string{"llm:light", "jira:read@PAY"}, "", `return 1`))
	p := f.pinned(t, id)
	if p.PreviousRecipeText != old || p.IsNew {
		t.Errorf("previous=%q is_new=%v; want the old file, false", p.PreviousRecipeText, p.IsNew)
	}
	if p.ExistingContentHash != automations.ContentHash([]byte(old)) {
		t.Errorf("existing_content_hash = %q; want the old file's", p.ExistingContentHash)
	}
	if !slices.Equal(p.Widening, []string{"jira:read@PAY"}) {
		t.Errorf("widening = %v; want only the added permission", p.Widening)
	}
}

func TestSaveAutomation_ParseErrorNoRow(t *testing.T) {
	f := newSaveFixture(t)
	_, err := f.proposeErr(map[string]any{"recipe_text": "not a recipe", "slug": "foo", "reason": "r"})
	var ve *tools.ValidationError
	if !errors.As(err, &ve) {
		t.Fatalf("propose = %v; want a ValidationError", err)
	}
	var n int
	if err := f.d.QueryRow(`SELECT COUNT(*) FROM agent_actions`).Scan(&n); err != nil || n != 0 {
		t.Errorf("agent_actions rows = %d (%v); want 0", n, err)
	}
}

func TestSaveAutomation_WorkbenchRefusedInP3(t *testing.T) {
	f := newSaveFixture(t)
	_, err := f.proposeErr(map[string]any{
		"recipe_text": recipeText([]string{"llm:light"}, "", `return 1`), "slug": "foo", "workbench_id": 3, "reason": "r",
	})
	var ve *tools.ValidationError
	if !errors.As(err, &ve) || ve.Msg != msgWorkbenchSaveLater {
		t.Fatalf("propose = %v; want %q", err, msgWorkbenchSaveLater)
	}
}

func TestSaveAutomation_DryRunSummaryClipped(t *testing.T) {
	f := newSaveFixture(t)
	rc, err := f.proposeErr(map[string]any{
		"recipe_text": recipeText([]string{"llm:light"}, "", `return 1`), "slug": "foo", "reason": "r",
		"dry_run_summary": strings.Repeat("x", 3*1024),
	})
	if err != nil {
		t.Fatal(err)
	}
	if got := len(f.pinned(t, rc.ActionID).DryRunSummary); got != 2*1024 {
		t.Errorf("dry_run_summary = %d bytes; want 2048", got)
	}
}

func TestSaveAutomation_FeatureOffRefused(t *testing.T) {
	d, err := db.Open(filepath.Join(t.TempDir(), "watchtower.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = d.Close() })
	reg := tools.New(d)
	if err := reg.Register(NewSaveAutomation(Deps{DB: d, WorkspaceDir: t.TempDir()})); err != nil { // Enabled nil = off
		t.Fatal(err)
	}
	raw, _ := json.Marshal(map[string]any{"recipe_text": recipeText(nil, "", `return 1`), "slug": "foo", "reason": "r"})
	_, err = reg.Propose(context.Background(), "save_automation", raw, tools.Binding{Surface: "main"})
	var ve *tools.ValidationError
	if !errors.As(err, &ve) || ve.Msg != msgFeatureOff {
		t.Fatalf("propose = %v; want %q", err, msgFeatureOff)
	}
}

// An unconfirmed edit's permissions are not a widening base: the card widens
// against what the owner last confirmed.
func TestSaveAutomation_WideningAgainstConfirmedNotUnconfirmedEdit(t *testing.T) {
	f := newSaveFixture(t)
	confirmed := recipeText([]string{"llm:light"}, "", `return 1`)
	a := f.existing(t, "foo", confirmed)
	insertRunSnapshot(t, f.d, a.ID, a.ConfirmedHash, confirmed)
	widened := recipeText([]string{"llm:light", "jira:read@PAY"}, "", `return 1`)
	f.unconfirmed(t, "foo", widened)
	p := f.pinned(t, f.propose(t, "foo", widened))
	if !slices.Equal(p.Widening, []string{"jira:read@PAY"}) {
		t.Errorf("widening = %v; want [jira:read@PAY] over the confirmed {llm:light}", p.Widening)
	}
}

func TestSaveAutomation_WideningNeverConfirmedIsEverything(t *testing.T) {
	f := newSaveFixture(t)
	f.unconfirmed(t, "foo", recipeText([]string{"llm:light"}, "", `return 1`))
	p := f.pinned(t, f.propose(t, "foo", recipeText([]string{"llm:light", "jira:read@PAY"}, "", `return 1`)))
	if !slices.Equal(p.Widening, []string{"jira:read@PAY", "llm:light"}) {
		t.Errorf("widening = %v; want every permission of a never-confirmed recipe", p.Widening)
	}
}

func TestSaveAutomation_WideningUnknownConfirmedTextIsEverything(t *testing.T) {
	f := newSaveFixture(t)
	f.existing(t, "foo", recipeText([]string{"llm:light"}, "", `return 1`))
	widened := recipeText([]string{"llm:light", "jira:read@PAY"}, "", `return 1`)
	f.unconfirmed(t, "foo", widened) // no run snapshot, no applied save: no candidate counts
	p := f.pinned(t, f.propose(t, "foo", widened))
	if !slices.Equal(p.Widening, []string{"jira:read@PAY", "llm:light"}) {
		t.Errorf("widening = %v; want every permission when the confirmed text is unknown", p.Widening)
	}
}
