package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strings"
	"testing"

	"github.com/spf13/cobra"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"gopkg.in/yaml.v3"

	"watchtower/internal/aiconsent"
	"watchtower/internal/config"
	"watchtower/internal/policy"
	"watchtower/internal/policy/policytest"
)

// aiBackgroundFixture points the command at a temp config, reads the
// consent back from that file (the package default reader is replaced in
// tests), counts daemon signals and fakes the terminal. It returns the
// config path and the signal counter.
func aiBackgroundFixture(t *testing.T, initial string, tty bool) (configPath string, signals *int) {
	t.Helper()
	configPath = filepath.Join(t.TempDir(), "config.yaml")
	if initial != "" {
		require.NoError(t, os.WriteFile(configPath, []byte(initial), 0o600))
	}
	oldConfig, oldReader, oldSignal, oldTTY := flagConfig, backgroundConsentReader, signalDaemonFn, stdinIsTTY
	t.Cleanup(func() {
		flagConfig, backgroundConsentReader, signalDaemonFn, stdinIsTTY = oldConfig, oldReader, oldSignal, oldTTY
		rootCmd.SetIn(nil)
	})
	flagConfig = configPath
	backgroundConsentReader = fileConsentReader(t, configPath)
	n := 0
	signals = &n
	signalDaemonFn = func(*config.Config) (int, error) { n++; return 0, nil }
	stdinIsTTY = func() bool { return tty }
	return configPath, signals
}

// fileConsentReader resolves the answer stored in path with the forced
// policy, the way aiconsent.Current does in production.
func fileConsentReader(t *testing.T, path string) aiconsent.Reader {
	t.Helper()
	return func() aiconsent.State {
		answer := aiconsent.AnswerNone
		if data, err := os.ReadFile(path); err == nil {
			var root struct {
				AI struct {
					BackgroundRuns string `yaml:"background_runs"`
				} `yaml:"ai"`
			}
			require.NoError(t, yaml.Unmarshal(data, &root))
			answer, _ = aiconsent.ParseAnswer(root.AI.BackgroundRuns)
		}
		return aiconsent.Resolve(answer, policy.Current().Keys.AllowBackgroundAI)
	}
}

func storedAnswer(t *testing.T, path string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return ""
	}
	require.NoError(t, err)
	var root map[string]any
	require.NoError(t, yaml.Unmarshal(data, &root))
	aiMap, _ := root["ai"].(map[string]any)
	s, _ := aiMap["background_runs"].(string)
	return s
}

var aiBackgroundCmds = []*cobra.Command{aiBackgroundStatusCmd, aiBackgroundAllowCmd, aiBackgroundPauseCmd}

func runAIBackground(t *testing.T, args ...string) (stdout, stderr string, err error) {
	t.Helper()
	return runRootCmd(t, aiBackgroundCmds, append([]string{"ai", "background"}, args...)...)
}

func TestAIBackground_StatusJSONKeys(t *testing.T) {
	policytest.Set(t, nil)
	aiBackgroundFixture(t, "active_workspace: test\n", false)

	out, _, err := runAIBackground(t, "status", "--json")
	require.NoError(t, err)
	var got map[string]any
	require.NoError(t, json.Unmarshal([]byte(out), &got))
	keys := make([]string, 0, len(got))
	for k := range got {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	assert.Equal(t, []string{"answer", "effective", "policy", "reason"}, keys)
	assert.Equal(t, "paused", got["effective"])
	assert.Equal(t, "unanswered", got["reason"])
	assert.Equal(t, "", got["answer"])
	assert.Nil(t, got["policy"])

	policytest.Set(t, map[string]any{policy.KeyAllowBackgroundAI: true})
	out, _, err = runAIBackground(t, "status", "--json")
	require.NoError(t, err)
	var org aiBackgroundStatusJSON
	require.NoError(t, json.Unmarshal([]byte(out), &org))
	assert.Equal(t, "allowed", org.Effective)
	assert.Equal(t, "organization", org.Reason)
	require.NotNil(t, org.Policy)
	assert.True(t, *org.Policy)
}

func TestAIBackground_AllowNeedsYesWithoutTTY(t *testing.T) {
	policytest.Set(t, nil)
	const initial = "active_workspace: test\n"
	path, signals := aiBackgroundFixture(t, initial, false)

	_, _, err := runAIBackground(t, "allow")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "run with --yes to confirm")
	data, readErr := os.ReadFile(path)
	require.NoError(t, readErr)
	assert.Equal(t, initial, string(data))
	assert.Zero(t, *signals)
}

