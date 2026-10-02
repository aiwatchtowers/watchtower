package devpack

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// Spec 2026-10-02 §5: a folder set up before the Workbench rename holds the
// watchtower-project skill (with our shipped-digest sidecar), hooks running
// `project brief --project N` / `project check --project N --stop-hook`, the
// local watchtower-project MCP registration and our exclude block naming
// the old skill directory.

const (
	legacyBin           = "/tmp/acme bin/watchtower"
	legacyStartCommand  = `'/tmp/acme bin/watchtower' project brief --project 7`
	legacyStopCommand   = `'/tmp/acme bin/watchtower' project check --project 7 --stop-hook`
	legacySkillContent  = "---\nname: watchtower-project\ndescription: the old skill\n" + MarkerKey + ": v1\n---\n\nUse project_board.\n"
	legacyOwnerSettings = `{
  "model": "sonnet",
  "permissions": {"allow": ["Bash(make test)", "mcp__watchtower-project__update_target", "mcp__watchtower-project__project_board", "mcp__watchtower-workbench__update_target"]},
  "hooks": {
    "SessionStart": [
      {"hooks": [{"type": "command", "command": "echo owner-start"}]},
      {"hooks": [{"type": "command", "command": "'/tmp/acme bin/watchtower' project brief --project 7", "timeout": 10}]}
    ],
    "Stop": [
      {"matcher": "", "hooks": [{"type": "command", "command": "'/tmp/acme bin/watchtower' project check --project 7 --stop-hook", "timeout": 15}, {"type": "command", "command": "echo owner-stop"}]}
    ],
    "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "echo owner-pre"}]}]
  }
}`
)

func legacySkillDir(folder string) string {
	return filepath.Join(folder, ".claude", "skills", LegacySkillName)
}

// seedLegacyFolder lays out a pre-rename install in folder with the given
// legacy skill content and settings; sidecar says whether the skill carries
// the digest we recorded when we shipped it.
func seedLegacyFolder(t *testing.T, folder string, f *fakeClaude, skill string, sidecar bool, settings string) {
	t.Helper()
	dir := legacySkillDir(folder)
	writeTestFile(t, filepath.Join(dir, "SKILL.md"), skill)
	if sidecar {
		sum := sha256.Sum256([]byte(legacySkillContent))
		if err := writeShippedDigest(dir, hex.EncodeToString(sum[:])); err != nil {
			t.Fatal(err)
		}
	}
	writeTestFile(t, settingsFile(folder), settings)
	if _, err := EnsureGitExclude(folder, []string{legacySkillExcludeLine, ".claude/settings.local.json"}); err != nil {
		t.Fatalf("seeding the exclude block: %v", err)
	}
	f.legacy[folder] = true
}

func legacyOpts(folder string, f *fakeClaude) WorkbenchInstallOptions {
	return WorkbenchInstallOptions{WorkbenchID: 7, Folder: folder, Bin: legacyBin, Run: f.run}
}

// ourCommands lists, per event, every hook command recognised as ours.
func ourCommands(t *testing.T, folder string) map[string][]string {
	t.Helper()
	out := map[string][]string{}
	hooks, _ := decodeSettings(t, folder)["hooks"].(map[string]any)
	for _, spec := range []hookSpec{sessionStartSpec, stopSpec} {
		groups, _ := hooks[spec.event].([]any)
		for _, g := range groups {
			_, hs, _ := groupHooks(g)
			for _, h := range hs {
				if cmd, ok := hookCommand(h); ok && looksLikeOurHook(cmd, spec, 7) {
					out[spec.event] = append(out[spec.event], cmd)
				}
			}
		}
	}
	return out
}

func excludeOf(t *testing.T, folder string) string {
	t.Helper()
	return readTestFile(t, filepath.Join(folder, ".git", "info", "exclude"))
}

