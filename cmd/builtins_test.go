package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"testing"
	"time"

	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/automations"
	"watchtower/internal/automations/automationstest"
	"watchtower/internal/automations/builtin"
	"watchtower/internal/briefing"
	"watchtower/internal/config"
	"watchtower/internal/daemon"
	"watchtower/internal/dayplan"
	"watchtower/internal/db"
	"watchtower/internal/digest"
)

// TestWireBuiltins_SlotExecutorHasMainBackends: the slot executor runs on
// the main executor's backends (the read tools of automationBackends) plus
// the daemon's primitives and the shipped prompts, and the wiring stands on
// its own — no wireAutomations, as when the owner-recipe upgrade step failed
// (automationsOK == false).
func TestWireBuiltins_SlotExecutorHasMainBackends(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	cfg := &config.Config{ActiveWorkspace: "acme",
		Briefing: config.BriefingConfig{Enabled: true}, DayPlan: config.DayPlanConfig{Enabled: true}}
	require.NoError(t, os.MkdirAll(cfg.WorkspaceDir(), 0o755))
	database := db.OpenTestDB(t)
	gen := &automationstest.FakeGenerator{}
	logger := log.New(io.Discard, "", 0)
	d := daemon.New(cfg)
	d.SetLogger(logger)
	d.SetDB(database)
	d.SetBriefingPipeline(briefing.New(database, cfg, gen, logger))
	d.SetDayPlanPipeline(dayplan.New(database, cfg, gen, logger))

	b := slotBackends(d, cfg, database, gen)
	require.NotNil(t, b.Registry)
	_, ok := b.Registry.Get("list_targets")
	assert.True(t, ok, "the slot executor has automationBackends' read tools")
	for _, name := range automations.BuiltinPrimitiveNames {
		assert.NotNil(t, b.Primitives[name], name)
	}
	require.NotNil(t, b.DefaultPrompt)
	_, err := b.DefaultPrompt("morning-brief", "brief", "")
	require.NoError(t, err)

	r := wireBuiltins(d, cfg, database, gen, logger)
	require.NotNil(t, r)
	a, err := database.GetBuiltinAutomation("morning-brief")
	require.NoError(t, err)
	assert.True(t, a.Confirmed(), "the shipped text is confirmed by the sync")

	// The runner executes on the slot executor: a manual run on a no-owner
	// install fails with db.ErrNoOwner (OWNER-02), with no model call.
	run, err := r.RunNow(context.Background(), "morning-brief", automations.BuiltinInput{Only: []string{"brief.compose"}})
	require.NoError(t, err)
	assert.Equal(t, db.RunFailed, run.Status)
	assert.Contains(t, run.Error, db.ErrNoOwner.Error())
	assert.Zero(t, gen.CallCount())
}

// TestWireBuiltins_LogsAnUnusedOwnerCopy: an owner copy that is not a
// regular file is not used, and the daemon's start says so.
func TestWireBuiltins_LogsAnUnusedOwnerCopy(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	cfg := &config.Config{ActiveWorkspace: "acme", Briefing: config.BriefingConfig{Enabled: true}}
	require.NoError(t, os.MkdirAll(builtin.OwnerCopyPath(cfg.WorkspaceDir(), "morning-brief"), 0o755)) // a directory
	database := db.OpenTestDB(t)
	var buf bytes.Buffer
	logger := log.New(&buf, "", 0)
	d := daemon.New(cfg)
	d.SetLogger(logger)
	d.SetDB(database)

	wireBuiltins(d, cfg, database, &automationstest.FakeGenerator{}, logger)
	assert.Contains(t, buf.String(), "built-in morning-brief: the edited copy is not a regular file; using the built-in")
}

// builtinCLI is a temp workspace for the built-in CLI paths: the automations
// CLI fixture's database and config (features as given), an owner, one
// target (data for a brief and a plan) and a FakeGenerator behind the
// built-in runs' generator seam.
type builtinCLI struct {
	d   *db.DB
	cfg *config.Config
	gen *automationstest.FakeGenerator
	ws  string
}