func TestAIBackground_AllowRefusedByPolicy(t *testing.T) {
	policytest.Set(t, map[string]any{policy.KeyAllowBackgroundAI: false})
	const initial = "active_workspace: test\n"
	path, signals := aiBackgroundFixture(t, initial, true)

	_, _, err := runAIBackground(t, "allow", "--yes")
	require.Error(t, err)
	assert.ErrorIs(t, err, policy.ErrNotAllowed)
	data, readErr := os.ReadFile(path)
	require.NoError(t, readErr)
	assert.Equal(t, initial, string(data))
	assert.Zero(t, *signals)
}

func TestAIBackground_AllowWritesAndSignals(t *testing.T) {
	policytest.Set(t, nil)
	path, signals := aiBackgroundFixture(t, "active_workspace: test\nai:\n  provider: claude\n", false)

	out, _, err := runAIBackground(t, "allow", "--yes")
	require.NoError(t, err)
	assert.Equal(t, "allowed", storedAnswer(t, path))
	assert.Equal(t, 1, *signals)
	assert.Contains(t, out, "Background AI: allowed")
	cfg, err := config.Load(path)
	require.NoError(t, err)
	assert.Equal(t, "claude", cfg.AI.Provider, "the other keys survive")

	// A failed signal (no daemon, stale PID file) still exits 0: the write
	// stands and the next cycle runs.
	signalDaemonFn = func(*config.Config) (int, error) { *signals++; return 0, errors.New("no daemon") }
	_, stderr, err := runAIBackground(t, "allow", "--yes")
	require.NoError(t, err)
	assert.Equal(t, 2, *signals)
	assert.Contains(t, stderr, "no daemon")
}

func TestAIBackground_AllowCreatesMissingConfig(t *testing.T) {
	policytest.Set(t, nil)
	path, _ := aiBackgroundFixture(t, "", false)
	path = filepath.Join(filepath.Dir(path), "nested", "config.yaml")
	flagConfig = path
	backgroundConsentReader = fileConsentReader(t, path)

	_, _, err := runAIBackground(t, "allow", "--yes")
	require.NoError(t, err)
	assert.Equal(t, "allowed", storedAnswer(t, path))
}

func TestAIBackground_PauseNeverRefused(t *testing.T) {
	policytest.Set(t, map[string]any{policy.KeyAllowBackgroundAI: false})
	path, signals := aiBackgroundFixture(t, "active_workspace: test\n", false)

	out, _, err := runAIBackground(t, "pause")
	require.NoError(t, err)
	assert.Equal(t, "paused", storedAnswer(t, path))
	assert.Zero(t, *signals)
	assert.Contains(t, out, "Background AI: turned off by your organization")
}

func TestAIBackground_TTYPromptDefaultsNo(t *testing.T) {
	policytest.Set(t, nil)
	path, signals := aiBackgroundFixture(t, "active_workspace: test\nai:\n  provider: claude\n", true)

	rootCmd.SetIn(strings.NewReader("\n"))
	out, _, err := runAIBackground(t, "allow")
	require.NoError(t, err)
	assert.Empty(t, storedAnswer(t, path))
	assert.Zero(t, *signals)
	assert.Contains(t, out, "Let Watchtower run AI in the background?")
	assert.Contains(t, out, "These runs use your own Claude subscription")
	assert.Contains(t, out, "Allow background AI? [y/N]")

	rootCmd.SetIn(strings.NewReader("y\n"))
	_, _, err = runAIBackground(t, "allow")
	require.NoError(t, err)
	assert.Equal(t, "allowed", storedAnswer(t, path))
	assert.Equal(t, 1, *signals)
}