func TestInstallWorkbench_MigratesALegacyFolder(t *testing.T) {
	folder := fakeRepo(t)
	f := newFakeClaude()
	seedLegacyFolder(t, folder, f, legacySkillContent, true, legacyOwnerSettings)
	before := decodeSettings(t, folder)

	rep, err := InstallWorkbench(context.Background(), legacyOpts(folder, f))
	if err != nil {
		t.Fatalf("install: %v", err)
	}

	// Skill: the new one installed, the old one (ours, un-edited) removed
	// with its sidecar.
	if rep.Skill.State != StateInstalled || rep.LegacySkill.State != StateRemoved {
		t.Fatalf("skills: new %+v, legacy %+v", rep.Skill, rep.LegacySkill)
	}
	if _, err := os.Lstat(legacySkillDir(folder)); !os.IsNotExist(err) {
		t.Fatalf("the legacy skill directory survived (err=%v)", err)
	}

	// Hooks: replaced in place — exactly one of ours per event, the new
	// command, the owner's hooks and keys as they were.
	want := map[string][]string{
		"SessionStart": {WorkbenchHookCommand(legacyBin, 7)},
		"Stop":         {WorkbenchStopHookCommand(legacyBin, 7)},
	}
	if got := ourCommands(t, folder); !reflect.DeepEqual(got, want) {
		t.Fatalf("our hooks = %q, want %q", got, want)
	}
	if !rep.HookChanged || !rep.LegacyHooksReplaced {
		t.Fatalf("the hooks must be reported replaced: %+v", rep)
	}
	after := decodeSettings(t, folder)
	for _, k := range []string{"model", "permissions"} {
		if !reflect.DeepEqual(after[k], before[k]) {
			t.Fatalf("PROJ-04: the owner's %q changed: %#v → %#v", k, before[k], after[k])
		}
	}
	afterHooks, beforeHooks := after["hooks"].(map[string]any), before["hooks"].(map[string]any)
	if !reflect.DeepEqual(afterHooks["PreToolUse"], beforeHooks["PreToolUse"]) {
		t.Fatalf("PROJ-04: the owner's PreToolUse hooks changed")
	}
	settings := readTestFile(t, settingsFile(folder))
	for _, owner := range []string{"echo owner-start", "echo owner-stop", `"matcher": ""`} {
		if !strings.Contains(settings, owner) {
			t.Fatalf("PROJ-04: %s is gone from:\n%s", owner, settings)
		}
	}
	if strings.Count(settings, `"timeout": 10`) != 1 || strings.Count(settings, `"timeout": 15`) != 1 {
		t.Fatalf("each replaced entry keeps its own fields:\n%s", settings)
	}

	// MCP: the new registration added first, then the old one removed — never
	// a moment without a server if the add fails.
	var mcpCalls []string
	for _, c := range f.calls {
		if c[3] != "get" {
			mcpCalls = append(mcpCalls, strings.Join(c[2:], " "))
		}
	}
	wantCalls := []string{
		"mcp add --scope local watchtower-workbench -- /tmp/acme bin/watchtower mcp --workbench 7",
		"mcp remove --scope local watchtower-project",
	}
	if !reflect.DeepEqual(mcpCalls, wantCalls) {
		t.Fatalf("claude calls = %q, want %q", mcpCalls, wantCalls)
	}
	if !rep.MCPRegistered || !rep.LegacyMCPRemoved || f.legacy[folder] {
		t.Fatalf("mcp: %+v, legacy still registered=%v", rep, f.legacy[folder])
	}

	// Exclude: the new skill's line added, the old one dropped, the
	// settings line kept.
	exclude := excludeOf(t, folder)
	if strings.Contains(exclude, "/.claude/skills/watchtower-project/") ||
		!strings.Contains(exclude, "/.claude/skills/watchtower-workbench/") ||
		strings.Count(exclude, "/.claude/settings.local.json") != 1 {
		t.Fatalf("exclude after the migration:\n%s", exclude)
	}

	if rep.LegacyPermissionRules != 2 {
		t.Fatalf("two allow rules name the old server, got %d", rep.LegacyPermissionRules)
	}

	// A second resync is the ordinary idempotent install.
	rep, err = InstallWorkbench(context.Background(), legacyOpts(folder, f))
	if err != nil || rep.LegacySkill.State != StateMissing || rep.LegacyMCPRemoved || rep.LegacyHooksReplaced || rep.HookChanged {
		t.Fatalf("the second install must find nothing legacy left: %+v err=%v", rep, err)
	}
}

