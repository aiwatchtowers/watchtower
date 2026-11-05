package codex

import (
	"bufio"
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// featuresSnapshot is the pinned list of codex feature flags with
// Watchtower's decision for each (see its header).
const featuresSnapshot = "testdata/codex_features.txt"

// readFeaturesSnapshot returns the snapshot's decision per feature name.
func readFeaturesSnapshot(t *testing.T) map[string]string {
	t.Helper()
	raw, err := os.ReadFile(featuresSnapshot)
	require.NoError(t, err)
	out := map[string]string{}
	for line := range strings.SplitSeq(string(raw), "\n") {
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		f := strings.Fields(line)
		require.Len(t, f, 2, "snapshot line %q", line)
		out[f[0]] = f[1]
	}
	return out
}

// TestDisabledFeatures_MatchSnapshot: every feature in the snapshot has a
// decision, disabledFeatures is exactly its "off" and "batch" set and
// toolRunFeatures its "batch" set — a flag added to one side only fails here.
func TestDisabledFeatures_MatchSnapshot(t *testing.T) {
	snap := readFeaturesSnapshot(t)
	var off, batch []string
	for name, decision := range snap {
		switch decision {
		case "off":
			off = append(off, name)
		case "batch":
			off = append(off, name)
			batch = append(batch, name)
		case "keep":
		default:
			t.Errorf("feature %q has no decision (%q): mark it off, batch or keep in %s", name, decision, featuresSnapshot)
		}
	}
	assert.ElementsMatch(t, off, disabledFeatures)
	assert.ElementsMatch(t, batch, toolRunFeatures)
	assert.Len(t, slices.Compact(slices.Sorted(slices.Values(disabledFeatures))), len(disabledFeatures), "no duplicates")
}

// hasConfig reports whether args carry `-c value`.
func hasConfig(args []string, value string) bool {
	for i := 0; i+1 < len(args); i++ {
		if args[i] == "-c" && args[i+1] == value {
			return true
		}
	}
	return false
}

// Every codex run Watchtower launches itself — batch, chat session, Discuss
// chat with Quick Connections, code question, spec reviewer, automation
// agent() — turns off the same feature set, so the owner's hooks, skills,
// subagents and other default-on extras never run inside it. Runs with tools
// (every Client run) leave toolRunFeatures alone, and a read-folder run turns
// the shell back on (it reads files through it).
func TestDisabledFeatures_EveryRunTurnsThemOff(t *testing.T) {
	genArgs, _ := genArgsT(t, "m", "sys", "hello")
	img := filepath.Join(t.TempDir(), "i.png")
	require.NoError(t, os.WriteFile(img, []byte("x"), 0o600))
	imgArgs, _, imgPrompt, err := buildImageArgs("codex", "m", "sys", "u", img, t.TempDir())
	require.NoError(t, err)
	t.Cleanup(func() { _ = os.Remove(imgPrompt) })

	plain := NewClient("m", "", "codex")
	session := NewClient("m", "/data/wt.db", "codex")
	session.SetMCPArgs([]string{"--chat", "--surface", "main"})
	readFolder := NewClient("m", "/data/wt.db", "codex")
	readFolder.SetReadFolder(t.TempDir())
	specReview := NewClient("m", "", "codex")
	specReview.SetReadFolder(t.TempDir())
	specReview.SetNoMCPServers()
	agent := NewClient("m", "/data/wt.db", "codex")
	agent.SetChildEnv([]string{"CODEX_HOME=" + t.TempDir()})
	agent.SetServersFromHome()

	runs := map[string][]string{
		"batch":       genArgs,
		"image":       imgArgs,
		"plain":       plain.ArgsForTest("sys", "hello"),
		"session":     session.ArgsForTest("sys", "hello"),
		"read folder": readFolder.ArgsForTest("sys", "hello"),
		"spec review": specReview.ArgsForTest("sys", "hello"),
		"agent":       agent.ArgsForTest("sys", "hello"),
	}
	for name, args := range runs {
		require.NotEmpty(t, args, name)
		readsFolder := name == "read folder" || name == "spec review"
		hasTools := name != "batch" && name != "image"
		for _, f := range disabledFeatures {
			if hasTools && slices.Contains(toolRunFeatures, f) {
				assert.False(t, hasConfig(args, "features."+f+"=false"), "%s: features.%s is needed by tool calls", name, f)
				continue
			}
			if f == "shell_tool" && readsFolder {
				assert.True(t, hasConfig(args, "features.shell_tool=true"), "%s: shell on", name)
				continue
			}
			assert.True(t, hasConfig(args, "features."+f+"=false"), "%s: features.%s=false missing", name, f)
		}
	}
}

// liveFeaturesEnv opts into TestDisabledFeatures_LiveCLI ("check" or
// "update"); see scripts/check-codex-features.sh.
const liveFeaturesEnv = "WATCHTOWER_CHECK_CODEX_FEATURES"

// TestDisabledFeatures_LiveCLI compares the installed codex CLI's feature
// flags with the snapshot (opt-in, never in CI): every flag it lists that is
// not "removed" must be in the snapshot; "update" adds the missing ones as
// "undecided", which TestDisabledFeatures_MatchSnapshot then fails until each
// is marked off or keep. `codex features list` reads only local config: no
// model call, no network.
func TestDisabledFeatures_LiveCLI(t *testing.T) {
	mode := os.Getenv(liveFeaturesEnv)
	if mode == "" {
		t.Skipf("set %s=check (or update) to compare against the installed codex CLI", liveFeaturesEnv)
	}
	bin := FindBinary("")
	require.NotEmpty(t, bin, "codex CLI not found")
	listed := liveFeatureNames(t, bin)
	require.NotEmpty(t, listed, "codex features list printed nothing")
	snap := readFeaturesSnapshot(t)
	var missing []string
	for _, name := range listed {
		if _, ok := snap[name]; !ok {
			missing = append(missing, name)
		}
	}
	if len(missing) > 0 && mode == "update" {
		addUndecidedFeatures(t, missing)
		t.Logf("added to %s as undecided: %v — mark each off/batch (and add it to disabledFeatures) or keep", featuresSnapshot, missing)
		return
	}
	assert.Empty(t, missing, "codex features missing from %s (rerun with update, then decide each)", featuresSnapshot)
}

// liveFeatureNames runs `codex features list` and returns the names of the
// flags not marked removed. The child runs in its own process group, killed
// and reaped on every path.
func liveFeatureNames(t *testing.T, bin string) []string {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, bin, "features", "list")
	cmd.Dir = t.TempDir()
	cmd.Env = append(os.Environ(), "PATH="+RichPATH())
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
	out, err := cmd.Output()
	if cmd.Process != nil {
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
	}
	require.NoError(t, err, "codex features list")
	var names []string
	sc := bufio.NewScanner(strings.NewReader(string(out)))
	for sc.Scan() {
		f := strings.Fields(sc.Text())
		if len(f) >= 2 && f[1] != "removed" {
			names = append(names, f[0])
		}
	}
	return names
}

// addUndecidedFeatures adds names to the snapshot as "undecided", keeping its
// header and its lines sorted.
func addUndecidedFeatures(t *testing.T, names []string) {
	t.Helper()
	raw, err := os.ReadFile(featuresSnapshot)
	require.NoError(t, err)
	var header, lines []string
	for line := range strings.SplitSeq(strings.TrimRight(string(raw), "\n"), "\n") {
		if strings.HasPrefix(line, "#") {
			header = append(header, line)
		} else if line != "" {
			lines = append(lines, line)
		}
	}
	for _, n := range names {
		lines = append(lines, n+" undecided")
	}
	slices.Sort(lines)
	out := strings.Join(append(header, lines...), "\n") + "\n"
	require.NoError(t, os.WriteFile(featuresSnapshot, []byte(out), 0o644))
}