// TestAIBackground_ConsentText pins the Go copy of spec §5.1.
func TestAIBackground_ConsentText(t *testing.T) {
	claude := consentText("claude", "", 15, 30)
	for _, want := range []string{
		"Let Watchtower run AI in the background?",
		"Watchtower uses Claude Code on this Mac to write your digests, briefings, tracks and people cards, and to run your automations. Most of this starts on its own, on a schedule or after each sync, without you asking each time.",
		"These runs use your own Claude subscription and count toward its usage limits, the same as when you use Claude Code yourself. Watchtower never pays for, sees or shares your sign-in.",
		"What can run on its own",
		"After each sync, about every 15 min: channel digests, tracks, memory, next steps, image and link descriptions",
		"Every few hours: ideas, Jira and mail digests",
		"Once a day: the morning briefing, day plan and people cards. Once a week: agent coaching",
		"After you connect a source: its last 30 days of history, a little at each sync",
		"Your automations that use AI, at the times and on the events you set",
		"Chats, Catch-Up, Run now and anything else you start yourself always run, whatever you pick here.",
		"You can change this any time in Settings → AI → Background AI.",
	} {
		assert.Contains(t, claude, want)
	}
	assert.NotContains(t, claude, "switch to")

	codex := consentText("codex", "claude", 5, 7)
	assert.Contains(t, codex, "Watchtower uses Codex on this Mac")
	assert.Contains(t, codex, "These runs use your own ChatGPT plan and count toward its Codex usage limits, the same as when you use Codex yourself. Watchtower never pays for, sees or shares your sign-in.")
	assert.Contains(t, codex, "When Codex's usage limit is reached, runs switch to Claude Code and use your Claude subscription.")

	assert.Contains(t, consentText("claude", "codex", 5, 7),
		"When Claude's usage limit is reached, runs switch to Codex and use your ChatGPT plan.")

	ollama := consentText("ollama", "", 5, 7)
	assert.Contains(t, ollama, "These runs use Ollama / Local, the model server set in Settings → AI.")
	assert.NotContains(t, ollama, "subscription")
}

func TestConfigSet_RefusesBackgroundRunsKey(t *testing.T) {
	const initial = "active_workspace: test\n"
	configPath := filepath.Join(t.TempDir(), "config.yaml")
	require.NoError(t, os.WriteFile(configPath, []byte(initial), 0o600))
	old := flagConfig
	flagConfig = configPath
	t.Cleanup(func() { flagConfig = old })
	configSetCmd.SetOut(new(bytes.Buffer))

	for _, key := range []string{"ai.background_runs", "AI.Background_Runs", "AI.background_runs", "ai", "AI"} {
		for _, value := range []string{"allowed", "paused", "yes"} {
			err := configSetCmd.RunE(configSetCmd, []string{key, value})
			require.Error(t, err, key)
			assert.Contains(t, err.Error(), "watchtower ai background allow|pause")
			data, readErr := os.ReadFile(configPath)
			require.NoError(t, readErr)
			assert.Equal(t, initial, string(data))
		}
	}
}

func TestStatus_BackgroundAILine(t *testing.T) {
	no, yes := false, true
	cases := []struct {
		state aiconsent.State
		want  string
	}{
		{aiconsent.Resolve(aiconsent.AnswerNone, nil), "Background AI: paused (not answered) — allow with `watchtower ai background allow`"},
		{aiconsent.Resolve(aiconsent.AnswerAllowed, nil), "Background AI: allowed"},
		{aiconsent.Resolve(aiconsent.AnswerNone, &yes), "Background AI: allowed"},
		{aiconsent.Resolve(aiconsent.AnswerPaused, nil), "Background AI: paused by you"},
		{aiconsent.Resolve(aiconsent.AnswerAllowed, &no), "Background AI: turned off by your organization"},
	}
	for _, c := range cases {
		assert.Equal(t, c.want, backgroundAIStatusLine(c.state))
	}
}