const (
	builtinBriefReply = `{"attention":[],"your_day":[],"what_happened":[],"team_pulse":[],"coaching":[]}`
	builtinPlanReply  = `{"timeblocks":[],"backlog":[{"source_type":"task","source_id":"1","title":"Write tests","description":"d","rationale":"r","priority":"medium"}],"summary":"ok"}`
)

func newBuiltinCLI(t *testing.T, featuresOn bool, replies ...string) *builtinCLI {
	t.Helper()
	d := writeActionsConfig(t)
	on := strconv.FormatBool(featuresOn)
	// schema_format current: executeCLI goes through the root command, whose
	// pre-run would otherwise run the one-time schema upgrade on this database.
	require.NoError(t, os.WriteFile(flagConfig, []byte("active_workspace: test\nbriefing:\n  enabled: "+on+
		"\nday_plan:\n  enabled: "+on+"\ndb:\n  schema_format: "+strconv.Itoa(db.CurrentSchemaFormat)+"\n"), 0o600))
	cfg, err := loadAutomationsConfig()
	require.NoError(t, err)
	require.NoError(t, os.MkdirAll(automations.PersonalDir(cfg.WorkspaceDir()), 0o755))
	require.NoError(t, d.UpsertWorkspace(db.Workspace{ID: "T001", Name: "acme", Domain: "acme"}))
	_, err = d.CreateSlackAccount(db.SlackAccount{CurrentUserID: "U001"})
	require.NoError(t, err)
	_, err = d.CreateTarget(db.Target{Text: "Write tests", Level: "day", PeriodStart: "2026-04-23", PeriodEnd: "2026-04-23",
		Priority: "medium", Status: "todo", Ownership: "mine", SourceType: "manual"})
	require.NoError(t, err)
	gen := &automationstest.FakeGenerator{Replies: replies, Usage: []digest.Usage{{InputTokens: 10, OutputTokens: 5}}}
	useBuiltinGenerator(t, gen)
	return &builtinCLI{d: d, cfg: cfg, gen: gen, ws: cfg.WorkspaceDir()}
}

// row syncs the Morning brief and returns its row.
func (c *builtinCLI) row(t *testing.T) *db.Automation {
	t.Helper()
	a, err := builtin.SyncOne(context.Background(), c.d, c.ws, c.cfg, morningBriefID, time.Now())
	require.NoError(t, err)
	return a
}

// writeCopy writes the owner's copy of the Morning brief with an edited
// brief prompt and returns the synced row (unconfirmed).
func (c *builtinCLI) writeCopy(t *testing.T, brief string) *db.Automation {
	t.Helper()
	e, ok := builtin.Lookup(morningBriefID)
	require.True(t, ok)
	data, err := builtin.RenderOwnerCopy(e, map[string]string{"brief": brief})
	require.NoError(t, err)
	path := builtin.OwnerCopyPath(c.ws, morningBriefID)
	require.NoError(t, os.MkdirAll(filepath.Dir(path), 0o700))
	require.NoError(t, os.WriteFile(path, data, 0o600))
	a := c.row(t)
	require.True(t, a.Overridden)
	return a
}

// executeCLI runs the root command as main does and returns its exit code
// and what it printed on stderr.
func executeCLI(t *testing.T, args ...string) (int, string) {
	t.Helper()
	r, w, err := os.Pipe()
	require.NoError(t, err)
	orig := os.Stderr
	os.Stderr = w
	var out bytes.Buffer
	rootCmd.SetOut(&out)
	// --config explicitly: a parse without it puts the flag's default (the
	// real config path) back into flagConfig.
	cfgPath := flagConfig
	rootCmd.SetArgs(append(args, "--config", cfgPath))
	code := Execute()
	flagConfig = cfgPath
	os.Stderr = orig
	require.NoError(t, w.Close())
	stderr, err := io.ReadAll(r)
	require.NoError(t, err)
	rootCmd.SetArgs(nil)
	rootCmd.SetOut(nil)
	for _, c := range []*cobra.Command{dayPlanGenerateCmd, briefingGenerateCmd} {
		c.LocalFlags().VisitAll(func(f *pflag.Flag) { // never the inherited --config
			_ = f.Value.Set(f.DefValue)
			f.Changed = false
		})
	}
	return code, string(stderr)
}

