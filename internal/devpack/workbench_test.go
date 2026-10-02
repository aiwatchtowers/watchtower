package devpack

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

func TestProjectSkillShipsWithMarkerAndName(t *testing.T) {
	name, body := WorkbenchSkill()
	if name != "watchtower-workbench" {
		t.Fatalf("expected the skill to be named watchtower-workbench, got %q", name)
	}
	content := string(body)
	if !HasMarker(content) {
		t.Fatalf("the project skill must carry %s in its frontmatter (DEV-04)", MarkerKey)
	}
	if !strings.Contains(content, "\nname: watchtower-workbench\n") {
		t.Fatalf("frontmatter name must match the directory name")
	}
	if !strings.Contains(content, "\ndescription: ") {
		t.Fatalf("frontmatter must carry a description")
	}
	s := workbenchSkill()
	if s.Name != name || s.Content != content || len(s.SHA256) != 64 {
		t.Fatalf("projectSkill() must wrap ProjectSkill() with a hex sha256, got %+v", s)
	}
}

// The generic pack is what plain `integrate claude-code` installs into
// ~/.claude/skills. The project skill only makes sense inside a bound
// folder, so it must never leak into it.
func TestProjectSkillIsNotInTheGenericPack(t *testing.T) {
	for _, s := range Skills() {
		if s.Name == WorkbenchSkillName {
			t.Fatalf("%s must be embedded separately from the generic pack", WorkbenchSkillName)
		}
	}
}

func TestProjectSkillTeachesEveryProjectTool(t *testing.T) {
	_, body := WorkbenchSkill()
	content := string(body)
	for _, tool := range []string{
		"workbench_info", "workbench_board", "update_workbench",
		"add_workbench_source", "remove_workbench_source",
		"create_targets", "update_target", "attach_document",
		"list_comments", "add_comment", "resolve_comment",
	} {
		if !strings.Contains(content, "`"+tool+"`") {
			t.Fatalf("the skill never names the %s tool", tool)
		}
	}
}

// Spec §5: every flow the skill must teach, pinned by a phrase from it.
func TestProjectSkillTeachesEveryFlow(t *testing.T) {
	_, body := WorkbenchSkill()
	content := string(body)
	for _, phrase := range []string{
		"## Setup",
		"empty description",                // setup trigger #2
		"Set up this Watchtower workbench", // setup trigger #1: the first-run prompt
		"Only after the owner agrees",      // first board created only on agreement
		"## Features, specs and plans",
		"one sub-target per plan task",
		"plan path plus the task number",
		"## Documents for review",
		"Every spec, plan and design you write",
		"Pick the review target",
		"then `update_target` that target to `blocked`",
		"It never means waiting for the owner",
		"not in a chat artifact",
		"When the owner says it is approved",
		"## Revising an attached document",
		"Before editing",
		"`attach_document` again",
		"## Running a plan",
		"verbatim into the implementer's brief",
		"After the task's review passes",
		"## Blocked, or an owner decision is needed",
		"continue with other work",
		"## Comment discipline",
		"no longer exists",
	} {
		if !strings.Contains(content, phrase) {
			t.Fatalf("the skill is missing %q", phrase)
		}
	}
}

// fakeClaude stands in for the claude CLI: it keeps the local-scope
// registrations per cwd and server name and records every call. It never
// execs anything.
type fakeClaude struct {
	mu         sync.Mutex
	registered map[string][]string // cwd → the `mcp add` args of the current server
	legacy     map[string]bool     // cwd → the pre-rename server is registered
	calls      [][]string          // cwd, name, args...
	missing    bool                // behave as if claude is not installed
}

func newFakeClaude() *fakeClaude {
	return &fakeClaude{registered: map[string][]string{}, legacy: map[string]bool{}}
}