// TestProcess_DaemonInitsBackgroundOrigin: the daemon process (sync
// --daemon) starts with background origin; a typed command with owner.
func TestProcess_DaemonInitsBackgroundOrigin(t *testing.T) {
	noEnv := func(string) string { return "" }
	t.Cleanup(func() { aiconsent.InitProcess("cli", noEnv) })

	assert.Equal(t, "daemon", initProcessOrigin([]string{"sync", "--daemon"}, noEnv))
	o, _ := aiconsent.OriginOf(context.Background())
	assert.Equal(t, aiconsent.OriginBackground, o)

	assert.Equal(t, "cli:digest generate", initProcessOrigin([]string{"digest", "generate"}, noEnv))
	o, _ = aiconsent.OriginOf(context.Background())
	assert.Equal(t, aiconsent.OriginOwner, o)

	bg := func(k string) string {
		if k == aiconsent.EnvOrigin {
			return "background"
		}
		return ""
	}
	initProcessOrigin([]string{"digest", "generate"}, bg)
	o, _ = aiconsent.OriginOf(context.Background())
	assert.Equal(t, aiconsent.OriginBackground, o)
}

// TestProcess_ExecuteInitsOrigin: Execute is what sets the process origin
// (a static check: Execute calls initProcessOrigin with os.Getenv).
func TestProcess_ExecuteInitsOrigin(t *testing.T) {
	src, err := os.ReadFile("root.go")
	require.NoError(t, err)
	f, err := parser.ParseFile(token.NewFileSet(), "root.go", src, 0)
	require.NoError(t, err)
	found := false
	ast.Inspect(f, func(n ast.Node) bool {
		fd, ok := n.(*ast.FuncDecl)
		if !ok || fd.Name.Name != "Execute" {
			return true
		}
		ast.Inspect(fd.Body, func(n ast.Node) bool {
			call, ok := n.(*ast.CallExpr)
			if !ok {
				return true
			}
			if id, ok := call.Fun.(*ast.Ident); ok && id.Name == "initProcessOrigin" && len(call.Args) == 2 {
				if sel, ok := call.Args[1].(*ast.SelectorExpr); ok && sel.Sel.Name == "Getenv" {
					found = true
				}
			}
			return true
		})
		return false
	})
	assert.True(t, found, "Execute must call initProcessOrigin(os.Args[1:], os.Getenv)")
}

// modelCommandFiles maps every cmd file that builds a generator or an AI
// client (the grep in TestModelCommands_ExistInCLI, comment lines skipped) to the command paths of
// model_commands.json it defines. modelHelperFiles are files whose model use
// is not a command a launcher can start, with the reason.
var modelCommandFiles = map[string][][]string{
	"ai.go":                        {{"ai", "query"}, {"ai", "test"}},
	"ask.go":                       {{"ask"}},
	"automations_run.go":           {{"automations", "dry-run"}},
	"builtins.go":                  {{"briefing", "generate"}, {"day-plan", "generate"}},
	"catchup.go":                   {{"catchup", "run"}, {"catchup", "feedback"}},
	"chat.go":                      {{"chat", "title"}},
	"coach.go":                     {{"coach", "run"}},
	"dictate.go":                   {{"dictate", "clean"}},
	"digest.go":                    {{"digest", "generate"}, {"digest", "summary"}},
	"ideas.go":                     {{"ideas", "mine"}},
	"inbox.go":                     {{"inbox", "generate"}},
	"jira.go":                      {{"jira", "boards", "analyze"}, {"jira", "fields", "discover"}, {"jira", "fields", "map"}},
	"meeting.go":                   {{"meeting-prep"}},
	"meeting_transcript.go":        {{"meeting-prep"}},
	"memory.go":                    {{"memory", "consolidate"}, {"memory", "digest-compare"}},
	"people.go":                    {{"people", "generate"}},
	"profile.go":                   {{"profile", "style-sample"}},
	"prompts.go":                   {{"tune"}},
	"reaction_commands.go":         {{"reaction-commands", "poll"}},
	"slack_backfill.go":            {{"slack", "backfill"}},
	"targets_ai.go":                {{"targets", "ai-update"}, {"targets", "extract"}, {"targets", "generate"}, {"targets", "next-step"}, {"targets", "suggest-links"}},
	"terminal.go":                  {{"terminal", "title"}},
	"tracks.go":                    {{"tracks", "create"}, {"tracks", "generate"}, {"tracks", "scan"}},
	"workbench_review_overview.go": {{"workbench", "review", "overview"}},
	"workbench_spec_review.go":     {{"workbench", "spec-review", "run"}, {"workbench", "spec-review", "start"}},
}

