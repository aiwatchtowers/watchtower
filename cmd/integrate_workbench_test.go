package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"

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
		t.Fatalf("projectRemoveInstall: %v", err)
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
	if !got.StopHook || !got.StateHooks || !got.AskGuard || !got.AskToolBlock {
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
		{"prompt hook", func(hooks map[string]any) {
			// Keep the drift check's group, drop the prompt hook's.
			var kept []any
			for _, g := range hooks["Stop"].([]any) {
				h := g.(map[string]any)["hooks"].([]any)[0].(map[string]any)
				if h["type"] != "prompt" {
					kept = append(kept, g)
				}
			}
			hooks["Stop"] = kept
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
