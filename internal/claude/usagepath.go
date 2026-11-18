package claude

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
)

// usageShellBudget bounds one login-shell PATH discovery for the usage
// reader; a slower (or hung) shell is killed and retried on the next poll.
// usageShellRetry is how often a lookup miss may ask the shell again (an
// installer may have added a folder to the login profile).
const (
	usageShellBudget = 5 * time.Second
	usageShellRetry  = 5 * time.Minute
)

// usagePaths caches the login shell's PATH once a shell has answered.
// shell, fallback, inherited, wellKnown and now are seams for tests.
var usagePaths = &usagePathCache{
	shell:     func(ctx context.Context) (string, bool) { return loginShellPATHUntil(ctx, loginShell()) },
	fallback:  fallbackPATH,
	inherited: func() string { return os.Getenv("PATH") },
	wellKnown: wellKnownDirs,
	now:       time.Now,
}

type usagePathCache struct {
	shell     func(context.Context) (string, bool)
	fallback  func() string
	inherited func() string
	wellKnown func() []string
	now       func() time.Time

	mu    sync.Mutex
	path  string
	ok    bool
	ranAt time.Time
}

// loginPATH is the login shell's PATH, bounded by ctx and usageShellBudget.
// Only a nonempty answer is cached: a shell that failed, ran out of time or
// printed nothing is asked again next time. refresh re-asks a cached answer,
// at most once per usageShellRetry; a failed refresh keeps the cached one.
func (c *usagePathCache) loginPATH(ctx context.Context, refresh bool) string {
	c.mu.Lock()
	run := !refresh && !c.ok || refresh && c.now().Sub(c.ranAt) >= usageShellRetry
	cached := c.path
	c.mu.Unlock()
	if !run {
		return cached
	}
	ctx, cancel := context.WithTimeout(ctx, usageShellBudget)
	defer cancel()
	path, ok := c.shell(ctx)
	c.mu.Lock()
	defer c.mu.Unlock()
	c.ranAt = c.now()
	if ok && path != "" {
		c.path, c.ok = path, true
	}
	return c.path
}

// UsageCommand is the binary and environment for ReadUsage, resolved on
// every poll in FindBinary's order, so the poll runs the claude the AI calls
// run:
//   - a configured CLI (override naming a file) is used as is; the child's
//     PATH is its folder, the login shell's PATH (bounded, cached) and the
//     well-known tool folders, so a `#!/usr/bin/env node` CLI finds a node
//     only the login profile adds;
//   - else claude on the inherited PATH, with no shell started;
//   - else the login shell's PATH (bounded by ctx and usageShellBudget,
//     cached once answered), then wellKnownDirs; after a miss the shell is
//     asked again at most once per usageShellRetry, so a CLI installed later
//     is found on a later poll.
//
// Not found is a bare "claude", which ReadUsage reports as cli_missing.
func UsageCommand(ctx context.Context, override string) (bin string, env []string) {
	return usagePaths.command(ctx, override)
}

func (c *usagePathCache) command(ctx context.Context, override string) (string, []string) {
	if override != "" {
		if info, err := os.Stat(override); err == nil && !info.IsDir() {
			login := c.loginPATH(ctx, false)
			return override, withPATH(mergePATH(filepath.Dir(override), login, c.fallback()))
		}
	}
	if bin := lookPathIn("claude", c.inherited()); bin != "" {
		return bin, withPATH(mergePATH(filepath.Dir(bin), c.fallback()))
	}
	wellKnown := strings.Join(c.wellKnown(), string(filepath.ListSeparator))
	login := c.loginPATH(ctx, false)
	bin := lookPathIn("claude", mergePATH(login, wellKnown))
	if bin == "" {
		if fresh := c.loginPATH(ctx, true); fresh != login {
			login = fresh
			bin = lookPathIn("claude", mergePATH(login, wellKnown))
		}
	}
	if bin == "" {
		return "claude", withPATH(mergePATH(login, c.fallback()))
	}
	return bin, withPATH(mergePATH(filepath.Dir(bin), login, c.fallback()))
}

// withPATH is the daemon's environment with PATH replaced (the last entry of
// a key wins for exec).
func withPATH(path string) []string { return append(os.Environ(), "PATH="+path) }

// lookPathIn finds an executable regular file name in the absolute folders
// of path; "" when there is none.
func lookPathIn(name, path string) string {
	for _, dir := range filepath.SplitList(path) {
		if !filepath.IsAbs(dir) {
			continue
		}
		p := filepath.Join(dir, name)
		if info, err := os.Stat(p); err == nil && info.Mode().IsRegular() && info.Mode().Perm()&0o111 != 0 {
			return p
		}
	}
	return ""
}

// usagePATHMarker separates what the shell's startup files print from the
// PATH value.
const usagePATHMarker = "__WATCHTOWER_PATH__"

// loginShellPATHUntil is the login shell's PATH, bounded by ctx: when ctx
// ends the shell's process group is killed and ok is false. Only the value
// after the marker line counts, so a profile banner cannot pose as PATH.
func loginShellPATHUntil(ctx context.Context, shell string) (string, bool) {
	cmd := exec.CommandContext(ctx, shell, "-l", "-c", `printf '\n`+usagePATHMarker+`\n%s\n' "$PATH"`)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
	cmd.WaitDelay = time.Second
	out, err := cmd.Output()
	if err != nil {
		return "", false
	}
	return parseUsagePATH(out)
}

// parseUsagePATH reads the line after the last marker line; false without
// a marker or with an empty value.
func parseUsagePATH(out []byte) (string, bool) {
	i := strings.LastIndex(string(out), "\n"+usagePATHMarker+"\n")
	if i < 0 {
		return "", false
	}
	value, _, _ := strings.Cut(string(out[i+len(usagePATHMarker)+2:]), "\n")
	value = strings.TrimSpace(value)
	return value, value != ""
}
