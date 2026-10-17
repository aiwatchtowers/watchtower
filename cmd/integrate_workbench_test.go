package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"watchtower/internal/codex"
	"watchtower/internal/db"
	"watchtower/internal/devpack"
)

// fakeWorkbenchClaude keeps the local-scope registrations per cwd and server
// name ("<cwd>\x00<server>"). It never execs anything; tests swap it in for
// workbenchCommandRunner.
type fakeWorkbenchClaude struct {
	mu         sync.Mutex
	registered map[string]bool
	failRemove bool // every `mcp remove` exits non-zero
	failAdd    bool // every `mcp add` exits non-zero
}

func fakeRegistration(dir, server string) string { return dir + "\x00" + server }

func (f *fakeWorkbenchClaude) run(_ context.Context, dir, name string, args ...string) ([]byte, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(args) >= 2 && args[0] == "--setting-sources" && args[1] == "project,local" {
		args = args[2:] // devpack's `mcp get` isolation; its own tests pin it
	}
	if name != "claude" || len(args) < 3 || args[0] != "mcp" {
		return nil, fmt.Errorf("unexpected command %s %v", name, args)
	}
	server := args[len(args)-1] // get NAME, remove --scope local NAME
	if args[1] == "add" {
		server = args[4] // add --scope local NAME -- ...
	}
	key := fakeRegistration(dir, server)
	switch args[1] {
	case "get":
		if f.registered[key] {
			return nil, nil
		}
		return nil, devpack.ErrCommandExit
	case "add":
		if f.failAdd {
			return []byte("add failed"), devpack.ErrCommandExit
		}
		f.registered[key] = true
		return nil, nil
	case "remove":
		if f.failRemove {
			return []byte("remove failed"), devpack.ErrCommandExit
		}
		delete(f.registered, key)
		return nil, nil
	}
	return nil, devpack.ErrCommandExit
}

func useFakeWorkbenchClaude(t *testing.T) *fakeWorkbenchClaude {
	t.Helper()
	f := &fakeWorkbenchClaude{registered: map[string]bool{}}
	prev := workbenchCommandRunner
	workbenchCommandRunner = f.run
	t.Cleanup(func() { workbenchCommandRunner = prev })
	return f
}

func testWorkbench(t *testing.T) *db.Workbench {
	t.Helper()
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, ".git", "info"), 0o755); err != nil {
		t.Fatalf("mkdir .git: %v", err)
	}
	// The test binary is not named "watchtower" (looksLikeOurHook, I2), so
	// hook recognition would never see its own entry as installed.
	prev := workbenchExecutable
	workbenchExecutable = func() (string, error) { return "/usr/local/bin/watchtower", nil }
	t.Cleanup(func() { workbenchExecutable = prev })
	return &db.Workbench{ID: 7, Name: "acme", FolderPath: dir}
}

// PROJ-02: `project delete` reaches the folder removal through the
// workbenchRemoveInstall hook Task 4 left as a no-op.
func TestProj02_ProjectDeleteRunsTheFolderRemoval(t *testing.T) {
	f := useFakeWorkbenchClaude(t)
	p := testWorkbench(t)
	var out bytes.Buffer
	if err := runWorkbenchInstall(context.Background(), &out, p); err != nil {
		t.Fatalf("install: %v\n%s", err, out.String())
	}
	skill := filepath.Join(p.FolderPath, ".claude", "skills", devpack.WorkbenchSkillName, "SKILL.md")
	if _, err := os.Stat(skill); err != nil {
		t.Fatalf("install did not write the skill: %v", err)
	}

	if err := workbenchRemoveInstall(context.Background(), nil, p); err != nil {
		t.Fatalf("workbenchRemoveInstall: %v", err)
	}
	for _, path := range []string{skill, filepath.Join(p.FolderPath, ".claude", "settings.local.json")} {
		if _, err := os.Stat(path); !os.IsNotExist(err) {
			t.Fatalf("PROJ-02: %s survived project delete's removal (err=%v)", path, err)
		}
	}
	if f.registered[fakeRegistration(p.FolderPath, devpack.WorkbenchMCPServerName)] {
		t.Fatalf("PROJ-02: the MCP registration survived project delete's removal")
	}
}

