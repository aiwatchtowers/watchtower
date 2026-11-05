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

// snapshotFeature is one snapshot line: Watchtower's decision and the
// default the CLI reported when the line was reviewed.
type snapshotFeature struct{ decision, enabled string }

// readFeaturesSnapshot returns the snapshot's lines by feature name.
func readFeaturesSnapshot(t *testing.T) map[string]snapshotFeature {
	t.Helper()
	raw, err := os.ReadFile(featuresSnapshot)
	require.NoError(t, err)
	out := map[string]snapshotFeature{}
	for line := range strings.SplitSeq(string(raw), "\n") {
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		f := strings.Fields(line)
		require.Len(t, f, 3, "snapshot line %q", line)
		out[f[0]] = snapshotFeature{decision: f[1], enabled: f[2]}
	}
	return out
}

// TestDisabledFeatures_MatchSnapshot: every feature in the snapshot has a
// decision, disabledFeatures is exactly its "off" and "batch" set and
// toolRunFeatures its "batch" set — a flag added to one side only fails here.
func TestDisabledFeatures_MatchSnapshot(t *testing.T) {
	snap := readFeaturesSnapshot(t)
	var off, batch []string
	for name, f := range snap {
		switch f.decision {
		case "off":
			off = append(off, name)
		case "batch":
			off = append(off, name)
			batch = append(batch, name)
		case "keep":
		default:
			t.Errorf("feature %q has no decision (%q): mark it off, batch or keep in %s", name, f.decision, featuresSnapshot)
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
		assert.True(t, hasConfig(args, hideSkillListArg), "%s: the owner's skill list must stay out of the context", name)
		readsFolder := name == "read folder" || name == "spec review"
		hasTools := name != "batch" && name != "image"
		for _, f := range disabledFeatures {
			if hasTools && slices.Contains(toolRunFeatures, f) {
				assert.False(t, hasConfig(args, "features."+f+"=false"), "%s: features.%s is needed by tool calls", name, f)
				continue
			}
			if f == "shell_tool" && readsFolder {
				assert.True(t, hasConfig(args, "features.shell_tool=true"), "%s: shell on", name)
				assert.False(t, hasConfig(args, "features.shell_tool=false"), "%s: no shell_tool=false beside it", name)
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
// flags with the snapshot (opt-in, never in CI). It fails on a flag the CLI
// lists (not "removed") that the snapshot lacks, and on a "keep" flag whose
// default differs from the pinned one (a release turning a flag on by
// default is the case the deny list must not miss). "update" rewrites such
// lines as "undecided" with the CLI's default, which
// TestDisabledFeatures_MatchSnapshot then fails until each is marked off,
// batch or keep. `codex features list` reads only local config: no model
// call, no network.
func TestDisabledFeatures_LiveCLI(t *testing.T) {
	mode := os.Getenv(liveFeaturesEnv)
	if mode == "" {
		t.Skipf("set %s=check (or update) to compare against the installed codex CLI", liveFeaturesEnv)
	}
	bin := FindBinary("")
	require.NotEmpty(t, bin, "codex CLI not found")
	listed := liveFeatureDefaults(t, bin)
	require.NotEmpty(t, listed, "codex features list printed nothing")
	snap := readFeaturesSnapshot(t)
	changed := map[string]string{} // name → the CLI's default
	for name, enabled := range listed {
		f, ok := snap[name]
		if !ok || (f.decision == "keep" && f.enabled != enabled) {
			changed[name] = enabled
		}
	}
	if len(changed) > 0 && mode == "update" {
		markUndecided(t, changed)
		t.Logf("marked undecided in %s: %v — mark each off/batch (and add it to disabledFeatures) or keep", featuresSnapshot, changed)
		return
	}
	assert.Empty(t, changed, "codex flags new to %s or kept with a changed default (rerun with update, then decide each)", featuresSnapshot)
}

// liveFeatureDefaults runs `codex features list` and returns the default
// ("true"/"false") of each flag not marked removed. The child runs in its
// own process group, killed and reaped on every path.
func liveFeatureDefaults(t *testing.T, bin string) map[string]string {
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
	flags := map[string]string{}
	sc := bufio.NewScanner(strings.NewReader(string(out)))
	for sc.Scan() {
		f := strings.Fields(sc.Text())
		if len(f) >= 3 && f[len(f)-2] != "removed" {
			flags[f[0]] = f[len(f)-1]
		}
	}
	return flags
}

// markUndecided writes each name as "<name> undecided <default>", replacing
// its line if there is one, keeping the header and the lines sorted.
func markUndecided(t *testing.T, flags map[string]string) {
	t.Helper()
	raw, err := os.ReadFile(featuresSnapshot)
	require.NoError(t, err)
	var header, lines []string
	for line := range strings.SplitSeq(strings.TrimRight(string(raw), "\n"), "\n") {
		switch {
		case strings.HasPrefix(line, "#"):
			header = append(header, line)
		case line == "":
		default:
			if _, ok := flags[strings.Fields(line)[0]]; !ok {
				lines = append(lines, line)
			}
		}
	}
	for name, enabled := range flags {
		lines = append(lines, name+" undecided "+enabled)
	}
	slices.Sort(lines)
	out := strings.Join(append(header, lines...), "\n") + "\n"
	require.NoError(t, os.WriteFile(featuresSnapshot, []byte(out), 0o644))
}

// TestDisabledFeatures_LiveSkillListHidden checks with the installed codex
// CLI (opt-in with the feature check, never in CI) that a run's flags keep
// the owner's skill list out of the model's context: `codex debug
// prompt-input` (local, no model call) renders the prompt of a folder whose
// home, CODEX_HOME and repository each hold a probe skill, once without and
// once with the production `-c` flags of a tool run and a read-folder run.
func TestDisabledFeatures_LiveSkillListHidden(t *testing.T) {
	if os.Getenv(liveFeaturesEnv) == "" {
		t.Skipf("set %s=check to run against the installed codex CLI", liveFeaturesEnv)
	}
	bin := FindBinary("")
	require.NotEmpty(t, bin, "codex CLI not found")
	home, codexHome, repo := t.TempDir(), t.TempDir(), t.TempDir()
	probes := map[string]string{
		"probe-home-skill-wt":      filepath.Join(home, ".agents", "skills"),
		"probe-codexhome-skill-wt": filepath.Join(codexHome, "skills"),
		"probe-repo-skill-wt":      filepath.Join(repo, ".agents", "skills"),
	}
	for name, root := range probes {
		dir := filepath.Join(root, name)
		require.NoError(t, os.MkdirAll(dir, 0o700))
		body := "---\nname: " + name + "\ndescription: Probe skill " + name + ".\n---\nProbe.\n"
		require.NoError(t, os.WriteFile(filepath.Join(dir, "SKILL.md"), []byte(body), 0o600))
	}
	require.NoError(t, os.Mkdir(filepath.Join(repo, ".git"), 0o700))
	env := append(os.Environ(), "HOME="+home, "CODEX_HOME="+codexHome, "PATH="+RichPATH())

	render := func(configs []string) string {
		args := append([]string{"debug", "prompt-input"}, configs...)
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		cmd := exec.CommandContext(ctx, bin, append(args, "hi")...)
		cmd.Dir, cmd.Env = repo, env
		cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
		cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
		out, err := cmd.Output()
		if cmd.Process != nil {
			_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		}
		require.NoError(t, err, "codex debug prompt-input")
		return string(out)
	}
	// Only the -c pairs: prompt-input takes no exec flags.
	configsOf := func(args []string) []string {
		var out []string
		for i := 0; i+1 < len(args); i++ {
			if args[i] == "-c" {
				out = append(out, "-c", args[i+1])
			}
		}
		return out
	}

	bare := render(nil)
	for name := range probes {
		require.Contains(t, bare, name, "the probe must be discovered without the flags, or the check proves nothing")
	}
	tools := NewClient("m", "", "codex")
	readFolder := NewClient("m", "", "codex")
	readFolder.SetReadFolder(repo)
	for run, args := range map[string][]string{
		"tools":       tools.execArgs(),
		"read folder": readFolder.execArgs(),
	} {
		got := render(configsOf(args))
		for name := range probes {
			assert.NotContains(t, got, name, "%s run: skill %s reached the context", run, name)
		}
	}
}
