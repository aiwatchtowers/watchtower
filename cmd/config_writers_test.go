package cmd

import (
	"bytes"
	"fmt"
	"go/ast"
	"go/parser"
	"go/printer"
	"go/token"
	"log"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"syscall"
	"testing"

	"github.com/spf13/cobra"
	"github.com/spf13/viper"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
)

// configWriterFuncs are the only functions allowed to write config.yaml
// bytes. Each takes a *config.WriteLock and refuses a path it does not cover
// (Decision 7 of the background-AI-consent plan, #1886).
var configWriterFuncs = map[string]bool{
	"writeConfigAtomic":                true,
	"writeConfigFile":                  true,
	"writeFeatureMigrationConfigBytes": true,
}

// viperWriteMethods write a viper's whole config to disk.
var viperWriteMethods = map[string]bool{
	"WriteConfig": true, "WriteConfigAs": true, "SafeWriteConfig": true,
	"SafeWriteConfigAs": true, "WriteConfigTo": true,
}

// osWriteFuncs replace or create a file by path.
var osWriteFuncs = map[string]bool{"WriteFile": true, "Rename": true, "Create": true, "OpenFile": true}

// configPathArg matches an argument that names a config.yaml path.
// Deliberately broad: a false hit is cheap to see, a missed writer is not.
var configPathArg = regexp.MustCompile(`(?i)\b(configPath|flagConfig|cfgPath|configFile)\b|config\.ya?ml`)

type configWriteCall struct {
	where, fn, call string
}

// scanConfigWrites lists every call in file that writes config bytes: a viper
// write method anywhere, or an os write whose arguments name a config path.
func scanConfigWrites(fset *token.FileSet, file *ast.File) []configWriteCall {
	var out []configWriteCall
	render := func(e ast.Expr) string {
		var b bytes.Buffer
		_ = printer.Fprint(&b, fset, e)
		return b.String()
	}
	visit := func(fn string, root ast.Node) {
		ast.Inspect(root, func(n ast.Node) bool {
			call, ok := n.(*ast.CallExpr)
			if !ok {
				return true
			}
			sel, ok := call.Fun.(*ast.SelectorExpr)
			if !ok {
				return true
			}
			hit := viperWriteMethods[sel.Sel.Name]
			if pkg, isIdent := sel.X.(*ast.Ident); isIdent && pkg.Name == "os" && osWriteFuncs[sel.Sel.Name] {
				for _, arg := range call.Args {
					// <config>.lock is the lock file, not the config.
					if text := render(arg); configPathArg.MatchString(text) && !strings.HasSuffix(text, `".lock"`) {
						hit = true
					}
				}
			}
			if hit {
				out = append(out, configWriteCall{
					where: fset.Position(call.Pos()).String(),
					fn:    fn,
					call:  render(call.Fun),
				})
			}
			return true
		})
	}
	for _, decl := range file.Decls {
		if fd, ok := decl.(*ast.FuncDecl); ok {
			visit(fd.Name.Name, fd)
			continue
		}
		visit("", decl) // package-level var initializers
	}
	return out
}

func TestConfigWriters_OnlyThroughWriteLock(t *testing.T) {
	fset := token.NewFileSet()
	var calls []configWriteCall
	for _, dir := range []string{".", filepath.Join("..", "internal", "config")} {
		paths, err := filepath.Glob(filepath.Join(dir, "*.go"))
		require.NoError(t, err)
		for _, p := range paths {
			if strings.HasSuffix(p, "_test.go") {
				continue
			}
			file, err := parser.ParseFile(fset, p, nil, 0)
			require.NoError(t, err)
			calls = append(calls, scanConfigWrites(fset, file)...)
		}
	}

	var offenders []string
	seen := map[string]bool{}
	for _, c := range calls {
		if !configWriterFuncs[c.fn] {
			offenders = append(offenders, fmt.Sprintf("%s: %s in %q", c.where, c.call, c.fn))
			continue
		}
		seen[c.fn+" "+c.call] = true
	}
	sort.Strings(offenders)
	assert.Empty(t, offenders,
		"config.yaml is written only by writeConfigAtomic, writeConfigFile and writeFeatureMigrationConfigBytes, "+
			"each under config.WithWriteLock")

	// The scan is not vacuous: it sees the writes the funnel itself makes.
	for _, want := range []string{
		"writeConfigAtomic v.WriteConfigAs",
		"writeConfigAtomic os.Rename",
		"writeFeatureMigrationConfigBytes os.Rename",
	} {
		assert.True(t, seen[want], "scan no longer sees %s", want)
	}
}