func (f *fakeClaude) run(_ context.Context, dir, name string, args ...string) ([]byte, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = append(f.calls, append([]string{dir, name}, args...))
	if f.missing {
		return nil, fmt.Errorf("exec: %q: %w", name, exec.ErrNotFound)
	}
	if name != "claude" || len(args) < 3 || args[0] != "mcp" {
		return nil, fmt.Errorf("unexpected command %s %v", name, args)
	}
	server := args[len(args)-1] // get NAME, remove --scope local NAME
	if args[1] == "add" {
		server = args[4] // add --scope local NAME -- ...
	}
	var isRegistered bool
	switch server {
	case WorkbenchMCPServerName:
		_, isRegistered = f.registered[dir]
	case LegacyMCPServerName:
		isRegistered = f.legacy[dir]
	default:
		return nil, fmt.Errorf("unexpected server %q in %v", server, args)
	}
	switch args[1] {
	case "get":
		if isRegistered {
			return []byte(server + ":\n  Scope: Local config"), nil
		}
		return []byte("No MCP server found with name: " + server), ErrCommandExit
	case "add":
		if isRegistered {
			return []byte("MCP server " + server + " already exists in local config"), ErrCommandExit
		}
		f.registered[dir] = args
		return nil, nil
	case "remove":
		if !isRegistered {
			return []byte("No local-scoped MCP server found"), ErrCommandExit
		}
		if server == LegacyMCPServerName {
			delete(f.legacy, dir)
		} else {
			delete(f.registered, dir)
		}
		return nil, nil
	}
	return nil, ErrCommandExit
}

func workbenchOpts(folder string, f *fakeClaude) WorkbenchInstallOptions {
	return WorkbenchInstallOptions{WorkbenchID: 7, Folder: folder, Bin: "/tmp/acme bin/watchtower", Run: f.run}
}

func workbenchSkillFile(folder string) string {
	return filepath.Join(folder, ".claude", "skills", WorkbenchSkillName, "SKILL.md")
}

func TestProjectHookCommandQuotesPathsWithSpaces(t *testing.T) {
	if got := WorkbenchHookCommand("/tmp/acme/bin/watchtower", 3); got != "/tmp/acme/bin/watchtower workbench brief --workbench 3" {
		t.Fatalf("a plain path must stay unquoted, got %q", got)
	}
	got := WorkbenchHookCommand("/tmp/Application Support/it's/watchtower", 3)
	want := `'/tmp/Application Support/it'\''s/watchtower' workbench brief --workbench 3`
	if got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
}

func TestInstallProjectInstallsSkillHookExcludeAndMCP(t *testing.T) {
	folder := fakeRepo(t)
	f := newFakeClaude()
	o := workbenchOpts(folder, f)

	rep, err := InstallWorkbench(context.Background(), o)
	if err != nil {
		t.Fatalf("install: %v", err)
	}
	if rep.Skill.State != StateInstalled || rep.Skill.Path != workbenchSkillFile(folder) {
		t.Fatalf("skill: %+v", rep.Skill)
	}
	_, body := WorkbenchSkill()
	if readTestFile(t, workbenchSkillFile(folder)) != string(body) {
		t.Fatalf("the installed skill differs from the embedded one")
	}
	if !rep.HookChanged {
		t.Fatalf("the hook must be reported as added")
	}
	if ok, err := HasSessionStartHook(folder, 7); err != nil || !ok {
		t.Fatalf("hook not installed: ok=%v err=%v", ok, err)
	}
	if len(rep.Excluded) != 2 {
		t.Fatalf("expected both exclude lines added, got %v", rep.Excluded)
	}
	want := []string{"mcp", "add", "--scope", "local", "watchtower-workbench", "--", "/tmp/acme bin/watchtower", "mcp", "--workbench", "7"}
	if got := f.registered[folder]; strings.Join(got, "\x00") != strings.Join(want, "\x00") {
		t.Fatalf("mcp add args = %q, want %q", got, want)
	}
	if !rep.MCPRegistered {
		t.Fatalf("MCP must be reported registered")
	}
	for _, c := range f.calls {
		if c[0] != folder {
			t.Fatalf("every claude call must run with cwd = the project folder, got %q", c[0])
		}
	}
	if !strings.Contains(rep.MCPCommand, "claude mcp add --scope local watchtower-workbench -- '/tmp/acme bin/watchtower' mcp --workbench 7") {
		t.Fatalf("printable MCP command: %q", rep.MCPCommand)
	}
}

