// Package claude provides utilities for resolving and locating the Claude CLI binary.
package claude

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
)

var (
	cachedBinary   string
	cachedBinaryMu sync.Once

	cachedPATH   string
	cachedPATHMu sync.Once
)

// FindBinary looks up the Claude CLI binary.
// If override is non-empty and points to an executable file, it is used directly
// (bypasses cache — M1 fix).
// Otherwise tries exec.LookPath, then falls back to a login shell lookup
// (needed when launched from a macOS .app bundle where PATH is minimal).
// The result (without override) is cached after the first call.
func FindBinary(override string) string {
	// M1 fix: always check override first, even after cache is populated
	if override != "" {
		if info, err := os.Stat(override); err == nil && !info.IsDir() {
			return override
		}
	}

	cachedBinaryMu.Do(func() {
		// Fast path: already in PATH.
		if p, err := exec.LookPath("claude"); err == nil {
			cachedBinary = p
			return
		}
		// Login shell: NVM/fnm/volta init → full PATH. Non-interactive, so it
		// reads .zprofile/.zshenv but NOT .zshrc — PATH exports living there
		// (a common setup) are invisible here.
		if p := loginShellWhich("claude"); p != "" {
			cachedBinary = p
			return
		}
		// Well-known install locations — covers the .zshrc-only PATH case above,
		// which hits every GUI-app launch (Finder apps get a minimal PATH).
		if p := wellKnownBinary("claude"); p != "" {
			cachedBinary = p
			return
		}
		cachedBinary = "claude" // fallback — let exec report the error
	})

	return cachedBinary
}

// RichPATH returns a PATH that includes the directory of the resolved claude
// binary plus common Node.js locations, so that `#!/usr/bin/env node` in the
// Claude CLI shebang can resolve `node` even from a macOS .app bundle.
// The result is cached after the first call.
func RichPATH() string {
	cachedPATHMu.Do(func() {
		// Merge the login-shell PATH (nvm, fnm, volta init) with the well-known
		// dirs rather than trusting either source alone: a non-interactive
		// login shell skips .zshrc, where PATH exports often live.
		cachedPATH = mergePATH(loginShellPATH(), fallbackPATH())
	})

	return cachedPATH
}

// wellKnownBinary checks common install locations for a binary — the places
// installers use, mirrored from fallbackPATH's extra dirs.
func wellKnownBinary(name string) string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	for _, dir := range []string{
		filepath.Join(home, ".local", "bin"),
		filepath.Join(home, ".claude", "bin"),
		"/opt/homebrew/bin",
		"/usr/local/bin",
		filepath.Join(home, ".volta", "bin"),
	} {
		p := filepath.Join(dir, name)
		if info, err := os.Stat(p); err == nil && !info.IsDir() {
			return p
		}
	}
	return ""
}

// mergePATH joins PATH strings, deduplicating entries and dropping empties.
func mergePATH(paths ...string) string {
	seen := make(map[string]bool)
	var parts []string
	for _, ps := range paths {
		for _, p := range strings.Split(ps, ":") {
			if p == "" || seen[p] {
				continue
			}
			seen[p] = true
			parts = append(parts, p)
		}
	}
	return strings.Join(parts, ":")
}

func fallbackPATH() string {
	existing := os.Getenv("PATH")
	home, _ := os.UserHomeDir()
	extra := []string{
		"/usr/local/bin",
		"/opt/homebrew/bin",
	}
	if home != "" {
		nvmDir := filepath.Join(home, ".nvm", "versions", "node")
		if entries, err := os.ReadDir(nvmDir); err == nil {
			for i := len(entries) - 1; i >= 0; i-- {
				extra = append(extra, filepath.Join(nvmDir, entries[i].Name(), "bin"))
			}
		}
		extra = append(extra,
			filepath.Join(home, ".local", "bin"),
			filepath.Join(home, ".volta", "bin"),
			filepath.Join(home, ".fnm", "current", "bin"),
			filepath.Join(home, ".claude", "bin"),
		)
	}

	seen := make(map[string]bool)
	for _, p := range strings.Split(existing, ":") {
		seen[p] = true
	}
	var parts []string
	for _, p := range extra {
		if !seen[p] {
			seen[p] = true
			parts = append(parts, p)
		}
	}
	if existing != "" {
		parts = append(parts, existing)
	}
	return strings.Join(parts, ":")
}

// loginShell returns the path to the user's login shell.
func loginShell() string {
	if sh := os.Getenv("SHELL"); sh != "" {
		return sh
	}
	if runtime.GOOS == "darwin" {
		return "/bin/zsh"
	}
	return "/bin/bash"
}

// loginShellWhich runs `which <name>` inside a login interactive shell to
// resolve a binary using the user's full PATH (including nvm/fnm/volta init).
// name must be a simple binary name (no shell metacharacters).
func loginShellWhich(name string) string {
	// Reject anything that isn't a simple binary name to prevent injection.
	for _, c := range name {
		if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_') {
			return ""
		}
	}
	sh := loginShell()
	// L1 fix: removed -i (interactive) flag — login shell (-l) is sufficient for PATH
	out, err := exec.Command(sh, "-l", "-c", "which "+name).Output()
	if err != nil {
		return ""
	}
	p := strings.TrimSpace(string(out))
	if p == "" {
		return ""
	}
	if info, err := os.Stat(p); err == nil && !info.IsDir() {
		return p
	}
	return ""
}

// loginShellPATH gets the full PATH from a login interactive shell.
func loginShellPATH() string {
	sh := loginShell()
	out, err := exec.Command(sh, "-l", "-c", "echo $PATH").Output()
	if err != nil {
		return ""
	}
	p := strings.TrimSpace(string(out))
	if p == "" || p == os.Getenv("PATH") {
		return ""
	}
	return p
}