func TestBriefingGenerate_UsesOwnerCopyPrompt(t *testing.T) {
	c := newBuiltinCLI(t, true, builtinBriefReply)
	e, _ := builtin.Lookup(morningBriefID)
	shipped, err := e.DefaultPrompt("brief", "")
	require.NoError(t, err)
	a := c.writeCopy(t, "OWNER COPY MARKER\n"+shipped)
	require.NoError(t, c.d.ConfirmAutomation(a.ID, a.ApprovalHash, time.Now()))

	code, stderr := executeCLI(t, "briefing", "generate")
	require.Equal(t, 0, code, stderr)
	require.Len(t, c.gen.Calls, 1)
	assert.Contains(t, c.gen.Calls[0].SystemPrompt, "OWNER COPY MARKER", "the prompt is the confirmed copy's")
	b, err := c.d.GetBriefing("U001", time.Now().Format(time.DateOnly))
	require.NoError(t, err)
	require.NotNil(t, b)
	runs := (&autoCLI{d: c.d}).runs(t, a.ID)
	require.Len(t, runs, 1)
	assert.Equal(t, db.TriggerManual, runs[0].Trigger)
	assert.Equal(t, db.RunSucceeded, runs[0].Status)
}

func TestBriefingGenerate_RefusedForUnconfirmedCopy(t *testing.T) {
	c := newBuiltinCLI(t, true, builtinBriefReply)
	c.writeCopy(t, "Edited brief for %s on %s.")
	for _, args := range [][]string{{"briefing", "generate"}, {"day-plan", "generate", "--feedback", "fewer meetings"}} {
		code, stderr := executeCLI(t, args...)
		assert.NotEqual(t, 0, code, args)
		assert.Equal(t, "Morning brief: your edited copy is not confirmed yet — confirm it in Automations → Built in\n", stderr, args)
	}
	assert.Zero(t, c.gen.CallCount())
}

func TestBriefingGenerate_RefusedWhileSlotRuns(t *testing.T) {
	c := newBuiltinCLI(t, true, builtinBriefReply)
	a := c.row(t)
	runID, _, err := c.d.EnqueueAutomationRun(db.EnqueueRequest{AutomationID: a.ID, Trigger: db.TriggerSync, Now: time.Now()})
	require.NoError(t, err)
	ok, err := c.d.ClaimAutomationRun(runID, a.ApprovalHash, a.RecipeText, a.BudgetTokens, a.BudgetMinutes, time.Now())
	require.NoError(t, err)
	require.True(t, ok)
	for _, args := range [][]string{{"briefing", "generate"}, {"day-plan", "generate", "--feedback", "fewer meetings"}} {
		code, stderr := executeCLI(t, args...)
		assert.NotEqual(t, 0, code, args)
		assert.Equal(t, "Morning brief is running now — try again in a minute\n", stderr, args)
	}
	assert.Zero(t, c.gen.CallCount())
}