func TestConfigWriters_ScanFlagsWriterOutsideFunnel(t *testing.T) {
	const src = `package x
import "os"
func sneaky(configPath string, v interface{ WriteConfigAs(string) error }) {
	_ = os.WriteFile(configPath, nil, 0o600)
	_ = os.Rename("tmp", flagConfig)
	_ = v.WriteConfigAs("elsewhere")
	_ = os.WriteFile(outPath, nil, 0o600)
}
`
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, "x.go", src, 0)
	require.NoError(t, err)
	var got []string
	for _, c := range scanConfigWrites(fset, file) {
		got = append(got, c.fn+" "+c.call)
	}
	assert.Equal(t, []string{"sneaky os.WriteFile", "sneaky os.Rename", "sneaky v.WriteConfigAs"}, got)
}

func TestWriteConfigAtomic_RefusesPathTheLockDoesNotCover(t *testing.T) {
	dir := t.TempDir()
	locked := filepath.Join(dir, "config.yaml")
	other := filepath.Join(dir, "other.yaml")
	v := viper.New()
	v.Set("a", 1)

	err := config.WithWriteLock(locked, func(lk *config.WriteLock) error {
		return writeConfigAtomic(lk, v, other)
	})
	require.Error(t, err)
	_, statErr := os.Stat(other)
	assert.True(t, os.IsNotExist(statErr))

	require.Error(t, writeConfigAtomic(nil, v, locked), "a nil token covers nothing")
	_, statErr = os.Stat(locked)
	assert.True(t, os.IsNotExist(statErr))
}

func TestSetConfigKey_RereadsInsideLock(t *testing.T) {
	cfgPath := filepath.Join(t.TempDir(), "config.yaml")
	require.NoError(t, os.WriteFile(cfgPath, []byte("sync:\n  workers: 2\n"), 0o600))

	// Another writer lands its key after setConfigKey was called but before
	// it took the lock; setConfigKey must not write back its older snapshot.
	old := setConfigKeyBeforeLock
	setConfigKeyBeforeLock = func() {
		require.NoError(t, config.WithWriteLock(cfgPath, func(lk *config.WriteLock) error {
			v := viper.New()
			v.SetConfigFile(cfgPath)
			require.NoError(t, v.ReadInConfig())
			v.Set("ai.background_runs", "allowed")
			return writeConfigAtomic(lk, v, cfgPath)
		}))
	}
	t.Cleanup(func() { setConfigKeyBeforeLock = old })
	// The re-read happens while the lock is held: another descriptor cannot
	// take it at that moment.
	lockedSeen := false
	oldLocked := setConfigKeyLocked
	setConfigKeyLocked = func() {
		lockedSeen = true
		assert.False(t, tryFlockOwnFD(t, cfgPath+".lock"), "setConfigKey re-reads inside the lock")
	}
	t.Cleanup(func() { setConfigKeyLocked = oldLocked })

	require.NoError(t, setConfigKey(cfgPath, "digest.enabled", true))
	require.True(t, lockedSeen)

	v := viper.New()
	v.SetConfigFile(cfgPath)
	require.NoError(t, v.ReadInConfig())
	assert.Equal(t, "allowed", v.GetString("ai.background_runs"), "the other writer's key survives")
	assert.True(t, v.GetBool("digest.enabled"))
	assert.Equal(t, 2, v.GetInt("sync.workers"))
}

func TestSetConfigKey_NestedInsideHeldLockFailsFast(t *testing.T) {
	cfgPath := filepath.Join(t.TempDir(), "config.yaml")
	var nested error
	require.NoError(t, config.WithWriteLock(cfgPath, func(*config.WriteLock) error {
		nested = setConfigKey(cfgPath, "digest.enabled", true)
		return nil
	}))
	require.ErrorIs(t, nested, config.ErrWriteLockHeld)
}

// tryFlockOwnFD takes a non-blocking exclusive flock on path through its own
// descriptor and reports whether it got it (releasing it at once).
func tryFlockOwnFD(t *testing.T, path string) bool {
	t.Helper()
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	require.NoError(t, err)
	defer f.Close()
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		require.ErrorIs(t, err, syscall.EWOULDBLOCK)
		return false
	}
	require.NoError(t, syscall.Flock(int(f.Fd()), syscall.LOCK_UN))
	return true
}