func TestInstallProjectTwiceIsIdempotent(t *testing.T) {
	folder := fakeRepo(t)
	f := newFakeClaude()
	o := workbenchOpts(folder, f)
	if _, err := InstallWorkbench(context.Background(), o); err != nil {
		t.Fatalf("first install: %v", err)
	}
	settingsBefore := readTestFile(t, settingsFile(folder))
	excludeBefore := readTestFile(t, filepath.Join(folder, ".git", "info", "exclude"))

	rep, err := InstallWorkbench(context.Background(), o)
	if err != nil {
		t.Fatalf("second install: %v", err)
	}
	if rep.Skill.State != StateUnchanged || rep.HookChanged || len(rep.Excluded) != 0 || !rep.MCPRegistered {
		t.Fatalf("second install must change nothing but re-register the MCP: %+v", rep)
	}
	if readTestFile(t, settingsFile(folder)) != settingsBefore {
		t.Fatalf("the second install rewrote settings.local.json")
	}
	if readTestFile(t, filepath.Join(folder, ".git", "info", "exclude")) != excludeBefore {
		t.Fatalf("the second install rewrote the exclude file")
	}
	if len(f.registered) != 1 {
		t.Fatalf("expected one registration, got %v", f.registered)
	}
}

func TestInstallProjectWithoutClaudeStillInstallsTheFilesAndReportsTheCommand(t *testing.T) {
	folder := fakeRepo(t)
	f := newFakeClaude()
	f.missing = true

	rep, err := InstallWorkbench(context.Background(), workbenchOpts(folder, f))
	if !errors.Is(err, ErrClaudeNotFound) {
		t.Fatalf("expected ErrClaudeNotFound, got %v", err)
	}
	if rep.MCPRegistered || rep.MCPCommand == "" {
		t.Fatalf("the report must carry the command to run by hand: %+v", rep)
	}
	if rep.Skill.State != StateInstalled || !rep.HookChanged {
		t.Fatalf("skill and hook must still be installed without claude: %+v", rep)
	}
}

func TestInstallProjectWithMalformedSettingsContinuesTheOtherSteps(t *testing.T) {
	folder := fakeRepo(t)
	const broken = `{"permissions": [`
	writeTestFile(t, settingsFile(folder), broken)
	f := newFakeClaude()

	rep, err := InstallWorkbench(context.Background(), workbenchOpts(folder, f))
	if !errors.Is(err, ErrMalformedSettings) {
		t.Fatalf("expected ErrMalformedSettings, got %v", err)
	}
	if readTestFile(t, settingsFile(folder)) != broken {
		t.Fatalf("PROJ-04: a malformed settings file was modified")
	}
	if rep.Skill.State != StateInstalled || !rep.MCPRegistered || rep.HookChanged {
		t.Fatalf("the other steps must still run: %+v", rep)
	}
}

func TestProj02_RemoveProjectLeavesNothingInstalled(t *testing.T) {
	folder := fakeRepo(t)
	exclude := filepath.Join(folder, ".git", "info", "exclude")
	writeTestFile(t, exclude, "*.swp\n")
	f := newFakeClaude()
	o := workbenchOpts(folder, f)
	if _, err := InstallWorkbench(context.Background(), o); err != nil {
		t.Fatalf("install: %v", err)
	}

	if err := RemoveWorkbench(context.Background(), o); err != nil {
		t.Fatalf("remove: %v", err)
	}
	for _, p := range []string{
		workbenchSkillFile(folder),
		filepath.Join(folder, ".claude", "skills", WorkbenchSkillName, shippedDigestFile),
		settingsFile(folder),
		filepath.Join(folder, ".claude"),
	} {
		if _, err := os.Stat(p); !os.IsNotExist(err) {
			t.Fatalf("PROJ-02: %s survived the removal (stat err=%v)", p, err)
		}
	}
	if got := readTestFile(t, exclude); got != "*.swp\n" {
		t.Fatalf("PROJ-02: the exclude file must be exactly the owner's again, got:\n%s", got)
	}
	if len(f.registered) != 0 {
		t.Fatalf("PROJ-02: the MCP registration survived: %v", f.registered)
	}
	if err := RemoveWorkbench(context.Background(), o); err != nil {
		t.Fatalf("a second removal must be a clean no-op: %v", err)
	}
}

