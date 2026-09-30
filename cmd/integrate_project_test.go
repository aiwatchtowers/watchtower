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
	"sync"
	"testing"

	"watchtower/internal/db"
	"watchtower/internal/devpack"
)

// fakeProjectClaude keeps one local-scope registration per cwd. It never
// execs anything; tests swap it in for projectCommandRunner.
type fakeProjectClaude struct {
	mu         sync.Mutex
	registered map[string]bool
}

func (f *fakeProjectClaude) run(_ context.Context, dir, name string, args ...string) ([]byte, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if name != "claude" || len(args) < 2 || args[0] != "mcp" {
		return nil, fmt.Errorf("unexpected command %s %v", name, args)
	}
	switch args[1] {
	case "get":
		if f.registered[dir] {
			return nil, nil
		}
		return nil, devpack.ErrCommandExit
	case "add":
		f.registered[dir] = true
		return nil, nil
	case "remove":
		delete(f.registered, dir)
		return nil, nil
	}
	return nil, devpack.ErrCommandExit
}

func useFakeProjectClaude(t *testing.T) *fakeProjectClaude {
	t.Helper()
	f := &fakeProjectClaude{registered: map[string]bool{}}
	prev := projectCommandRunner
	projectCommandRunner = f.run
	t.Cleanup(func() { projectCommandRunner = prev })
	return f
}

func testProject(t *testing.T) *db.Project {
	t.Helper()
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, ".git", "info"), 0o755); err != nil {
		t.Fatalf("mkdir .git: %v", err)
	}
	// The test binary is not named "watchtower" (looksLikeOurHook, I2), so
	// hook recognition would never see its own entry as installed.
	prev := projectExecutable
	projectExecutable = func() (string, error) { return "/usr/local/bin/watchtower", nil }
	t.Cleanup(func() { projectExecutable = prev })
	return &db.Project{ID: 7, Name: "acme", FolderPath: dir}
}

// PROJ-02: `project delete` reaches the folder removal through the
// projectRemoveInstall hook Task 4 left as a no-op.
func TestProj02_ProjectDeleteRunsTheFolderRemoval(t *testing.T) {
	f := useFakeProjectClaude(t)
	p := testProject(t)
	var out bytes.Buffer
	if err := runProjectInstall(context.Background(), &out, p); err != nil {
		t.Fatalf("install: %v\n%s", err, out.String())
	}
	skill := filepath.Join(p.FolderPath, ".claude", "skills", devpack.ProjectSkillName, "SKILL.md")
	if _, err := os.Stat(skill); err != nil {
		t.Fatalf("install did not write the skill: %v", err)
	}

	if err := projectRemoveInstall(context.Background(), nil, p); err != nil {
		t.Fatalf("projectRemoveInstall: %v", err)
	}
	for _, path := range []string{skill, filepath.Join(p.FolderPath, ".claude", "settings.local.json")} {
		if _, err := os.Stat(path); !os.IsNotExist(err) {
			t.Fatalf("PROJ-02: %s survived project delete's removal (err=%v)", path, err)
		}
	}
	if f.registered[p.FolderPath] {
		t.Fatalf("PROJ-02: the MCP registration survived project delete's removal")
	}
}

func TestIntegrateProjectStatusJSON(t *testing.T) {
	useFakeProjectClaude(t)
	p := testProject(t)
	var out bytes.Buffer
	if err := runProjectInstall(context.Background(), &out, p); err != nil {
		t.Fatalf("install: %v", err)
	}
	out.Reset()
	if err := runProjectStatus(context.Background(), &out, p, true); err != nil {
		t.Fatalf("status: %v", err)
	}
	var got projectStatusJSON
	if err := json.Unmarshal(out.Bytes(), &got); err != nil {
		t.Fatalf("status --json is not JSON: %v\n%s", err, out.String())
	}
	if got.ProjectID != 7 || got.Folder != p.FolderPath || got.Skill != "unchanged" || !got.Hook || !got.MCP || !got.ClaudeFound {
		t.Fatalf("unexpected status: %+v", got)
	}
}

func TestIntegrateProjectRejectsGlobalFlags(t *testing.T) {
	if err := checkProjectFlags(false, "", false, false); err != nil {
		t.Fatalf("plain --project must be accepted: %v", err)
	}
	for name, args := range map[string][4]any{
		"scope":       {true, "", false, false},
		"path":        {false, "/tmp/skills", false, false},
		"skills-only": {false, "", true, false},
		"mcp-only":    {false, "", false, true},
	} {
		if err := checkProjectFlags(args[0].(bool), args[1].(string), args[2].(bool), args[3].(bool)); err == nil {
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