func TestWriteInitConfig_KeepsKeysWrittenMeanwhile(t *testing.T) {
	cfgPath := filepath.Join(t.TempDir(), "config.yaml")
	// Written by other writers after the wizard started (its prompts and OAuth
	// run outside the lock), before it saves.
	require.NoError(t, os.WriteFile(cfgPath,
		[]byte("ai:\n  background_runs: allowed\nclaude_path: /opt/claude\nsync:\n  workers: 9\n"), 0o600))

	require.NoError(t, writeInitConfig(cfgPath, map[string]any{
		"active_workspace":            "acme",
		"workspaces.acme.slack_token": "xoxb-test", // leak-check:allow
		"sync.workers":                config.DefaultSyncWorkers,
	}))

	v := viper.New()
	v.SetConfigFile(cfgPath)
	require.NoError(t, v.ReadInConfig())
	assert.Equal(t, "allowed", v.GetString("ai.background_runs"))
	assert.Equal(t, "/opt/claude", v.GetString("claude_path"))
	assert.Equal(t, "acme", v.GetString("active_workspace"))
	assert.Equal(t, config.DefaultSyncWorkers, v.GetInt("sync.workers"), "the wizard's own keys win")
}

func TestWriteInitConfig_LeavesUnparsableConfigAlone(t *testing.T) {
	cfgPath := filepath.Join(t.TempDir(), "config.yaml")
	broken := []byte("sync:\n\tworkers: 2\n")
	require.NoError(t, os.WriteFile(cfgPath, broken, 0o600))
	require.Error(t, writeInitConfig(cfgPath, map[string]any{"active_workspace": "acme"}))
	got, err := os.ReadFile(cfgPath)
	require.NoError(t, err)
	assert.Equal(t, broken, got)
}

func TestBlankLegacySlackConfigToken_NothingToBlankTakesNoLock(t *testing.T) {
	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "config.yaml")
	require.NoError(t, os.WriteFile(cfgPath, []byte("active_workspace: acme\n"), 0o600))
	require.NoError(t, os.Chmod(dir, 0o500))
	t.Cleanup(func() { _ = os.Chmod(dir, 0o700) })
	old := flagConfig
	flagConfig = cfgPath
	t.Cleanup(func() { flagConfig = old })

	var logs bytes.Buffer
	blankLegacySlackConfigToken(&config.Config{ActiveWorkspace: "acme"}, log.New(&logs, "", 0))

	assert.Empty(t, logs.String(), "nothing to blank logs nothing")
	_, err := os.Stat(cfgPath + ".lock")
	assert.True(t, os.IsNotExist(err), "nothing to blank takes no lock")
}

func TestWriteInitConfig_RefusesMoreThanOneDocument(t *testing.T) {
	for name, body := range map[string]string{
		"second document":           "sync:\n  workers: 2\n---\nai:\n  background_runs: allowed\n",
		"malformed after separator": "sync:\n  workers: 2\n---\nai: [unclosed\n",
	} {
		t.Run(name, func(t *testing.T) {
			cfgPath := filepath.Join(t.TempDir(), "config.yaml")
			require.NoError(t, os.WriteFile(cfgPath, []byte(body), 0o600))
			require.Error(t, writeInitConfig(cfgPath, map[string]any{"active_workspace": "acme"}))
			got, err := os.ReadFile(cfgPath)
			require.NoError(t, err)
			assert.Equal(t, body, string(got), "nothing is dropped")
		})
	}
}

func TestWriteInitConfig_EmptyFileIsAnEmptyConfig(t *testing.T) {
	cfgPath := filepath.Join(t.TempDir(), "config.yaml")
	require.NoError(t, os.WriteFile(cfgPath, nil, 0o600))
	require.NoError(t, writeInitConfig(cfgPath, map[string]any{"active_workspace": "acme"}))
	v := viper.New()
	v.SetConfigFile(cfgPath)
	require.NoError(t, v.ReadInConfig())
	assert.Equal(t, "acme", v.GetString("active_workspace"))
}

func TestWriteInitConfig_NewPathWithoutExtension(t *testing.T) {
	cfgPath := filepath.Join(t.TempDir(), "watchtower-config")
	require.NoError(t, writeInitConfig(cfgPath, map[string]any{"active_workspace": "acme"}))
	cfg, err := config.Load(cfgPath)
	require.NoError(t, err, "the next command loads what init wrote")
	assert.Equal(t, "acme", cfg.ActiveWorkspace)

	// An existing extensionless file is read as YAML and its keys kept.
	require.NoError(t, writeInitConfig(cfgPath, map[string]any{"sync.workers": 3}))
	cfg, err = config.Load(cfgPath)
	require.NoError(t, err)
	assert.Equal(t, "acme", cfg.ActiveWorkspace)
	assert.Equal(t, 3, cfg.Sync.Workers)
}