// The same guarantee, checked by git itself: nothing Watchtower installs
// ever shows in `git status`, and removal leaves the repo as it was.
func TestProj02_RemoveProjectLeavesGitStatusClean(t *testing.T) {
	gitBin, err := exec.LookPath("git")
	if err != nil {
		t.Skip("git not installed")
	}
	folder := t.TempDir()
	git := func(args ...string) string {
		t.Helper()
		c := exec.Command(gitBin, args...)
		c.Dir = folder
		// No global/system config: an owner's global ignore of
		// settings.local.json would make this test pass vacuously.
		c.Env = append(os.Environ(), "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1")
		out, err := c.CombinedOutput()
		if err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
		return string(out)
	}
	git("init", "-q")
	status := func() string { return git("status", "--porcelain", "--untracked-files=all") }
	if s := status(); s != "" {
		t.Fatalf("fresh repo not clean: %q", s)
	}

	f := newFakeClaude()
	o := workbenchOpts(folder, f)
	if _, err := InstallWorkbench(context.Background(), o); err != nil {
		t.Fatalf("install: %v", err)
	}
	if s := status(); s != "" {
		t.Fatalf("installed files are visible to git:\n%s", s)
	}
	if err := RemoveWorkbench(context.Background(), o); err != nil {
		t.Fatalf("remove: %v", err)
	}
	if s := status(); s != "" {
		t.Fatalf("PROJ-02: git status is not clean after removal:\n%s", s)
	}
	if strings.Contains(readTestFile(t, filepath.Join(folder, ".git", "info", "exclude")), excludeBegin) {
		t.Fatalf("PROJ-02: our exclude block survived the removal")
	}
}

func TestProj02_RemoveProjectKeepsOwnerSettingsButDropsOurHook(t *testing.T) {
	folder := fakeRepo(t)
	writeTestFile(t, settingsFile(folder), `{"model": "sonnet"}`)
	f := newFakeClaude()
	o := workbenchOpts(folder, f)
	if _, err := InstallWorkbench(context.Background(), o); err != nil {
		t.Fatalf("install: %v", err)
	}
	if err := RemoveWorkbench(context.Background(), o); err != nil {
		t.Fatalf("remove: %v", err)
	}
	got := decodeSettings(t, folder)
	if got["model"] != "sonnet" || got["hooks"] != nil {
		t.Fatalf("expected exactly the owner's settings back, got %#v", got)
	}
	// The owner's file survives, so its exclude line stays: removing it
	// would suddenly surface the owner's own file in `git status`.
	exclude := readTestFile(t, filepath.Join(folder, ".git", "info", "exclude"))
	if !strings.Contains(exclude, "/.claude/settings.local.json") || strings.Contains(exclude, "/.claude/skills/watchtower-workbench/") {
		t.Fatalf("exclude after remove:\n%s", exclude)
	}
}