// PROJ-04 (spec 2026-10-02 §5.4): an owner-edited legacy skill is never
// deleted by a resync — it stays byte-identical, is reported drifted, and
// its exclude line keeps it git-invisible.
func TestProj04_ResyncKeepsAnEditedLegacySkill(t *testing.T) {
	folder := fakeRepo(t)
	f := newFakeClaude()
	edited := strings.Replace(legacySkillContent, "Use project_board.", "My own board rules.", 1)
	seedLegacyFolder(t, folder, f, edited, true, legacyOwnerSettings)
	sidecar := readTestFile(t, filepath.Join(legacySkillDir(folder), shippedDigestFile))

	rep, err := InstallWorkbench(context.Background(), legacyOpts(folder, f))
	if err != nil {
		t.Fatalf("install: %v", err)
	}
	if rep.LegacySkill.State != StateDrifted {
		t.Fatalf("an edited legacy skill must be reported drifted, got %+v", rep.LegacySkill)
	}
	if got := readTestFile(t, filepath.Join(legacySkillDir(folder), "SKILL.md")); got != edited {
		t.Fatalf("PROJ-04: the edited legacy skill was changed:\n%s", got)
	}
	if got := readTestFile(t, filepath.Join(legacySkillDir(folder), shippedDigestFile)); got != sidecar {
		t.Fatalf("PROJ-04: the kept skill's sidecar was changed")
	}
	if !strings.Contains(excludeOf(t, folder), "/.claude/skills/watchtower-project/") {
		t.Fatalf("PROJ-04: the kept legacy skill's exclude line must stay:\n%s", excludeOf(t, folder))
	}
	// The rest migrated; the kept copy alone does not make the folder legacy.
	st, err := StatusWorkbench(context.Background(), legacyOpts(folder, f))
	if err != nil || st.Legacy || st.LegacySkill.State != StateDrifted || st.Skill.State != StateUnchanged {
		t.Fatalf("status after the resync: %+v err=%v", st, err)
	}
	// A removal keeps it too.
	if err := RemoveWorkbench(context.Background(), legacyOpts(folder, f)); err != nil {
		t.Fatalf("remove: %v", err)
	}
	if got := readTestFile(t, filepath.Join(legacySkillDir(folder), "SKILL.md")); got != edited {
		t.Fatalf("PROJ-04: the removal changed the edited legacy skill")
	}
}

// The same guarantee for a watchtower-project skill we never shipped (no
// marker): it is the owner's, untouched by a resync and by a removal.
func TestInstallWorkbench_ForeignLegacySkillIsUntouched(t *testing.T) {
	folder := fakeRepo(t)
	f := newFakeClaude()
	foreign := "---\nname: watchtower-project\ndescription: someone else's\n---\n\nNot ours.\n"
	seedLegacyFolder(t, folder, f, foreign, false, legacyOwnerSettings)

	rep, err := InstallWorkbench(context.Background(), legacyOpts(folder, f))
	if err != nil {
		t.Fatalf("install: %v", err)
	}
	if rep.LegacySkill.State != StateForeign {
		t.Fatalf("want foreign, got %+v", rep.LegacySkill)
	}
	if err := RemoveWorkbench(context.Background(), legacyOpts(folder, f)); err != nil {
		t.Fatalf("remove: %v", err)
	}
	if got := readTestFile(t, filepath.Join(legacySkillDir(folder), "SKILL.md")); got != foreign {
		t.Fatalf("a foreign legacy skill was changed:\n%s", got)
	}
	if !strings.Contains(excludeOf(t, folder), "/.claude/skills/watchtower-project/") {
		t.Fatalf("the foreign skill's exclude line must stay")
	}
}

// A marked legacy copy without our sidecar cannot be proven un-edited: kept.
func TestInstallWorkbench_LegacySkillWithoutSidecarIsKept(t *testing.T) {
	folder := fakeRepo(t)
	f := newFakeClaude()
	seedLegacyFolder(t, folder, f, legacySkillContent, false, legacyOwnerSettings)

	rep, err := InstallWorkbench(context.Background(), legacyOpts(folder, f))
	if err != nil {
		t.Fatalf("install: %v", err)
	}
	if rep.LegacySkill.State != StateDrifted || readTestFile(t, filepath.Join(legacySkillDir(folder), "SKILL.md")) != legacySkillContent {
		t.Fatalf("a legacy skill without its sidecar must be kept as drifted: %+v", rep.LegacySkill)
	}
}

// PROJ-04: a malformed settings.local.json on a legacy folder stays
// byte-identical and is reported; the skill and MCP steps still run.
func TestInstallWorkbench_LegacyFolderWithMalformedSettings(t *testing.T) {
	folder := fakeRepo(t)
	f := newFakeClaude()
	const broken = `{"hooks": {"SessionStart": [` + `{"hooks": [{"command": "'/tmp/acme bin/watchtower' project brief --project 7"}]}`
	seedLegacyFolder(t, folder, f, legacySkillContent, true, broken)

	rep, err := InstallWorkbench(context.Background(), legacyOpts(folder, f))
	if !errors.Is(err, ErrMalformedSettings) {
		t.Fatalf("expected ErrMalformedSettings, got %v", err)
	}
	if readTestFile(t, settingsFile(folder)) != broken {
		t.Fatalf("PROJ-04: a malformed settings file was modified")
	}
	if rep.HookChanged || rep.LegacyHooksReplaced {
		t.Fatalf("no hook can be replaced in a malformed file: %+v", rep)
	}
	if !rep.MCPRegistered || !rep.LegacyMCPRemoved || rep.LegacySkill.State != StateRemoved || rep.Skill.State != StateInstalled {
		t.Fatalf("the other steps must still run: %+v", rep)
	}
	if rep.LegacyPermissionRules != 0 {
		t.Fatalf("a malformed file has no countable rules, got %d", rep.LegacyPermissionRules)
	}
}