func TestDayPlanGenerate_FeedbackForcesAndKeepsManualItems(t *testing.T) {
	c := newBuiltinCLI(t, true, builtinPlanReply)
	const date = "2026-04-23"
	code, stderr := executeCLI(t, "day-plan", "generate", "--date", date)
	require.Equal(t, 0, code, stderr)
	plan, err := c.d.GetDayPlan("U001", date)
	require.NoError(t, err)
	require.NotNil(t, plan)
	require.NoError(t, c.d.CreateDayPlanItems(plan.ID, []db.DayPlanItem{{Kind: db.DayPlanItemKindBacklog,
		SourceType: "manual", Title: "Call the plumber", Status: "pending"}}))

	code, stderr = executeCLI(t, "day-plan", "generate", "--date", date, "--feedback", "fewer meetings")
	require.Equal(t, 0, code, stderr)
	require.Equal(t, 2, c.gen.CallCount(), "--feedback regenerates without --force")
	assert.Contains(t, c.gen.Calls[1].SystemPrompt, "fewer meetings")
	again, err := c.d.GetDayPlan("U001", date)
	require.NoError(t, err)
	assert.Equal(t, plan.ID, again.ID)
	assert.Equal(t, 1, again.RegenerateCount)
	items, err := c.d.GetDayPlanItems(again.ID)
	require.NoError(t, err)
	assert.True(t, slices.ContainsFunc(items, func(it db.DayPlanItem) bool { return it.Title == "Call the plumber" }),
		"the manual item is kept")
}

func TestDayPlanGenerate_WorksWithFeatureOff(t *testing.T) {
	c := newBuiltinCLI(t, false, builtinPlanReply)
	code, stderr := executeCLI(t, "day-plan", "generate", "--date", "2026-04-23")
	require.Equal(t, 0, code, stderr)
	plan, err := c.d.GetDayPlan("U001", "2026-04-23")
	require.NoError(t, err)
	require.NotNil(t, plan)
	a, err := c.d.GetBuiltinAutomation(morningBriefID)
	require.NoError(t, err)
	assert.False(t, a.Enabled, "the row keeps mirroring the features' off state")
}

func TestAutomationsRun_BuiltinWithoutRunNowRefused(t *testing.T) {
	c := newBuiltinCLI(t, true)
	a := c.row(t)
	orig := builtinLookup
	builtinLookup = func(id string) (builtin.Entry, bool) {
		e, ok := orig(id)
		e.RunNow, e.NoRunNowNote = false, "Acme runs only at its sync"
		return e, ok
	}
	t.Cleanup(func() { builtinLookup = orig })
	out, err := runAutomations(t, "run", idArg(a.ID))
	require.Error(t, err, out)
	assert.Equal(t, "Acme runs only at its sync", err.Error())
	assert.Empty(t, (&autoCLI{d: c.d}).runs(t, a.ID))
}

// TestAuto09_BuiltinRunNowOnlyQueues: `automations run` of a built-in only
// queues a manual run and asks the daemon for a sync; the CLI executes
// nothing.
func TestAuto09_BuiltinRunNowOnlyQueues(t *testing.T) {
	c := newBuiltinCLI(t, true, builtinBriefReply)
	a := c.row(t)
	signals := 0
	orig := builtinRunSignal
	builtinRunSignal = func(*config.Config) (int, error) { signals++; return 4242, nil }
	t.Cleanup(func() { builtinRunSignal = orig })

	m := runAutomationsJSON(t, "run", idArg(a.ID))
	assert.Equal(t, true, m["at_next_sync"])
	assert.Equal(t, true, m["daemon_running"])
	assert.Equal(t, 1, signals)
	runs := (&autoCLI{d: c.d}).runs(t, a.ID)
	require.Len(t, runs, 1)
	assert.Equal(t, db.RunQueued, runs[0].Status)
	assert.Equal(t, db.TriggerManual, runs[0].Trigger)
	assert.Zero(t, c.gen.CallCount())

	off := newBuiltinCLI(t, false)
	b := off.row(t)
	_, err := runAutomations(t, "run", idArg(b.ID))
	require.Error(t, err)
	assert.Contains(t, err.Error(), "turn it on first")
}