var modelHelperFiles = map[string]string{
	"generator.go":               "the generator and AI client constructors",
	"provider_policy.go":         "the policy-checked generator wrapper",
	"workbench_askguard_stop.go": "workbench ask-guard --stop: the Stop hook of the owner's own workbench session (owner origin); no launcher starts it",
	"automations_registry.go":    "the authoring generator of automations preview and the MCP tool registry (no command of its own)",
	"root.go":                    "the interactive REPL: the bare root command, a terminal only",
	"sync.go":                    "the daemon's post-sync pipelines: sync --daemon is background by role; sync's other forms (--now, stop, --users-only) call no model",
}

func loadModelCommands(t *testing.T) [][]string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "internal", "aiconsent", "testdata", "model_commands.json"))
	require.NoError(t, err)
	var paths [][]string
	require.NoError(t, json.Unmarshal(data, &paths))
	return paths
}

func TestModelCommands_ExistInCLI(t *testing.T) {
	paths := loadModelCommands(t)
	require.NotEmpty(t, paths)
	listed := map[string]bool{}
	for _, p := range paths {
		require.NotEmpty(t, p)
		key := strings.Join(p, " ")
		assert.False(t, listed[key], "duplicate %q", key)
		listed[key] = true
		c, _, err := rootCmd.Find(p)
		require.NoError(t, err, key)
		assert.Equal(t, "watchtower "+key, c.CommandPath(), "%q is not a command", key)
	}

	gen := regexp.MustCompile(`cliPooledGenerator|cliGenerator|newAIClient|checkedGenerator|cliBoundedGenerator|cliBuiltinGenerator|legacyCLIGenerator|transport\.For`)
	files, err := filepath.Glob("*.go")
	require.NoError(t, err)
	var found []string
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		src, err := os.ReadFile(f)
		require.NoError(t, err)
		for _, line := range strings.Split(string(src), "\n") {
			if !strings.HasPrefix(strings.TrimSpace(line), "//") && gen.MatchString(line) {
				found = append(found, f)
				break
			}
		}
	}
	require.NotEmpty(t, found)
	for _, f := range found {
		cmdPaths, isCmd := modelCommandFiles[f]
		_, isHelper := modelHelperFiles[f]
		if !isCmd && !isHelper {
			t.Errorf("%s builds a generator or AI client: add the commands it defines to internal/aiconsent/testdata/model_commands.json and modelCommandFiles (or a reason to modelHelperFiles)", f)
			continue
		}
		for _, p := range cmdPaths {
			assert.True(t, listed[strings.Join(p, " ")], "%s: %q is missing from model_commands.json", f, strings.Join(p, " "))
		}
	}
	for f := range modelCommandFiles {
		assert.True(t, slices.Contains(found, f), "modelCommandFiles lists %s, which builds no generator any more", f)
	}
	for f := range modelHelperFiles {
		assert.True(t, slices.Contains(found, f), "modelHelperFiles lists %s, which builds no generator any more", f)
	}
}

// TestModelCommands_JSONIsSorted keeps the shared list stable for the
// Desktop's byte-for-byte copy.
func TestModelCommands_JSONIsSorted(t *testing.T) {
	paths := loadModelCommands(t)
	keys := make([]string, len(paths))
	for i, p := range paths {
		keys[i] = strings.Join(p, " ")
	}
	assert.True(t, sort.StringsAreSorted(keys), "model_commands.json is not sorted")
}