// PROJ-02 (spec 2026-10-02 §5.5): removing a folder that was never resynced
// takes out the legacy hooks, skill, registration and exclude lines, and
// git status is clean afterwards.
func TestProj02_RemoveLegacyFolderLeavesNothingInstalled(t *testing.T) {
	gitBin, err := exec.LookPath("git")
	if err != nil {
		t.Skip("git not installed")
	}
	folder := t.TempDir()
	git := func(args ...string) string {
		t.Helper()
		c := exec.Command(gitBin, args...)
		c.Dir = folder
		c.Env = append(os.Environ(), "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1")
		out, err := c.CombinedOutput()
		if err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
		return string(out)
	}
	git("init", "-q")
	status := func() string { return git("status", "--porcelain", "--untracked-files=all") }

	f := newFakeClaude()
	const ours = `{"hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "'/tmp/acme bin/watchtower' project brief --project 7", "timeout": 10}]}],` +
		` "Stop": [{"hooks": [{"type": "command", "command": "'/tmp/acme bin/watchtower' project check --project 7 --stop-hook", "timeout": 15}]}]}}`
	seedLegacyFolder(t, folder, f, legacySkillContent, true, ours)
	if s := status(); s != "" {
		t.Fatalf("the legacy install is visible to git:\n%s", s)
	}

	if err := RemoveWorkbench(context.Background(), legacyOpts(folder, f)); err != nil {
		t.Fatalf("remove: %v", err)
	}
	for _, p := range []string{legacySkillDir(folder), settingsFile(folder), filepath.Join(folder, ".claude")} {
		if _, err := os.Lstat(p); !os.IsNotExist(err) {
			t.Fatalf("PROJ-02: %s survived the removal (err=%v)", p, err)
		}
	}
	if f.legacy[folder] || len(f.registered) != 0 {
		t.Fatalf("PROJ-02: an MCP registration survived: legacy=%v current=%v", f.legacy, f.registered)
	}
	if strings.Contains(excludeOf(t, folder), excludeBegin) {
		t.Fatalf("PROJ-02: our exclude block survived the removal:\n%s", excludeOf(t, folder))
	}
	if s := status(); s != "" {
		t.Fatalf("PROJ-02: git status is not clean after removal:\n%s", s)
	}
	st, err := StatusWorkbench(context.Background(), legacyOpts(folder, f))
	if err != nil || st.Legacy || st.Hook || st.StopHook || st.MCP || st.LegacySkill.State != StateMissing {
		t.Fatalf("PROJ-02: something is still installed: %+v err=%v", st, err)
	}
}

// integrate status on a legacy folder: legacy, and a legacy hook still
// counts as installed; after the resync nothing legacy is left.
func TestStatusWorkbench_ReportsALegacyFolderUntilItIsResynced(t *testing.T) {
	folder := fakeRepo(t)
	f := newFakeClaude()
	seedLegacyFolder(t, folder, f, legacySkillContent, true, legacyOwnerSettings)
	o := legacyOpts(folder, f)

	st, err := StatusWorkbench(context.Background(), o)
	if err != nil {
		t.Fatalf("status: %v", err)
	}
	if !st.Legacy || !st.Hook || !st.StopHook || !st.MCP || !st.LegacyMCP || !st.LegacyHooks ||
		st.LegacySkill.State != StateUnchanged || st.Skill.State != StateMissing {
		t.Fatalf("a legacy folder: %+v", st)
	}

	if _, err := InstallWorkbench(context.Background(), o); err != nil {
		t.Fatalf("install: %v", err)
	}
	st, err = StatusWorkbench(context.Background(), o)
	if err != nil || st.Legacy || st.LegacyMCP || st.LegacyHooks || st.LegacySkill.State != StateMissing ||
		!st.Hook || !st.StopHook || !st.MCP || st.Skill.State != StateUnchanged {
		t.Fatalf("after the resync: %+v err=%v", st, err)
	}
}