func TestProj04_EditedProjectSkillIsNeverClobbered(t *testing.T) {
	folder := fakeRepo(t)
	f := newFakeClaude()
	o := workbenchOpts(folder, f)
	if _, err := InstallWorkbench(context.Background(), o); err != nil {
		t.Fatalf("install: %v", err)
	}
	edited := "---\nname: watchtower-workbench\ndescription: mine now\n" + MarkerKey + ": v1\n---\n\nMy own board rules.\n"
	writeTestFile(t, workbenchSkillFile(folder), edited)

	rep, err := InstallWorkbench(context.Background(), o)
	if err != nil {
		t.Fatalf("reinstall: %v", err)
	}
	if rep.Skill.State != StateDrifted {
		t.Fatalf("expected drifted, got %s", rep.Skill.State)
	}
	if err := RemoveWorkbench(context.Background(), o); err != nil {
		t.Fatalf("remove: %v", err)
	}
	if got := readTestFile(t, workbenchSkillFile(folder)); got != edited {
		t.Fatalf("PROJ-04: an edited project skill was overwritten or removed")
	}
	st, err := StatusWorkbench(context.Background(), o)
	if err != nil || st.Skill.State != StateDrifted || st.Hook || st.MCP {
		t.Fatalf("after remove only the edited skill may remain: %+v err=%v", st, err)
	}
	// The kept skill stays git-invisible.
	if !strings.Contains(readTestFile(t, filepath.Join(folder, ".git", "info", "exclude")), "/.claude/skills/watchtower-workbench/") {
		t.Fatalf("the kept skill's exclude line must stay")
	}
}

func TestRemoveProjectWithAMissingFolderTouchesNothing(t *testing.T) {
	f := newFakeClaude()
	o := workbenchOpts(filepath.Join(t.TempDir(), "gone"), f)
	err := RemoveWorkbench(context.Background(), o)
	if err == nil || !strings.Contains(err.Error(), "no longer exists") {
		t.Fatalf("expected a folder-gone error, got %v", err)
	}
	if len(f.calls) != 0 {
		t.Fatalf("no claude call may run in a missing folder: %v", f.calls)
	}
}

func TestStatusProjectReportsEachPart(t *testing.T) {
	folder := fakeRepo(t)
	f := newFakeClaude()
	o := workbenchOpts(folder, f)

	st, err := StatusWorkbench(context.Background(), o)
	if err != nil {
		t.Fatalf("status: %v", err)
	}
	if st.Skill.State != StateMissing || st.Hook || st.MCP || !st.ClaudeFound {
		t.Fatalf("before install: %+v", st)
	}
	if _, err := InstallWorkbench(context.Background(), o); err != nil {
		t.Fatalf("install: %v", err)
	}
	st, err = StatusWorkbench(context.Background(), o)
	if err != nil || st.Skill.State != StateUnchanged || !st.Hook || !st.MCP {
		t.Fatalf("after install: %+v err=%v", st, err)
	}

	f.missing = true
	st, err = StatusWorkbench(context.Background(), o)
	if err != nil || st.ClaudeFound || st.MCP {
		t.Fatalf("without claude, status must report it rather than fail: %+v err=%v", st, err)
	}
}

// TestProjectMCPCommand_MatchesTheDesktopFixture pins the text the Desktop's
// ProjectInstallStatus.manualMCPCommand reproduces (ProjectCLITests
// testManualMCPCommandMatchesTheGoTwin): change both sides together.
func TestProjectMCPCommand_MatchesTheDesktopFixture(t *testing.T) {
	cases := []struct {
		o    WorkbenchInstallOptions
		want string
	}{
		{WorkbenchInstallOptions{WorkbenchID: 7, Folder: "/tmp/acme project", Bin: "/tmp/acme bin/it's/watchtower"},
			`cd '/tmp/acme project' && claude mcp add --scope local watchtower-workbench -- '/tmp/acme bin/it'\''s/watchtower' mcp --workbench 7`},
		{WorkbenchInstallOptions{WorkbenchID: 3, Folder: "/tmp/acme", Bin: "/usr/local/bin/watchtower"},
			`cd /tmp/acme && claude mcp add --scope local watchtower-workbench -- /usr/local/bin/watchtower mcp --workbench 3`},
	}
	for _, c := range cases {
		if got := WorkbenchMCPCommand(c.o); got != c.want {
			t.Errorf("ProjectMCPCommand(%+v):\n got %s\nwant %s", c.o, got, c.want)
		}
	}
}