func TestIntegrateProjectStatusJSON(t *testing.T) {
	useFakeWorkbenchClaude(t)
	p := testWorkbench(t)
	var out bytes.Buffer
	if err := runWorkbenchInstall(context.Background(), &out, p); err != nil {
		t.Fatalf("install: %v", err)
	}
	out.Reset()
	if err := runWorkbenchStatus(context.Background(), &out, p, true); err != nil {
		t.Fatalf("status: %v", err)
	}
	var got workbenchStatusJSON
	if err := json.Unmarshal(out.Bytes(), &got); err != nil {
		t.Fatalf("status --json is not JSON: %v\n%s", err, out.String())
	}
	if got.WorkbenchID != 7 || got.Folder != p.FolderPath || got.Skill != "unchanged" || !got.Hook || !got.MCP || !got.ClaudeFound {
		t.Fatalf("unexpected status: %+v", got)
	}
	if !got.StopHook || !got.StateHooks || !got.AskGuard || !got.AskToolBlock || !got.PermissionWait {
		t.Fatalf("every hook is installed: %+v", got)
	}
}

// state_hooks is false while any one of the session state entries is
// missing (the Desktop then offers Repair).
func TestIntegrateWorkbenchStatusJSON_StateHooksFalseWithOneMissing(t *testing.T) {
	useFakeWorkbenchClaude(t)
	p := testWorkbench(t)
	var out bytes.Buffer
	if err := runWorkbenchInstall(context.Background(), &out, p); err != nil {
		t.Fatalf("install: %v", err)
	}
	settings := filepath.Join(p.FolderPath, ".claude", "settings.local.json")
	b, err := os.ReadFile(settings)
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatal(err)
	}
	delete(m["hooks"].(map[string]any), "PostToolUse")
	b, err = json.Marshal(m)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(settings, b, 0o644); err != nil {
		t.Fatal(err)
	}
	out.Reset()
	if err := runWorkbenchStatus(context.Background(), &out, p, true); err != nil {
		t.Fatalf("status: %v", err)
	}
	if !strings.Contains(out.String(), `"state_hooks": false`) || !strings.Contains(out.String(), `"stop_hook": true`) {
		t.Fatalf("status --json must report state_hooks false and stop_hook true:\n%s", out.String())
	}
}

// ask_guard and ask_tool_block each go false with their own entry gone
// (the Desktop then offers Repair).
func TestIntegrateWorkbenchStatusJSON_AskGuardKeys(t *testing.T) {
	for _, tc := range []struct {
		name       string
		drop       func(hooks map[string]any)
		gone, kept string
	}{
		{"stop command", func(hooks map[string]any) {
			hooks["Stop"] = withoutAskGuardStop(hooks["Stop"].([]any))
		}, `"ask_guard": false`, `"ask_tool_block": true`},
		// Only the old marker prompt (an install from before the command
		// hook): not the ask guard, so the Desktop offers Repair.
		{"marker prompt only", func(hooks map[string]any) {
			hooks["Stop"] = append(withoutAskGuardStop(hooks["Stop"].([]any)), map[string]any{"hooks": []any{
				map[string]any{"type": "prompt", "prompt": "[watchtower-workbench ask-guard 7]\nv3", "timeout": 30}}})
		}, `"ask_guard": false`, `"ask_tool_block": true`},
		{"tool block", func(hooks map[string]any) { delete(hooks, "PreToolUse") },
			`"ask_tool_block": false`, `"ask_guard": true`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			useFakeWorkbenchClaude(t)
			p := testWorkbench(t)
			var out bytes.Buffer
			if err := runWorkbenchInstall(context.Background(), &out, p); err != nil {
				t.Fatalf("install: %v", err)
			}
			out.Reset()
			if err := runWorkbenchStatus(context.Background(), &out, p, true); err != nil {
				t.Fatalf("status: %v", err)
			}
			if !strings.Contains(out.String(), `"ask_guard": true`) || !strings.Contains(out.String(), `"ask_tool_block": true`) {
				t.Fatalf("an installed workbench reports both keys true:\n%s", out.String())
			}
			editSettingsHooks(t, p.FolderPath, tc.drop)
			out.Reset()
			if err := runWorkbenchStatus(context.Background(), &out, p, true); err != nil {
				t.Fatalf("status: %v", err)
			}
			if !strings.Contains(out.String(), tc.gone) || !strings.Contains(out.String(), tc.kept) || !strings.Contains(out.String(), `"stop_hook": true`) {
				t.Fatalf("status --json must report %s and %s:\n%s", tc.gone, tc.kept, out.String())
			}
		})
	}
}

