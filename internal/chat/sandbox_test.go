package chat

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// fakeSandboxExec is a sandbox-exec stand-in: it appends its argv (one
// argument NUL-terminated, then a newline) to $FAKE_SANDBOX_ARGV when set and
// runs the command after "--" unconfined.
const fakeSandboxExec = `#!/bin/sh
if [ -n "$FAKE_SANDBOX_ARGV" ]; then
	for a in "$@"; do printf '%s\0' "$a"; done >> "$FAKE_SANDBOX_ARGV"
	echo >> "$FAKE_SANDBOX_ARGV"
fi
while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do shift; done
shift
exec "$@"
`

// testSandbox is a ChildSandbox over fakeSandboxExec for a home under the
// test's temp dir, for the tests that spawn a fake CLI in claude.ai mode.
func testSandbox(t *testing.T) *ChildSandbox {
	t.Helper()
	bin := filepath.Join(t.TempDir(), "sandbox-exec")
	require.NoError(t, os.WriteFile(bin, []byte(fakeSandboxExec), 0o700))
	s, err := NewChildSandboxAt(bin, []string{filepath.Join(t.TempDir(), "home")})
	require.NoError(t, err)
	return s
}

// The profile denies every protected folder of every home and the volume
// roots, and carries no home path itself: the homes are -D parameters.
func TestChildSandbox_ProfileCoversEveryHomeAndProtectedFolder(t *testing.T) {
	s := &ChildSandbox{exec: "/x/sandbox-exec", homes: []string{"/h/one", "/h/two \"q\""}}
	name, argv := s.command("/bin/claude", []string{"-p", "--verbose"})
	assert.Equal(t, "/x/sandbox-exec", name)
	require.Len(t, argv, 10)
	assert.Equal(t, []string{"-D", "H0=/h/one", "-D", "H1=/h/two \"q\""}, argv[:4])
	assert.Equal(t, "-p", argv[4])
	assert.Equal(t, []string{"--", "/bin/claude", "-p", "--verbose"}, argv[6:])

	profile := argv[5]
	assert.NotContains(t, profile, "/h/")
	assert.Contains(t, profile, "(allow default)")
	assert.Contains(t, profile, "(deny file-read* file-write*")
	for _, root := range protectedRoots {
		assert.Contains(t, profile, `(subpath "`+root+`")`)
	}
	for _, h := range []string{"H0", "H1"} {
		for _, d := range protectedHomeDirs {
			assert.Contains(t, profile, `(subpath (string-append (param "`+h+`") "/`+d+`"))`)
		}
	}
	for _, d := range []string{"Desktop", "Documents", "Downloads", "Library/Mobile Documents",
		"Library/CloudStorage", "Library/Containers", "Library/Group Containers", "Pictures"} {
		assert.Contains(t, protectedHomeDirs, d)
	}
}

// Homes are made absolute-only, symlink-resolved and deduplicated; a home on
// a volume the profile denies whole is refused, as is no home at all or a
// sandbox-exec that does not run.
func TestChildSandbox_Homes(t *testing.T) {
	bin := filepath.Join(t.TempDir(), "sandbox-exec")
	require.NoError(t, os.WriteFile(bin, []byte(fakeSandboxExec), 0o700))
	home := t.TempDir()
	link := filepath.Join(t.TempDir(), "link")
	require.NoError(t, os.Symlink(home, link))
	resolved, err := filepath.EvalSymlinks(home)
	require.NoError(t, err)

	s, err := NewChildSandboxAt(bin, []string{link, home + "/", "relative", ""})
	require.NoError(t, err)
	assert.Equal(t, []string{resolved}, s.homes)

	_, err = NewChildSandboxAt(bin, []string{"relative"})
	assert.Error(t, err)
	_, err = NewChildSandboxAt(bin, []string{"/Volumes/External/home"})
	assert.ErrorContains(t, err, "/Volumes")
	_, err = NewChildSandboxAt(filepath.Join(t.TempDir(), "missing"), []string{home})
	assert.ErrorContains(t, err, "does not run")
}