// Spec 2026-10-02 A6: the allow rules naming the old server are counted,
// never rewritten.
func TestLegacyPermissionRules_CountsWithoutWriting(t *testing.T) {
	folder := fakeRepo(t)
	if n := LegacyPermissionRules(folder); n != 0 {
		t.Fatalf("no settings file: want 0, got %d", n)
	}
	writeTestFile(t, settingsFile(folder), legacyOwnerSettings)
	if n := LegacyPermissionRules(folder); n != 2 {
		t.Fatalf("want 2, got %d", n)
	}
	if readTestFile(t, settingsFile(folder)) != legacyOwnerSettings {
		t.Fatalf("counting the rules changed the file")
	}
	writeTestFile(t, settingsFile(folder), `{"permissions": {"allow": ["mcp__watchtower-project", "mcp__watchtower-projector__x", "mcp__watchtower-project__x"]}}`)
	if n := LegacyPermissionRules(folder); n != 2 {
		t.Fatalf("the bare server rule and a tool rule count, a lookalike does not: got %d", n)
	}
}

// Without the claude CLI the install of a legacy folder names the manual
// removal of the old registration along with the manual registration.
func TestInstallWorkbench_LegacyFolderWithoutClaudeNamesBothCommands(t *testing.T) {
	folder := fakeRepo(t)
	f := newFakeClaude()
	seedLegacyFolder(t, folder, f, legacySkillContent, true, legacyOwnerSettings)
	f.missing = true

	rep, err := InstallWorkbench(context.Background(), legacyOpts(folder, f))
	if !errors.Is(err, ErrClaudeNotFound) {
		t.Fatalf("expected ErrClaudeNotFound, got %v", err)
	}
	if !strings.Contains(err.Error(), "claude mcp remove --scope local watchtower-project") {
		t.Fatalf("the error must name the manual removal: %v", err)
	}
	if !strings.Contains(rep.MCPCommand, "mcp add --scope local watchtower-workbench") || rep.MCPRegistered {
		t.Fatalf("the report must carry the manual registration: %+v", rep)
	}
	if !rep.LegacyHooksReplaced || rep.LegacySkill.State != StateRemoved {
		t.Fatalf("the file steps still migrate without claude: %+v", rep)
	}
}

func TestLooksLikeOurHook_RecognisesBothVocabularies(t *testing.T) {
	for _, c := range []struct {
		cmd          string
		ours, legacy bool
	}{
		{"/x/watchtower workbench brief --workbench 7", true, false},
		{"'/x y/watchtower' project brief --project 7", true, true},
		{"/x/watchtower project brief --project 70", false, false},
		{"/x/watchtower project brief --workbench 7", false, false},
		{"/x/not-watchtower project brief --project 7", false, false},
	} {
		if got := looksLikeOurHook(c.cmd, sessionStartSpec, 7); got != c.ours {
			t.Errorf("looksLikeOurHook(%q) = %v", c.cmd, got)
		}
		if got := looksLikeLegacyHook(c.cmd, sessionStartSpec, 7); got != c.legacy {
			t.Errorf("looksLikeLegacyHook(%q) = %v", c.cmd, got)
		}
	}
	if !looksLikeOurHook("/x/watchtower project check --project 7 --stop-hook", stopSpec, 7) ||
		looksLikeOurHook("/x/watchtower project check --project 7", stopSpec, 7) {
		t.Errorf("the Stop hook needs its --stop-hook flag in either vocabulary")
	}
}

// A failed `mcp add` must not cost a not-yet-migrated folder its working old
// server: the old registration stays, and the failure is reported.
func TestInstallWorkbench_FailedAddKeepsTheLegacyRegistration(t *testing.T) {
	folder := fakeRepo(t)
	f := newFakeClaude()
	seedLegacyFolder(t, folder, f, legacySkillContent, true, legacyOwnerSettings)
	f.failAdd = true

	rep, err := InstallWorkbench(context.Background(), legacyOpts(folder, f))
	if err == nil || !strings.Contains(err.Error(), "claude mcp add") ||
		!strings.Contains(err.Error(), "the old watchtower-project registration was kept") {
		t.Fatalf("the failed add must be reported, naming the kept registration: %v", err)
	}
	if !f.legacy[folder] {
		t.Fatalf("the legacy registration was removed although the new one never came")
	}
	if rep.MCPRegistered || rep.LegacyMCPRemoved || rep.MCPCommand == "" {
		t.Fatalf("report: %+v", rep)
	}
	for _, c := range f.calls {
		if c[3] == "remove" && c[len(c)-1] == LegacyMCPServerName {
			t.Fatalf("no removal of the legacy server may run before the add succeeded: %q", c)
		}
	}
}