// withoutAskGuardStop keeps the Stop groups that hold no ask guard
// command entry (the drift check's).
func withoutAskGuardStop(stop []any) []any {
	var kept []any
	for _, g := range stop {
		h := g.(map[string]any)["hooks"].([]any)[0].(map[string]any)
		if cmd, _ := h["command"].(string); !strings.HasSuffix(cmd, " --stop") {
			kept = append(kept, g)
		}
	}
	return kept
}

// editSettingsHooks rewrites the folder's settings.local.json with edit
// applied to its hooks object.
func editSettingsHooks(t *testing.T, folder string, edit func(hooks map[string]any)) {
	t.Helper()
	settings := filepath.Join(folder, ".claude", "settings.local.json")
	b, err := os.ReadFile(settings)
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatal(err)
	}
	edit(m["hooks"].(map[string]any))
	if b, err = json.Marshal(m); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(settings, b, 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestIntegrateProjectRejectsGlobalFlags(t *testing.T) {
	if err := checkWorkbenchFlags("--workbench", false, "", false, false); err != nil {
		t.Fatalf("plain --project must be accepted: %v", err)
	}
	for name, args := range map[string][4]any{
		"scope":       {true, "", false, false},
		"path":        {false, "/tmp/skills", false, false},
		"skills-only": {false, "", true, false},
		"mcp-only":    {false, "", false, true},
	} {
		if err := checkWorkbenchFlags("--project", args[0].(bool), args[1].(string), args[2].(bool), args[3].(bool)); err == nil || !strings.HasPrefix(err.Error(), "--project ") {
			t.Fatalf("--project with --%s must be refused", name)
		}
	}
}

func TestExecCommandRunnerClassifiesFailures(t *testing.T) {
	dir := t.TempDir()
	if _, err := execCommandRunner(context.Background(), dir, "sh", "-c", "exit 3"); !errors.Is(err, devpack.ErrCommandExit) {
		t.Fatalf("a non-zero exit must wrap ErrCommandExit, got %v", err)
	}
	if _, err := execCommandRunner(context.Background(), dir, "watchtower-no-such-binary-acme"); !errors.Is(err, exec.ErrNotFound) {
		t.Fatalf("a missing binary must wrap exec.ErrNotFound, got %v", err)
	}
	out, err := execCommandRunner(context.Background(), dir, "sh", "-c", "pwd")
	if err != nil {
		t.Fatalf("pwd: %v", err)
	}
	gotDir, _ := filepath.EvalSymlinks(string(bytes.TrimSpace(out)))
	wantDir, _ := filepath.EvalSymlinks(dir)
	if gotDir != wantDir {
		t.Fatalf("the runner must run in dir: got %q want %q", gotDir, wantDir)
	}
}

// fakeCmdCodex stands in for codex's app-server in cmd tests: it lists the
// launch-flag hooks of the watchtower binary's codex hook set and keeps the
// trust they get.
type fakeCmdCodex struct {
	ctx     context.Context // the last start's context
	bin     string          // the codex binary codexFindBinary resolves
	trusted map[string]bool
	writes  int
}

func useFakeCmdCodex(t *testing.T) *fakeCmdCodex {
	t.Helper()
	f := &fakeCmdCodex{bin: filepath.Join(t.TempDir(), "codex"), trusted: map[string]bool{}}
	if err := os.WriteFile(f.bin, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	prevFind, prevStart := codexFindBinary, codexAppServerStart
	codexFindBinary = func() (string, error) { return f.bin, nil }
	codexAppServerStart = func(ctx context.Context, bin string, _, _ []string) (codex.AppServer, error) {
		f.ctx = ctx
		if bin != f.bin {
			return nil, fmt.Errorf("unexpected codex %q", bin)
		}
		return f, nil
	}
	t.Cleanup(func() { codexFindBinary, codexAppServerStart = prevFind, prevStart })
	return f
}

func (f *fakeCmdCodex) ListHooks(context.Context, string) ([]codex.HookEntry, error) {
	var out []codex.HookEntry
	for i, h := range devpack.CodexHookSet("/usr/local/bin/watchtower") {
		key := fmt.Sprintf("/<session-flags>/config.toml:%d", i)
		trust := "untrusted"
		if f.trusted[key] {
			trust = "trusted"
		}
		out = append(out, codex.HookEntry{Key: key, Command: h.Command, CurrentHash: "sha256:" + key,
			TrustStatus: trust, Source: "sessionFlags", Event: strings.ToLower(h.Event[:1]) + h.Event[1:]})
	}
	return out, nil
}

func (f *fakeCmdCodex) TrustHooks(_ context.Context, entries []codex.HookEntry) error {
	f.writes++
	for _, e := range entries {
		f.trusted[e.Key] = true
	}
	return nil
}

func (f *fakeCmdCodex) Close() error { return nil }

func codexSkillPath(folder string) string {
	return filepath.Join(folder, ".agents", "skills", devpack.WorkbenchSkillName, "SKILL.md")
}

func TestIntegrateStatusJSON_HasCodexObjectAndKeepsClaudeKeys(t *testing.T) {
	useFakeWorkbenchClaude(t)
	useFakeCmdCodex(t)
	p := testWorkbench(t)
	var out bytes.Buffer
	if err := runWorkbenchInstall(context.Background(), &out, p); err != nil {
		t.Fatalf("install: %v", err)
	}
	if err := runCodexInstall(context.Background(), &out, p); err != nil {
		t.Fatalf("codex install: %v\n%s", err, out.String())
	}
	out.Reset()
	if err := runWorkbenchStatus(context.Background(), &out, p, true); err != nil {
		t.Fatalf("status: %v", err)
	}
	got := strings.ReplaceAll(out.String(), p.FolderPath, "/Users/example/acme")
	golden := filepath.Join("testdata", "integrate_status_codex.golden.json")
	want, err := os.ReadFile(golden)
	if err != nil {
		t.Fatal(err)
	}
	if got != string(want) {
		t.Fatalf("status --json drifted from %s:\n%s", golden, got)
	}
}

func TestIntegrateStatusJSON_CodexNotFoundIsNullTrust(t *testing.T) {
	useFakeWorkbenchClaude(t)
	p := testWorkbench(t)
	var out bytes.Buffer
	if err := runWorkbenchStatus(context.Background(), &out, p, true); err != nil {
		t.Fatalf("status: %v", err)
	}
	var got map[string]any
	if err := json.Unmarshal(out.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	want := map[string]any{"found": false, "skill": false, "skill_state": "missing", "hooks_trusted": nil, "imported_duplicates": false}
	if fmt.Sprint(got["codex"]) != fmt.Sprint(want) {
		t.Fatalf("codex = %v, want %v", got["codex"], want)
	}
	out.Reset()
	if err := runWorkbenchStatus(context.Background(), &out, p, false); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), "  codex    not found, skill missing, hooks trusted unknown\n") {
		t.Fatalf("text status:\n%s", out.String())
	}
}

// A config that does not load is not "codex found": status says codex was
// not resolved and why, on the wire and in the text report (#399 B1).
func TestIntegrateStatus_ConfigErrorIsATrustError(t *testing.T) {
	useFakeWorkbenchClaude(t)
	useFakeCmdCodex(t)
	bad := filepath.Join(t.TempDir(), "config.yaml")
	if err := os.WriteFile(bad, []byte("workbench: [unclosed\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	prev := flagConfig
	flagConfig = bad
	t.Cleanup(func() { flagConfig = prev })
	p := testWorkbench(t)
	var out bytes.Buffer
	if err := runWorkbenchStatus(context.Background(), &out, p, true); err != nil {
		t.Fatalf("status: %v", err)
	}
	var got struct {
		Codex codexStatusJSON `json:"codex"`
	}
	if err := json.Unmarshal(out.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if got.Codex.Found || got.Codex.HooksTrusted != nil || !strings.Contains(got.Codex.TrustError, "loading config") {
		t.Fatalf("codex = %+v", got.Codex)
	}
	out.Reset()
	if err := runWorkbenchStatus(context.Background(), &out, p, false); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), "trust check failed: could not resolve the codex binary: loading config") {
		t.Fatalf("text status:\n%s", out.String())
	}
}

func TestIntegrateCodex_InstallReportsAndIsIdempotent(t *testing.T) {
	f := useFakeCmdCodex(t)
	p := testWorkbench(t)
	var out bytes.Buffer
	if err := runCodexInstall(context.Background(), &out, p); err != nil {
		t.Fatalf("install: %v\n%s", err, out.String())
	}
	want := fmt.Sprintf("Workbench 7 (%s), codex:\n  skill    installed (.agents/skills/watchtower-workbench)\n"+
		"  preset   installed (.agents/skills/watchtower-flow)\n  trust    hooks trusted\n", p.FolderPath)
	if out.String() != want {
		t.Fatalf("report:\n%s\nwant:\n%s", out.String(), want)
	}
	out.Reset()
	if err := runCodexInstall(context.Background(), &out, p); err != nil {
		t.Fatal(err)
	}
	if f.writes != 1 || !strings.Contains(out.String(), "skill    unchanged") {
		t.Fatalf("second run: writes=%d\n%s", f.writes, out.String())
	}
}

func TestIntegrateCodex_MissingCodexIsNotAnError(t *testing.T) {
	p := testWorkbench(t)
	var out bytes.Buffer
	if err := runCodexInstall(context.Background(), &out, p); err != nil {
		t.Fatalf("a missing codex must not fail the install (D5): %v", err)
	}
	if !strings.Contains(out.String(), "trust    skipped — codex not found") {
		t.Fatalf("report:\n%s", out.String())
	}
	if _, err := os.Stat(codexSkillPath(p.FolderPath)); err != nil {
		t.Fatalf("the skill is installed anyway: %v", err)
	}
}

func TestIntegrateCodex_FolderGoneIsCleanError(t *testing.T) {
	useFakeCmdCodex(t)
	p := testWorkbench(t)
	p.FolderPath = filepath.Join(p.FolderPath, "gone")
	for name, run := range map[string]workbenchIntegrateFunc{"install": runCodexInstall, "remove": runCodexRemove} {
		var out bytes.Buffer
		err := run(context.Background(), &out, p)
		if err == nil || !strings.Contains(err.Error(), "no longer exists") {
			t.Fatalf("%s: err = %v", name, err)
		}
		if _, statErr := os.Stat(p.FolderPath); !os.IsNotExist(statErr) {
			t.Fatalf("%s recreated the folder", name)
		}
	}
	var out bytes.Buffer
	if err := runWorkbenchStatus(context.Background(), &out, p, true); err == nil {
		t.Fatalf("status of a gone folder must fail")
	}
}

func TestIntegrateCodex_RemoveKeepsTrust(t *testing.T) {
	f := useFakeCmdCodex(t)
	p := testWorkbench(t)
	var out bytes.Buffer
	if err := runCodexInstall(context.Background(), &out, p); err != nil {
		t.Fatal(err)
	}
	out.Reset()
	if err := runCodexRemove(context.Background(), &out, p); err != nil {
		t.Fatalf("remove: %v", err)
	}
	if _, err := os.Stat(filepath.Join(p.FolderPath, ".agents")); !os.IsNotExist(err) {
		t.Fatalf(".agents survived: %v", err)
	}
	if len(f.trusted) != len(devpack.CodexHookSet("x")) || f.writes != 1 {
		t.Fatalf("removal touched the trust: %v", f.trusted)
	}
	if !strings.Contains(out.String(), "left in place") {
		t.Fatalf("report:\n%s", out.String())
	}
}

// The app-server starts under the caller's context (plus SIGINT/SIGTERM), so
// a cancelled run closes it and kills its process group.
func TestIntegrateCodex_AppServerContextFollowsTheCaller(t *testing.T) {
	useFakeWorkbenchClaude(t)
	f := useFakeCmdCodex(t)
	p := testWorkbench(t)
	// Status asks codex only in a folder set up for it (the skill copy).
	if err := runCodexInstall(context.Background(), io.Discard, p); err != nil {
		t.Fatal(err)
	}
	for name, run := range map[string]workbenchIntegrateFunc{
		"install": runCodexInstall,
		"status": func(ctx context.Context, w io.Writer, p *db.Workbench) error {
			return runWorkbenchStatus(ctx, w, p, true)
		},
	} {
		f.ctx = nil
		ctx, cancel := context.WithCancel(context.Background())
		var out bytes.Buffer
		_ = run(ctx, &out, p)
		if f.ctx == nil {
			t.Fatalf("%s: no app-server started", name)
		}
		if f.ctx.Err() == nil {
			t.Fatalf("%s: the app-server context outlived the run", name)
		}
		cancel()
		f.ctx = nil
		ctx, cancel = context.WithCancel(context.Background())
		cancel()
		_ = run(ctx, &out, p)
		if f.ctx == nil || !errors.Is(f.ctx.Err(), context.Canceled) {
			t.Fatalf("%s: a cancelled caller must cancel the app-server context", name)
		}
	}
}

func TestIntegrateCodex_RequiresWorkbench(t *testing.T) {
	prev := integrateWorkbenchID
	integrateWorkbenchID = 0
	t.Cleanup(func() { integrateWorkbenchID = prev })
	err := runIntegrateCodex(integrateCodexCmd, nil)
	var ec *exitCodeError
	if !errors.As(err, &ec) || ec.code != 2 {
		t.Fatalf("err = %v, want a usage error", err)
	}
}

// PROJ-02: `workbench delete` also takes the codex skill copy out.
func TestProj02_WorkbenchDeleteRemovesTheCodexSkill(t *testing.T) {
	useFakeWorkbenchClaude(t)
	useFakeCmdCodex(t)
	p := testWorkbench(t)
	var out bytes.Buffer
	if err := runCodexInstall(context.Background(), &out, p); err != nil {
		t.Fatal(err)
	}
	if err := workbenchRemoveInstall(context.Background(), nil, p); err != nil {
		t.Fatalf("remove: %v", err)
	}
	if _, err := os.Stat(filepath.Join(p.FolderPath, ".agents")); !os.IsNotExist(err) {
		t.Fatalf("PROJ-02: the codex skill survived workbench delete (err=%v)", err)
	}
	gone := &db.Workbench{ID: 7, FolderPath: filepath.Join(p.FolderPath, "gone")}
	if err := workbenchRemoveInstall(context.Background(), nil, gone); err == nil ||
		strings.Count(err.Error(), "no longer exists") != 1 {
		t.Fatalf("a gone folder is one error, got %v", err)
	}
}

func TestWorkbenchResync_RefreshesTheCodexPart(t *testing.T) {
	useFakeWorkbenchClaude(t)
	database := writeActionsConfig(t)
	pid, err := database.CreateWorkbench("acme", resyncFolder(t))
	if err != nil {
		t.Fatal(err)
	}
	p, err := database.GetWorkbench(pid)
	if err != nil {
		t.Fatal(err)
	}
	prev := workbenchExecutable
	workbenchExecutable = func() (string, error) { return "/usr/local/bin/watchtower", nil }
	t.Cleanup(func() { workbenchExecutable = prev })

	res, err := resyncWorkbench(context.Background(), database, p, false)
	if err != nil || res.Codex != nil {
		t.Fatalf("no codex, no skill copy: codex step skipped; got %+v, err %v", res.Codex, err)
	}

	useFakeCmdCodex(t)
	res, err = resyncWorkbench(context.Background(), database, p, false)
	if err != nil || res.Codex == nil || !res.Codex.OK || res.Codex.Skill != "installed" ||
		res.Codex.HooksTrusted == nil || !*res.Codex.HooksTrusted {
		t.Fatalf("codex found: the part is installed; got %+v, err %v", res.Codex, err)
	}
	b, _ := json.Marshal(res)
	if !strings.Contains(string(b), `"codex":{"ok":true,"error":"","found":true,"skill":"installed","flow":"installed","hooks_trusted":true,"duplicates_removed":false}`) {
		t.Fatalf("resync JSON: %s", b)
	}
}

// A config that does not load still lets resync find codex on PATH, but
// the codex part reports the config error, also in the text report
// (#399 B2).
func TestWorkbenchResync_CodexReportsAConfigThatDidNotLoad(t *testing.T) {
	useFakeWorkbenchClaude(t)
	database := writeActionsConfig(t)
	pid, err := database.CreateWorkbench("acme", resyncFolder(t))
	if err != nil {
		t.Fatal(err)
	}
	p, err := database.GetWorkbench(pid)
	if err != nil {
		t.Fatal(err)
	}
	prev := workbenchExecutable
	workbenchExecutable = func() (string, error) { return "/usr/local/bin/watchtower", nil }
	t.Cleanup(func() { workbenchExecutable = prev })
	useFakeCmdCodex(t)
	bad := filepath.Join(t.TempDir(), "config.yaml")
	if err := os.WriteFile(bad, []byte("workbench: [unclosed\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	prevCfg := flagConfig
	flagConfig = bad
	t.Cleanup(func() { flagConfig = prevCfg })

	res, _ := resyncWorkbench(context.Background(), database, p, false)
	if res.Codex == nil || res.Codex.OK || !res.Codex.Found ||
		!strings.Contains(res.Codex.Error, "loading config (codex_path ignored") {
		t.Fatalf("codex part: %+v", res.Codex)
	}
	if res.Codex.HooksTrusted == nil || !*res.Codex.HooksTrusted {
		t.Fatalf("the PATH codex is still set up: %+v", res.Codex)
	}
	var out bytes.Buffer
	printResyncReport(&out, p, res)
	if !strings.Contains(out.String(), "codex_path ignored") {
		t.Fatalf("text report:\n%s", out.String())
	}
}

// A config that does not load with codex neither on PATH nor in the folder:
// codex may be reachable only through the ignored codex_path, so resync
// says so instead of skipping the part quietly (#399 N1).
func TestWorkbenchResync_ConfigErrorWithoutCodexIsReported(t *testing.T) {
	useFakeWorkbenchClaude(t)
	database := writeActionsConfig(t)
	pid, err := database.CreateWorkbench("acme", resyncFolder(t))
	if err != nil {
		t.Fatal(err)
	}
	p, err := database.GetWorkbench(pid)
	if err != nil {
		t.Fatal(err)
	}
	prev := workbenchExecutable
	workbenchExecutable = func() (string, error) { return "/usr/local/bin/watchtower", nil }
	t.Cleanup(func() { workbenchExecutable = prev })
	bad := filepath.Join(t.TempDir(), "config.yaml")
	if err := os.WriteFile(bad, []byte("workbench: [unclosed\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	prevCfg := flagConfig
	flagConfig = bad
	t.Cleanup(func() { flagConfig = prevCfg })

	res, _ := resyncWorkbench(context.Background(), database, p, false)
	if res.Codex == nil || res.Codex.OK || !strings.Contains(res.Codex.Error, "codex_path ignored") {
		t.Fatalf("codex part: %+v", res.Codex)
	}
	var out bytes.Buffer
	printResyncReport(&out, p, res)
	if !strings.Contains(out.String(), "FAILED — loading config (codex_path ignored") {
		t.Fatalf("text report:\n%s", out.String())
	}
}

// permission_wait goes false with its PermissionRequest entry gone (the
// Desktop then offers Repair).
func TestIntegrateWorkbenchStatusJSON_PermissionWaitKey(t *testing.T) {
	useFakeWorkbenchClaude(t)
	p := testWorkbench(t)
	var out bytes.Buffer
	if err := runWorkbenchInstall(context.Background(), &out, p); err != nil {
		t.Fatalf("install: %v", err)
	}
	out.Reset()
	if err := runWorkbenchStatus(context.Background(), &out, p, true); err != nil {
		t.Fatalf("status: %v", err)
	}
	if !strings.Contains(out.String(), `"permission_wait": true`) {
		t.Fatalf("an installed workbench reports permission_wait true:\n%s", out.String())
	}
	editSettingsHooks(t, p.FolderPath, func(hooks map[string]any) { delete(hooks, "PermissionRequest") })
	out.Reset()
	if err := runWorkbenchStatus(context.Background(), &out, p, true); err != nil {
		t.Fatalf("status: %v", err)
	}
	if !strings.Contains(out.String(), `"permission_wait": false`) {
		t.Fatalf("a missing PermissionRequest entry reports false:\n%s", out.String())
	}
}
