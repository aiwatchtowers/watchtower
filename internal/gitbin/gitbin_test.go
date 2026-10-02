package gitbin

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

// fakeDarwin is a darwin Locator whose filesystem holds exactly the
// executables listed; the xcode-select link points at link ("" = absent).
func fakeDarwin(env map[string]string, link string, executables ...string) Locator {
	set := map[string]bool{}
	for _, e := range executables {
		set[e] = true
	}
	return Locator{
		GOOS:   "darwin",
		Getenv: func(k string) string { return env[k] },
		Readlink: func(string) (string, error) {
			if link == "" {
				return "", os.ErrNotExist
			}
			return link, nil
		},
		IsExecutable: func(p string) bool { return set[p] },
		LookPath: func(string) (string, error) {
			panic("darwin must never look git up on PATH")
		},
	}
}

func TestLocate_DarwinOrder(t *testing.T) {
	all := []string{
		"/opt/dev/usr/bin/git",
		"/Applications/Xcode-beta.app/Contents/Developer/usr/bin/git",
		"/Library/Developer/CommandLineTools/usr/bin/git",
		"/Applications/Xcode.app/Contents/Developer/usr/bin/git",
		"/opt/homebrew/bin/git",
		"/usr/local/bin/git",
		shim,
	}
	cases := []struct {
		name  string
		env   map[string]string
		link  string
		exist []string
		want  string
	}{
		{"DEVELOPER_DIR wins", map[string]string{"DEVELOPER_DIR": "/opt/dev"}, "/Applications/Xcode-beta.app/Contents/Developer", all, "/opt/dev/usr/bin/git"},
		{"xcode-select link target", nil, "/Applications/Xcode-beta.app/Contents/Developer", all, "/Applications/Xcode-beta.app/Contents/Developer/usr/bin/git"},
		{"Command Line Tools", nil, "", all, "/Library/Developer/CommandLineTools/usr/bin/git"},
		{"Xcode.app default", nil, "", all[3:], "/Applications/Xcode.app/Contents/Developer/usr/bin/git"},
		{"Homebrew arm64", nil, "", all[4:], "/opt/homebrew/bin/git"},
		{"Homebrew Intel", nil, "", all[5:], "/usr/local/bin/git"},
		{"a DEVELOPER_DIR without git falls through", map[string]string{"DEVELOPER_DIR": "/nowhere"}, "", all[4:], "/opt/homebrew/bin/git"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, ok := fakeDarwin(tc.env, tc.link, tc.exist...).Locate()
			if !ok || got != tc.want {
				t.Fatalf("Locate() = %q, %v; want %q", got, ok, tc.want)
			}
		})
	}
}

// The shim is never returned, whichever way a candidate spells it.
func TestLocate_NeverTheShim(t *testing.T) {
	for _, l := range []Locator{
		fakeDarwin(nil, "", shim),
		fakeDarwin(map[string]string{"DEVELOPER_DIR": "/"}, "", shim),
		fakeDarwin(map[string]string{"DEVELOPER_DIR": "/usr/../"}, "/", shim),
	} {
		if got, ok := l.Locate(); ok || got != "" {
			t.Fatalf("Locate() = %q, %v; the shim must never be returned", got, ok)
		}
	}
}

func TestLocate_NoneFound(t *testing.T) {
	if got, ok := fakeDarwin(nil, "").Locate(); ok || got != "" {
		t.Fatalf("Locate() = %q, %v; want none", got, ok)
	}
}

func TestLocate_RelativeLinkTargetResolvesAgainstTheLinkDir(t *testing.T) {
	got, ok := fakeDarwin(nil, "../dev", "/var/dev/usr/bin/git").Locate()
	if !ok || got != "/var/dev/usr/bin/git" {
		t.Fatalf("Locate() = %q, %v", got, ok)
	}
}

func TestLocate_OtherOSesUseLookPath(t *testing.T) {
	l := Locator{
		GOOS:         "linux",
		Getenv:       func(string) string { panic("no darwin lookup on linux") },
		IsExecutable: func(string) bool { panic("no darwin lookup on linux") },
		LookPath:     func(string) (string, error) { return "/usr/bin/git", nil },
	}
	if got, ok := l.Locate(); !ok || got != "/usr/bin/git" {
		t.Fatalf("Locate() = %q, %v", got, ok)
	}
	l.LookPath = func(string) (string, error) { return "", errors.New("not found") }
	if _, ok := l.Locate(); ok {
		t.Fatal("a failed PATH lookup must report none")
	}
}

func TestIsExecutable(t *testing.T) {
	dir := t.TempDir()
	exe := filepath.Join(dir, "git")
	plain := filepath.Join(dir, "plain")
	if err := os.WriteFile(exe, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(plain, []byte(""), 0o644); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dir, "link")
	if err := os.Symlink(exe, link); err != nil {
		t.Fatal(err)
	}
	for path, want := range map[string]bool{exe: true, link: true, plain: false, dir: false, filepath.Join(dir, "missing"): false} {
		if got := isExecutable(path); got != want {
			t.Errorf("isExecutable(%s) = %v, want %v", filepath.Base(path), got, want)
		}
	}
}

func TestInsideRepository(t *testing.T) {
	root := t.TempDir()
	repo := filepath.Join(root, "repo")
	sub := filepath.Join(repo, "a", "b")
	linked := filepath.Join(root, "linked")
	plain := filepath.Join(root, "plain")
	for _, d := range []string{filepath.Join(repo, ".git"), sub, linked, plain} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(linked, ".git"), []byte("gitdir: ../repo/.git/worktrees/linked\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	for dir, want := range map[string]bool{repo: true, sub: true, linked: true, plain: false} {
		if got := InsideRepository(dir); got != want {
			t.Errorf("InsideRepository(%s) = %v, want %v", filepath.Base(dir), got, want)
		}
	}
}
