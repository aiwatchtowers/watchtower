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
const usageShellBudget = 5 * time.Second

// usagePaths caches the login shell's PATH once a shell has answered.
// shell and fallback are seams for tests.
var usagePaths = &usagePathCache{
	shell:    func(ctx context.Context) (string, bool) { return loginShellPATHUntil(ctx, loginShell()) },
	fallback: fallbackPATH,
}

type usagePathCache struct {
	shell    func(context.Context) (string, bool)
	fallback func() string

	mu   sync.Mutex
	path string
	ok   bool
}

// loginPATH is the login shell's PATH, bounded by ctx and usageShellBudget.
// Only an answer is cached: a shell that failed or ran out of time is asked
// again next time.
func (c *usagePathCache) loginPATH(ctx context.Context) string {
	c.mu.Lock()
	if c.ok {
		defer c.mu.Unlock()
		return c.path
	}
	c.mu.Unlock()
	ctx, cancel := context.WithTimeout(ctx, usageShellBudget)
	defer cancel()
	path, ok := c.shell(ctx)
	if ok {
		c.mu.Lock()
		c.path, c.ok = path, true
		c.mu.Unlock()
	}
	return path
}

// UsageCommand is the binary and environment for ReadUsage, resolved on
// every poll. A configured CLI (override naming a file) runs no shell: its
// PATH is its own folder plus the well-known tool folders. Otherwise claude
// is looked up in the login shell's PATH (bounded by ctx, see
// usageShellBudget) plus the well-known folders, so a CLI installed after the
// daemon started is found on the next poll; not found is a bare "claude",
// which ReadUsage reports as cli_missing.
func UsageCommand(ctx context.Context, override string) (bin string, env []string) {
	return usagePaths.command(ctx, override)
}

func (c *usagePathCache) command(ctx context.Context, override string) (string, []string) {
	if override != "" {
		if info, err := os.Stat(override); err == nil && !info.IsDir() {
			return override, withPATH(mergePATH(filepath.Dir(override), c.fallback()))
		}
	}
	path := mergePATH(c.loginPATH(ctx), c.fallback())
	bin := "claude"
	if p := lookPathIn("claude", path); p != "" {
		bin = p
	}
	return bin, withPATH(path)
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

// loginShellPATHUntil is the login shell's `echo $PATH`, bounded by ctx:
// when ctx ends the shell's process group is killed and ok is false.
func loginShellPATHUntil(ctx context.Context, shell string) (string, bool) {
	cmd := exec.CommandContext(ctx, shell, "-l", "-c", "echo $PATH")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
	cmd.WaitDelay = time.Second
	out, err := cmd.Output()
	if err != nil {
		return "", false
	}
	return strings.TrimSpace(string(out)), true
}
