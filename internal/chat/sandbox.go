package chat

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"runtime"
	"slices"
	"strconv"
	"strings"
)

// sandboxExecPath is macOS's sandbox-exec.
const sandboxExecPath = "/usr/bin/sandbox-exec"

// protectedHomeDirs are the folders under a home directory that macOS guards
// with TCC (Desktop, Documents, Downloads, iCloud Drive, cloud storage
// providers, other apps' containers, Photos, Contacts, Calendars, Mail…),
// or with Full Disk Access. An access to one from a process Watchtower
// started can raise a privacy prompt in Watchtower's name.
var protectedHomeDirs = []string{
	"Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music",
	"Library/Mobile Documents", "Library/CloudStorage",
	"Library/Containers", "Library/Group Containers", "Library/Daemon Containers",
	"Library/Application Support/AddressBook", "Library/Application Support/CallHistoryDB",
	"Library/Application Support/CallHistoryTransactions", "Library/Application Support/com.apple.TCC",
	"Library/Application Support/FileProvider", "Library/Application Support/Knowledge",
	"Library/Calendars", "Library/Reminders", "Library/Mail", "Library/Messages", "Library/Safari",
	"Library/Cookies", "Library/HomeKit", "Library/Photos", "Library/Biome", "Library/Suggestions",
	"Library/IdentityServices", "Library/Accounts", "Library/PersonalizationPortrait",
	"Library/Metadata/CoreSpotlight",
}

// protectedRoots are the TCC-guarded places outside any home: removable and
// network volumes.
var protectedRoots = []string{"/Volumes", "/Network"}

// ChildSandbox runs the claude.ai-mode child under a macOS sandbox profile
// that denies every file read (stat included) and write in the TCC-guarded
// folders. The CLI touches a model-chosen path before it sends can_use_tool
// (it resolves symlinks for Read and Write, and reads and hashes an Artifact
// publish source to pin it), so the permission gate alone cannot keep a path
// in ~/Documents unread. A sandbox denial is decided before TCC is consulted:
// the access fails with EPERM and no privacy prompt appears. The profile is
// inherited by everything the child starts (MCP servers included).
type ChildSandbox struct {
	exec  string   // sandbox-exec
	homes []string // the home directories whose protected folders are denied
}

// NewChildSandbox is the sandbox for this account: the home from $HOME and
// the account's own (they differ when HOME is overridden), symlinks
// resolved. It fails on a system without sandbox-exec, or when the profile
// does not run, so the caller keeps claude.ai mode off instead of starting
// an unguarded child.
func NewChildSandbox() (*ChildSandbox, error) {
	if runtime.GOOS != "darwin" {
		return nil, errors.New("the file sandbox needs macOS")
	}
	var homes []string
	if h, err := os.UserHomeDir(); err == nil {
		homes = append(homes, h)
	}
	if u, err := user.Current(); err == nil && u.HomeDir != "" {
		homes = append(homes, u.HomeDir)
	}
	return NewChildSandboxAt(sandboxExecPath, homes)
}

// NewChildSandboxAt is NewChildSandbox with an explicit sandbox-exec binary
// and home directories (tests pass a stand-in). It checks the profile runs
// by starting /usr/bin/true under it.
func NewChildSandboxAt(execPath string, homes []string) (*ChildSandbox, error) {
	s := &ChildSandbox{exec: execPath}
	for _, h := range homes {
		if !filepath.IsAbs(h) {
			continue
		}
		h = filepath.Clean(h)
		if resolved, err := filepath.EvalSymlinks(h); err == nil {
			h = resolved
		}
		for _, root := range protectedRoots {
			if h == root || strings.HasPrefix(h, root+"/") {
				return nil, fmt.Errorf("the file sandbox cannot cover a home on %s (%s)", root, h)
			}
		}
		if !slices.Contains(s.homes, h) {
			s.homes = append(s.homes, h)
		}
	}
	if len(s.homes) == 0 {
		return nil, errors.New("the file sandbox needs the home directory")
	}
	name, args := s.command("/usr/bin/true", nil)
	if out, err := exec.Command(name, args...).CombinedOutput(); err != nil {
		return nil, fmt.Errorf("the file sandbox does not run: %w: %s", err, strings.TrimSpace(string(out)))
	}
	return s, nil
}

// command wraps bin and args in the sandbox: the program to start and its
// argv. Home paths travel as -D parameters, never inside the profile text.
func (s *ChildSandbox) command(bin string, args []string) (string, []string) {
	argv := make([]string, 0, 2*len(s.homes)+5+len(args))
	for i, h := range s.homes {
		argv = append(argv, "-D", "H"+strconv.Itoa(i)+"="+h)
	}
	argv = append(argv, "-p", s.profile(), "--", bin)
	return s.exec, append(argv, args...)
}

// profile is the SBPL text: everything allowed except file reads and writes
// under protectedRoots and each home's protectedHomeDirs.
func (s *ChildSandbox) profile() string {
	var b strings.Builder
	b.WriteString("(version 1)\n(allow default)\n(deny file-read* file-write*")
	for _, root := range protectedRoots {
		fmt.Fprintf(&b, "\n  (subpath %q)", root)
	}
	for i := range s.homes {
		for _, d := range protectedHomeDirs {
			fmt.Fprintf(&b, "\n  (subpath (string-append (param \"H%d\") %q))", i, "/"+d)
		}
	}
	b.WriteString(")\n")
	return b.String()
}