// CHAT-05 / TCC: the claude.ai-mode child can never touch a TCC-guarded
// folder. The CLI resolves and reads a model-chosen path (a Write target, an
// Artifact publish source it hashes) before it asks the gate, so the
// confinement is structural: the child only ever starts under the sandbox,
// an On session without one refuses to start, and the profile denies stat,
// read, write and symlink-following into the protected folders with EPERM —
// a sandbox denial never reaches TCC, so no privacy prompt appears.
func TestChat05_PublishNeverReadsOutsideThePublishDir(t *testing.T) {
	t.Run("an On session without a sandbox never starts the CLI", func(t *testing.T) {
		fx := gateFake(t)
		fx.opts.ClaudeAI.Sandbox = nil
		_, err := NewClaudeBackend(fx.opts).Start(t.Context())
		require.ErrorContains(t, err, "sandbox")
		_, statErr := os.Stat(fx.files.argv)
		assert.True(t, os.IsNotExist(statErr), "the CLI must not have run")
	})

	t.Run("an On session starts the CLI only through the sandbox", func(t *testing.T) {
		fx := gateFake(t)
		record := filepath.Join(t.TempDir(), "sandbox-argv")
		fx.opts.Env = append(fx.opts.Env, "FAKE_SANDBOX_ARGV="+record)
		startSession(t, NewClaudeBackend(fx.opts), nil)
		var b []byte
		require.Eventually(t, func() bool {
			b, _ = os.ReadFile(record)
			return strings.HasSuffix(string(b), "\x00\n")
		}, 5*time.Second, 10*time.Millisecond)
		argv := strings.Split(strings.TrimSuffix(string(b), "\x00\n"), "\x00")
		dash := indexOf(argv, "--")
		require.Positive(t, dash)
		assert.Equal(t, "-p", argv[dash-2])
		assert.Contains(t, argv[dash-1], "(deny file-read* file-write*")
		require.Less(t, dash+1, len(argv))
		assert.Equal(t, fx.opts.Binary, argv[dash+1])
	})

	t.Run("the CLI runs under the macOS sandbox", func(t *testing.T) {
		if runtime.GOOS != "darwin" {
			t.Skip("sandbox-exec is macOS only")
		}
		fx := gateFake(t)
		sandbox, err := NewChildSandboxAt(sandboxExecPath, []string{t.TempDir()})
		require.NoError(t, err)
		fx.opts.ClaudeAI.Sandbox = sandbox
		startSession(t, NewClaudeBackend(fx.opts), nil)
		require.Eventually(t, func() bool {
			_, err := os.Stat(fx.files.argv)
			return err == nil
		}, 5*time.Second, 10*time.Millisecond, "the CLI never started")
	})

	t.Run("the macOS sandbox denies every access to a protected folder", func(t *testing.T) {
		if runtime.GOOS != "darwin" {
			t.Skip("sandbox-exec is macOS only")
		}
		// A stand-in home under the test's temp dir: its Documents and
		// Desktop are not TCC-guarded, so a missed denial reads a canary
		// instead of raising a prompt.
		home, err := filepath.EvalSymlinks(t.TempDir())
		require.NoError(t, err)
		s, err := NewChildSandboxAt(sandboxExecPath, []string{home})
		require.NoError(t, err)
		open := filepath.Join(home, "open")
		for _, d := range []string{"Documents", "Desktop", "Library/Mobile Documents", "open"} {
			require.NoError(t, os.MkdirAll(filepath.Join(home, d), 0o700))
			require.NoError(t, os.WriteFile(filepath.Join(home, d, "canary.md"), []byte("SECRET-CANARY"), 0o600))
		}
		require.NoError(t, os.Symlink(filepath.Join(home, "Documents", "canary.md"), filepath.Join(open, "link.md")))

		run := func(script string) (string, error) {
			name, args := s.command("/bin/sh", []string{"-c", script})
			out, err := exec.Command(name, args...).CombinedOutput()
			return string(out), err
		}
		for _, script := range []string{
			`stat ` + shQuote(filepath.Join(home, "Documents", "canary.md")),
			`cat ` + shQuote(filepath.Join(home, "Desktop", "canary.md")),
			`cat ` + shQuote(filepath.Join(home, "Library/Mobile Documents", "canary.md")),
			`ls ` + shQuote(filepath.Join(home, "Documents")),
			`cat ` + shQuote(filepath.Join(open, "link.md")),
			`cat ` + shQuote("/System/Volumes/Data"+filepath.Join(home, "Documents", "canary.md")),
			`echo x > ` + shQuote(filepath.Join(home, "Desktop", "new.md")),
			`shasum -a 256 ` + shQuote(filepath.Join(home, "Documents", "canary.md")),
		} {
			out, err := run(script)
			assert.Error(t, err, "%s ran: %s", script, out)
			assert.Contains(t, out, "Operation not permitted", script)
			assert.NotContains(t, out, "SECRET-CANARY", script)
		}
		_, statErr := os.Stat(filepath.Join(home, "Desktop", "new.md"))
		assert.True(t, os.IsNotExist(statErr), "a write into Desktop went through")

		out, err := run(`cat ` + shQuote(filepath.Join(open, "canary.md")))
		require.NoError(t, err, out)
		assert.Equal(t, "SECRET-CANARY", out, "a folder outside the protected list stays readable")
	})
}

func shQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'" }