func TestAutomationsReset_RemovesCopyAndConfirmsShipped(t *testing.T) {
	c := newBuiltinCLI(t, true)
	a := c.writeCopy(t, "Edited brief for %s on %s.")
	require.False(t, a.Confirmed())
	m := runAutomationsJSON(t, "reset", idArg(a.ID))
	wantKeys(t, m, "automation_id", "overridden", "approval_hash")
	assert.Equal(t, float64(a.ID), m["automation_id"])
	assert.Equal(t, false, m["overridden"])
	assert.NoFileExists(t, builtin.OwnerCopyPath(c.ws, morningBriefID))
	row, err := c.d.GetBuiltinAutomation(morningBriefID)
	require.NoError(t, err)
	assert.True(t, row.Confirmed(), "the shipped text is confirmed again")
	assert.Equal(t, row.ApprovalHash, m["approval_hash"])

	_, err = runAutomations(t, "reset", idArg((&autoCLI{d: c.d, personal: automations.PersonalDir(c.ws)}).indexRecipe(t, "digest",
		autoCLIRecipeText(`return 1`)).ID))
	require.Error(t, err, "an owner automation is not reset")
}

func TestAutomationsReset_RefusedUnderAgentMarkers(t *testing.T) {
	c := newBuiltinCLI(t, true)
	a := c.writeCopy(t, "Edited brief for %s on %s.")
	for _, marker := range agentEnvMarkers {
		t.Run(marker, func(t *testing.T) {
			t.Setenv(marker, "1")
			_, err := runAutomations(t, "reset", idArg(a.ID))
			require.Error(t, err)
			assert.Contains(t, err.Error(), "under an AI agent")
			assert.FileExists(t, builtin.OwnerCopyPath(c.ws, morningBriefID))
		})
	}
}

func TestAutomationsCLI_BuiltinEnableDisableDeletePointers(t *testing.T) {
	c := newBuiltinCLI(t, true)
	a := c.row(t)
	for _, verb := range []string{"enable", "disable"} {
		_, err := runAutomations(t, verb, idArg(a.ID))
		require.Error(t, err, verb)
		assert.Equal(t, "A built-in turns on and off with its features: watchtower features enable|disable briefing day-plan", err.Error())
	}
	_, err := runAutomations(t, "delete", idArg(a.ID))
	require.Error(t, err)
	assert.Equal(t, "built-ins cannot be deleted; turn it off instead", err.Error())
	row, err := c.d.GetBuiltinAutomation(morningBriefID)
	require.NoError(t, err)
	assert.Equal(t, a.Enabled, row.Enabled)
}

// TestAuto03_BuiltinGetsNoAutoGrant: no auto grant is ever written for a
// built-in, at its current approval hash or otherwise.
func TestAuto03_BuiltinGetsNoAutoGrant(t *testing.T) {
	c := newBuiltinCLI(t, true)
	a := c.row(t)
	for _, state := range []string{"on", "off"} {
		_, err := runAutomations(t, "auto", idArg(a.ID), "create_target", state, "--hash", a.ApprovalHash)
		require.Error(t, err, state)
		assert.Equal(t, "built-ins get no auto grants (AUTO-03)", err.Error())
	}
	grants, err := c.d.ListAutomationToolGrants(a.ID)
	require.NoError(t, err)
	assert.Empty(t, grants)
}

func TestAutomationsSave_BuiltinPathWritesOwnerCopy(t *testing.T) {
	c := newBuiltinCLI(t, true)
	a := c.row(t)
	e, _ := builtin.Lookup(morningBriefID)
	data, err := builtin.RenderOwnerCopy(e, map[string]string{"brief": "Edited brief for %s on %s."})
	require.NoError(t, err)
	file := filepath.Join(t.TempDir(), "draft.md")
	require.NoError(t, os.WriteFile(file, data, 0o600))

	m := runAutomationsJSON(t, "save", "--file", file, "--path", "builtin:morning-brief", "--expect-content-hash", a.ContentHash)
	assert.Equal(t, float64(a.ID), m["automation_id"])
	assert.Equal(t, false, m["confirmed"])
	got, err := os.ReadFile(builtin.OwnerCopyPath(c.ws, morningBriefID))
	require.NoError(t, err)
	assert.Equal(t, data, got)
	fi, err := os.Stat(filepath.Dir(builtin.OwnerCopyPath(c.ws, morningBriefID)))
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o700), fi.Mode().Perm())
	row, err := c.d.GetBuiltinAutomation(morningBriefID)
	require.NoError(t, err)
	assert.True(t, row.Overridden)
	assert.False(t, row.Confirmed())

	// The shipped hash is stale now that a copy exists.
	_, err = runAutomations(t, "save", "--file", file, "--path", "builtin:morning-brief", "--expect-content-hash", a.ContentHash)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "changed on disk")

	// With the copy's hash and --confirm-hash the copy is confirmed.
	m = runAutomationsJSON(t, "save", "--file", file, "--path", "builtin:morning-brief",
		"--expect-content-hash", row.ContentHash, "--confirm-hash", row.ApprovalHash)
	assert.Equal(t, true, m["confirmed"])
	row, err = c.d.GetBuiltinAutomation(morningBriefID)
	require.NoError(t, err)
	assert.True(t, row.Confirmed())
}