// TestProcess_CLIRootSetsConsentConfigPath: a command run through the CLI
// root reads the consent answer from the --config file (cobra.OnInitialize),
// so aiconsent.Current is not stuck at its fail-closed "no path" default.
// The answer is "paused" so only a real read of this file gives reason owner.
func TestProcess_CLIRootSetsConsentConfigPath(t *testing.T) {
	policytest.Set(t, nil)
	configPath := filepath.Join(t.TempDir(), "config.yaml")
	require.NoError(t, os.WriteFile(configPath, []byte("ai:\n  background_runs: paused\n"), 0o600))
	oldConfig, oldReader := flagConfig, backgroundConsentReader
	t.Cleanup(func() {
		flagConfig, backgroundConsentReader = oldConfig, oldReader
		aiconsent.SetConfigPath(oldConfig)
	})
	backgroundConsentReader = nil
	aiconsent.SetConfigPath("")

	out, _, err := runAIBackground(t, "status", "--json", "--config", configPath)
	require.NoError(t, err)
	var got aiBackgroundStatusJSON
	require.NoError(t, json.Unmarshal([]byte(out), &got))
	assert.Equal(t, aiBackgroundStatusJSON{Effective: "paused", Reason: "owner", Answer: "paused"}, got)
	assert.Equal(t, aiconsent.ReasonOwner, aiconsent.Current().Reason)
}

func TestConfigSet_RefusesParentOfBackgroundRunsKey(t *testing.T) {
	const initial = "ai:\n  background_runs: allowed\n  provider: claude\n"
	configPath := filepath.Join(t.TempDir(), "config.yaml")
	require.NoError(t, os.WriteFile(configPath, []byte(initial), 0o600))
	old := flagConfig
	flagConfig = configPath
	t.Cleanup(func() { flagConfig = old })
	configSetCmd.SetOut(new(bytes.Buffer))

	err := configSetCmd.RunE(configSetCmd, []string{"ai", "x"})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "watchtower ai background allow|pause")
	assert.Equal(t, "allowed", storedAnswer(t, configPath))

	// A sibling key is still settable and keeps the answer.
	require.NoError(t, configSetCmd.RunE(configSetCmd, []string{"ai.model", "opus"}))
	assert.Equal(t, "allowed", storedAnswer(t, configPath))
}

func TestAIBackground_AllowSignalsNamedWorkspace(t *testing.T) {
	policytest.Set(t, nil)
	aiBackgroundFixture(t, "active_workspace: test\n", false)
	var signalled string
	signalDaemonFn = func(cfg *config.Config) (int, error) { signalled = cfg.ActiveWorkspace; return 0, nil }

	_, _, err := runAIBackground(t, "allow", "--yes", "--workspace", "other")
	require.NoError(t, err)
	assert.Equal(t, "other", signalled)
}

// errAfterReader returns data, then err.
type errAfterReader struct {
	data string
	err  error
}

func (r *errAfterReader) Read(p []byte) (int, error) {
	if r.data == "" {
		return 0, r.err
	}
	n := copy(p, r.data)
	r.data = r.data[n:]
	return n, nil
}

func TestAIBackground_PromptReadErrorIsNotAnAnswer(t *testing.T) {
	policytest.Set(t, nil)
	path, signals := aiBackgroundFixture(t, "active_workspace: test\n", true)

	rootCmd.SetIn(&errAfterReader{data: "y", err: errors.New("terminal gone")})
	_, _, err := runAIBackground(t, "allow")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "terminal gone")
	assert.Empty(t, storedAnswer(t, path))
	assert.Zero(t, *signals)

	// "y" then EOF is an answer; EOF alone is a no.
	rootCmd.SetIn(strings.NewReader(""))
	_, _, err = runAIBackground(t, "allow")
	require.NoError(t, err)
	assert.Empty(t, storedAnswer(t, path))
	rootCmd.SetIn(strings.NewReader("y"))
	_, _, err = runAIBackground(t, "allow")
	require.NoError(t, err)
	assert.Equal(t, "allowed", storedAnswer(t, path))
}

func TestAIBackground_AllowRefusesBadWorkspace(t *testing.T) {
	policytest.Set(t, nil)
	path, signals := aiBackgroundFixture(t, "", false)

	_, _, err := runAIBackground(t, "allow", "--yes", "--workspace", "../x")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "invalid workspace name")
	assert.Empty(t, storedAnswer(t, path))
	assert.Zero(t, *signals)

	// No --workspace on a fresh install (no config, no workspace) answers.
	_, _, err = runAIBackground(t, "allow", "--yes")
	require.NoError(t, err)
	assert.Equal(t, "allowed", storedAnswer(t, path))
}