// TestConfigReaders_ForceYAML: config.yaml is YAML by contract, so every
// viper that names the config file also sets its type to yaml — the format
// never follows the path's extension (an extensionless --config path, or one
// ending in .json, still holds YAML that init and config.Load agree on).
func TestConfigReaders_ForceYAML(t *testing.T) {
	fset := token.NewFileSet()
	files, typed := 0, 0
	for _, dir := range []string{".", filepath.Join("..", "internal", "config"), filepath.Join("..", "internal", "diagnostics")} {
		paths, err := filepath.Glob(filepath.Join(dir, "*.go"))
		require.NoError(t, err)
		for _, p := range paths {
			if strings.HasSuffix(p, "_test.go") {
				continue
			}
			file, err := parser.ParseFile(fset, p, nil, 0)
			require.NoError(t, err)
			for _, decl := range file.Decls {
				setFile, setYAML := 0, 0
				ast.Inspect(decl, func(n ast.Node) bool {
					call, ok := n.(*ast.CallExpr)
					if !ok {
						return true
					}
					sel, ok := call.Fun.(*ast.SelectorExpr)
					if !ok {
						return true
					}
					switch sel.Sel.Name {
					case "SetConfigFile":
						setFile++
					case "SetConfigType":
						if lit, ok := call.Args[0].(*ast.BasicLit); ok && lit.Value == `"yaml"` {
							setYAML++
						}
					}
					return true
				})
				files += setFile
				typed += setYAML
				assert.LessOrEqual(t, setFile, setYAML,
					"%s: a viper on the config file sets SetConfigType(\"yaml\")", fset.Position(decl.Pos()))
			}
		}
	}
	assert.Positive(t, files, "the scan sees the config readers")
	assert.GreaterOrEqual(t, typed, files)
}

func TestConfigInit_BrokenConfigFailsBeforeAnyPrompt(t *testing.T) {
	cfgPath := filepath.Join(t.TempDir(), "config.yaml")
	require.NoError(t, os.WriteFile(cfgPath, []byte("sync:\n\tworkers: 2\n"), 0o600))
	old := flagConfig
	flagConfig = cfgPath
	t.Cleanup(func() { flagConfig = old })

	var out bytes.Buffer
	c := &cobra.Command{}
	c.SetOut(&out)
	c.SetIn(strings.NewReader("")) // no input: a prompt would fail differently
	err := runConfigInit(c, nil)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "cannot be carried over")
	assert.NotContains(t, out.String(), "How do you want to authenticate?", "no prompt is shown")
}

// TestConfigWriters_UnparsableConfigIsNeverOverwritten: a writer that cannot
// parse config.yaml under the lock aborts, leaving the file byte-identical,
// instead of writing a file that holds only its own keys.
func TestConfigWriters_UnparsableConfigIsNeverOverwritten(t *testing.T) {
	writers := map[string]func(path string) error{
		"enableJiraPhase":   func(string) error { return enableJiraPhase() },
		"enableLinearPhase": func(string) error { return enableLinearPhase() },
		"setConfigKey":      func(p string) error { return setConfigKey(p, "digest.enabled", true) },
		"setAIConfigKey":    func(p string) error { return setAIConfigKey(p, "ai.fallback.enabled", true) },
		"writeWorkspaceScaffold": func(p string) error {
			return writeWorkspaceScaffold(p, "acme", true, nil)
		},
		"writeInitConfig": func(p string) error {
			return writeInitConfig(p, map[string]any{"active_workspace": "acme"})
		},
	}
	for name, write := range writers {
		t.Run(name, func(t *testing.T) {
			cfgPath := filepath.Join(t.TempDir(), "config.yaml")
			broken := []byte("ai:\n  background_runs: allowed\nsync: [unclosed\n")
			require.NoError(t, os.WriteFile(cfgPath, broken, 0o600))
			old := flagConfig
			flagConfig = cfgPath
			t.Cleanup(func() { flagConfig = old })

			require.Error(t, write(cfgPath))
			got, err := os.ReadFile(cfgPath)
			require.NoError(t, err)
			assert.Equal(t, broken, got, "the file is byte-identical")
		})
	}
}

func TestEnablePhase_MissingConfigStartsEmpty(t *testing.T) {
	for name, enable := range map[string]func() error{"jira": enableJiraPhase, "linear": enableLinearPhase} {
		t.Run(name, func(t *testing.T) {
			cfgPath := filepath.Join(t.TempDir(), "config.yaml")
			old := flagConfig
			flagConfig = cfgPath
			t.Cleanup(func() { flagConfig = old })

			require.NoError(t, enable())
			cfg, err := config.Load(cfgPath)
			require.NoError(t, err)
			if name == "jira" {
				assert.True(t, cfg.Jira.Enabled)
			} else {
				assert.True(t, cfg.Linear.Enabled)
			}
		})
	}
}