func TestAutomationsShow_BuiltinBlockGolden(t *testing.T) {
	c := newBuiltinCLI(t, true)
	a := c.row(t)
	raw, err := os.ReadFile(filepath.Join("..", "internal", "automations", "builtin", "testdata", "show_morning_brief.json"))
	require.NoError(t, err)
	var golden map[string]any
	require.NoError(t, json.Unmarshal(raw, &golden))

	show := runAutomationsJSON(t, "show", idArg(a.ID))
	block, ok := show["builtin"].(map[string]any)
	require.True(t, ok, "show of a built-in has a builtin block: %v", show["builtin"])
	assert.Equal(t, automationJSONKeys(golden), automationJSONKeys(block))
	for _, k := range []string{"costs", "default_prompts"} {
		assert.Equal(t, automationJSONKeys(golden[k].(map[string]any)), automationJSONKeys(block[k].(map[string]any)), k)
	}
	params := block["parameters"].([]any)
	require.Len(t, params, len(golden["parameters"].([]any)))
	assert.Equal(t, automationJSONKeys(golden["parameters"].([]any)[0].(map[string]any)),
		automationJSONKeys(params[0].(map[string]any)))
	assert.Equal(t, "morning-brief", block["id"])
	assert.Equal(t, show, runAutomationsJSON(t, "show", "morning-brief"), "a built-in resolves by its id too")

	list, err := runAutomations(t, "list", "--json")
	require.NoError(t, err)
	var items []map[string]any
	require.NoError(t, json.Unmarshal([]byte(list), &items))
	require.Len(t, items, 1)
	assert.Equal(t, "builtin", items[0]["origin"])
	assert.Equal(t, "morning-brief", items[0]["builtin_id"])
	assert.Equal(t, false, items[0]["overridden"])

	owner := (&autoCLI{d: c.d, personal: automations.PersonalDir(c.ws)}).indexRecipe(t, "digest", autoCLIRecipeText(`return 1`))
	ownerShow := runAutomationsJSON(t, "show", idArg(owner.ID))
	v, present := ownerShow["builtin"]
	assert.True(t, present)
	assert.Nil(t, v, "an owner automation's builtin block is null")
}

// TestAutomationsShow_UnreadableCopyIsCopyError: show reports an owner copy
// it cannot lstat as copy_error instead of failing.
func TestAutomationsShow_UnreadableCopyIsCopyError(t *testing.T) {
	c := newBuiltinCLI(t, true)
	a := c.row(t)
	dir := filepath.Dir(builtin.OwnerCopyPath(c.ws, morningBriefID))
	require.NoError(t, os.MkdirAll(dir, 0o700))
	require.NoError(t, os.Chmod(dir, 0o000))
	t.Cleanup(func() { _ = os.Chmod(dir, 0o700) })
	if _, err := os.Lstat(builtin.OwnerCopyPath(c.ws, morningBriefID)); err == nil || os.IsNotExist(err) {
		t.Skipf("lstat in an unreadable directory gave %v (running as root?)", err)
	}
	show := runAutomationsJSON(t, "show", idArg(a.ID))
	assert.Contains(t, show["builtin"].(map[string]any)["copy_error"], "reading the edited copy")
}
