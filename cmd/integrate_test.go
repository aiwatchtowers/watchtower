package cmd

import (
	"os"
	"path/filepath"
	"testing"
)

func TestResolveSkillsDirUserScopeUsesHome(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	got, err := resolveSkillsDir("user", "")
	if err != nil {
		t.Fatalf("resolving: %v", err)
	}
	want := filepath.Join(home, ".claude", "skills")
	if got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
}

func TestResolveSkillsDirProjectScopeUsesCwd(t *testing.T) {
	dir := t.TempDir()
	cwd, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	t.Cleanup(func() { _ = os.Chdir(cwd) })
	if err := os.Chdir(dir); err != nil {
		t.Fatalf("chdir: %v", err)
	}

	got, err := resolveSkillsDir("project", "")
	if err != nil {
		t.Fatalf("resolving: %v", err)
	}
	// t.TempDir may hand back a symlinked path (/var vs /private/var on
	// macOS); compare resolved forms.
	gotReal, _ := filepath.EvalSymlinks(got)
	wantReal, _ := filepath.EvalSymlinks(filepath.Join(dir, ".claude", "skills"))
	if gotReal != wantReal {
		t.Fatalf("got %q, want %q", gotReal, wantReal)
	}
}

func TestResolveSkillsDirExplicitPathWins(t *testing.T) {
	got, err := resolveSkillsDir("user", "/tmp/somewhere/skills")
	if err != nil {
		t.Fatalf("resolving: %v", err)
	}
	if got != "/tmp/somewhere/skills" {
		t.Fatalf("explicit --path must win, got %q", got)
	}
}

func TestResolveSkillsDirRejectsUnknownScope(t *testing.T) {
	if _, err := resolveSkillsDir("global", ""); err == nil {
		t.Fatalf("expected an error for an unknown scope")
	}
}

func TestShouldTouchMCPSkipsWhenTargetIsNarrowed(t *testing.T) {
	// An explicit --path (or a non-default --scope) resolves to something
	// other than the real default location — that must never reach the
	// global MCP registration on its own.
	if shouldTouchMCP(false, false, "/tmp/scratch/skills", "/home/dev/.claude/skills") {
		t.Fatalf("a narrowed target must not touch the global MCP registration")
	}
}

func TestShouldTouchMCPRunsOnDefaultTarget(t *testing.T) {
	if !shouldTouchMCP(false, false, "/home/dev/.claude/skills", "/home/dev/.claude/skills") {
		t.Fatalf("the default target should still touch the MCP registration")
	}
}

func TestShouldTouchMCPSkillsOnlyAlwaysSkips(t *testing.T) {
	if shouldTouchMCP(true, false, "/home/dev/.claude/skills", "/home/dev/.claude/skills") {
		t.Fatalf("--skills-only must never touch the MCP registration, even at the default target")
	}
}

func TestShouldTouchMCPMCPOnlyOverridesNarrowedTarget(t *testing.T) {
	if !shouldTouchMCP(false, true, "/tmp/scratch/skills", "/home/dev/.claude/skills") {
		t.Fatalf("--mcp-only must reach the MCP registration even with a narrowed target")
	}
}

// resolveMCPScope is the single decision "integrate claude-code" and
// "integrate remove" both route through, so testing it once pins the
// symmetry between the two subcommands rather than assuming it holds.

func TestResolveMCPScopeDefaultTouchesBoth(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	scope, err := resolveMCPScope("user", "", false, false)
	if err != nil {
		t.Fatalf("resolving: %v", err)
	}
	if !scope.touchSkills || !scope.touchMCP {
		t.Fatalf("a default invocation should touch both halves, got touchSkills=%v touchMCP=%v", scope.touchSkills, scope.touchMCP)
	}
}

func TestResolveMCPScopeNarrowedPathSkipsMCPButNotSkills(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	scope, err := resolveMCPScope("user", "/tmp/scratch/skills", false, false)
	if err != nil {
		t.Fatalf("resolving: %v", err)
	}
	if !scope.touchSkills {
		t.Fatalf("an explicit --path should still touch the skill pack")
	}
	if scope.touchMCP {
		t.Fatalf("an explicit --path must not touch the global MCP registration by default")
	}
}

func TestResolveMCPScopeSkillsOnlySkipsMCPAtDefaultTarget(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	scope, err := resolveMCPScope("user", "", true, false)
	if err != nil {
		t.Fatalf("resolving: %v", err)
	}
	if scope.touchMCP {
		t.Fatalf("--skills-only must skip the MCP half even at the default target")
	}
}

func TestResolveMCPScopeMCPOnlySkipsSkillsAndForcesMCP(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	scope, err := resolveMCPScope("user", "/tmp/scratch/skills", false, true)
	if err != nil {
		t.Fatalf("resolving: %v", err)
	}
	if scope.touchSkills {
		t.Fatalf("--mcp-only must skip the skill pack")
	}
	if !scope.touchMCP {
		t.Fatalf("--mcp-only must reach the MCP registration even with a narrowed --path")
	}
}

func TestResolveMCPScopeRejectsBothOnlyFlags(t *testing.T) {
	if _, err := resolveMCPScope("user", "", true, true); err == nil {
		t.Fatalf("expected an error when --skills-only and --mcp-only are both set")
	}
}
