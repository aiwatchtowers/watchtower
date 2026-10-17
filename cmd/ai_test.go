package cmd

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/spf13/cobra"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/ai"
	"watchtower/internal/chat"
	"watchtower/internal/config"
	"watchtower/internal/tools"
)

func TestChatMCPArgs_Shape(t *testing.T) {
	aiFlagSurface, aiFlagConversation, aiFlagTurn, aiFlagContextType, aiFlagContextID = "target", 7, "t1", "target", "42"
	t.Cleanup(func() {
		aiFlagSurface, aiFlagConversation, aiFlagTurn, aiFlagContextType, aiFlagContextID = "main", 0, "", "", ""
	})
	got := chatMCPArgs()
	want := []string{"--chat", "--surface", "target", "--conversation", "7", "--turn", "t1", "--context-type", "target", "--context-id", "42"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v", got)
	}
}

// TestAIQueryCmd_FlagsBeforeSeparatorReachRunEVerbatim is the cobra-side pin
// for task 12's Swift argv ordering: WatchtowerAIService.buildArgs must emit
// ["ai", "query"], then every flag, then ["--", prompt] — flags first, `--`
// last. This drives the real command tree from rootCmd down (cobra always
// resolves Execute() to the root — calling Execute() on a child command
// directly re-parses the *root's* args instead, a cobra gotcha; the
// rootCmd.SetArgs precedent below is the same one cmd/jira_create_test.go
// uses), through cobra.ExactArgs(1) and the flags registered in cmd/ai.go's
// init(), and asserts the values RunE actually receives — never an error
// string, per the "count/one-element traps" note in the wave-5 plan.
//
// Two prompt shapes matter: a short single-dash flag-shaped message ("-v
// looks wrong") and a long double-dash one ("--verbose please") — a fixture
// that only covers one dash style would miss an implementation that
// special-cases just one of them.
//
// flagConfig is pointed at a nonexistent path so cobra's inherited
// PersistentPreRunE (ensureSchemaFormat, cmd/root.go) short-circuits at its
// own os.Stat(flagConfig) check without touching any real config or DB.
func TestAIQueryCmd_FlagsBeforeSeparatorReachRunEVerbatim(t *testing.T) {
	origFlagConfig := flagConfig
	flagConfig = filepath.Join(t.TempDir(), "does-not-exist.yaml")
	t.Cleanup(func() { flagConfig = origFlagConfig })

	origRunE := aiQueryCmd.RunE
	t.Cleanup(func() { aiQueryCmd.RunE = origRunE })
	t.Cleanup(func() {
		resetSystemPromptFlags(t)
		rootCmd.SetArgs(nil)
	})

	tests := []struct {
		name   string
		prompt string
	}{
		{"single-dash flag-shaped prompt", "-v looks wrong"},
		{"double-dash flag-shaped prompt", "--verbose please"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var gotPrompt, gotSystemPrompt string
			called := false
			aiQueryCmd.RunE = func(_ *cobra.Command, args []string) error {
				called = true
				gotPrompt = args[0]
				gotSystemPrompt = aiFlagSystemPrompt
				return nil
			}

			rootCmd.SetArgs([]string{"ai", "query", "--system-prompt", "S", "--", tt.prompt})
			err := rootCmd.Execute()
			rootCmd.SetArgs(nil)
			if err != nil {
				t.Fatalf("Execute() error = %v", err)
			}
			if !called {
				t.Fatal("RunE was not invoked")
			}
			if gotPrompt != tt.prompt {
				t.Errorf("prompt reaching RunE = %q, want %q", gotPrompt, tt.prompt)
			}
			if gotSystemPrompt != "S" {
				t.Errorf("--system-prompt value = %q, want %q — a flag placed after \"--\" would never reach its variable", gotSystemPrompt, "S")
			}
		})
	}
}

func runV2(t *testing.T, chunks []ai.StreamChunk, sid string, err error) []chat.Event {
	t.Helper()
	textCh := make(chan ai.StreamChunk, len(chunks))
	for _, c := range chunks {
		textCh <- c
	}
	close(textCh)
	sidCh := make(chan string, 1)
	sidCh <- sid
	close(sidCh)
	errCh := make(chan error, 1)
	if err != nil {
		errCh <- err
	}
	close(errCh)

	var buf bytes.Buffer
	streamQueryV2(&buf, "t1", textCh, errCh, sidCh)
	var out []chat.Event
	sc := bufio.NewScanner(&buf)
	for sc.Scan() {
		var e chat.Event
		require.NoError(t, json.Unmarshal(sc.Bytes(), &e))
		out = append(out, e)
	}
	return out
}

func TestAIQueryV2_StreamsWithoutReset(t *testing.T) {
	evs := runV2(t, []ai.StreamChunk{{Text: "Let me check."}, {ToolBoundary: true}, {Text: "Found it."}}, "s1", nil)
	var types []string
	for _, e := range evs {
		types = append(types, e.Type)
	}
	assert.Equal(t, []string{chat.EventTurnStart, chat.EventTextDelta, chat.EventTextDelta, chat.EventTurnDone}, types)
	assert.Equal(t, "t1", evs[3].TurnID)
	assert.Equal(t, "s1", evs[3].SessionID)
	assert.Equal(t, chat.StatusComplete, evs[3].Status)
}

func TestAIQueryV2_ErrorIsTerminal(t *testing.T) {
	evs := runV2(t, []ai.StreamChunk{{Text: "partial"}}, "", errors.New("API Error: 429 rate_limit_error"))
	last := evs[len(evs)-1]
	assert.Equal(t, chat.EventError, last.Type)
	assert.Equal(t, "t1", last.TurnID)
	assert.Equal(t, chat.CodeRateLimit, last.Code)
	for _, e := range evs {
		assert.NotEqual(t, chat.EventTurnDone, e.Type)
	}
}

// TestQuerySystemPrompt_Stdin: with --system-prompt-stdin the prompt comes
// from stdin (the Desktop keeps it off argv), never together with
// --system-prompt; without it, --system-prompt is used and stdin untouched.
func TestQuerySystemPrompt_Stdin(t *testing.T) {
	t.Cleanup(func() { aiFlagSystemPrompt, aiFlagSystemPromptStdin = "", false })

	aiFlagSystemPrompt, aiFlagSystemPromptStdin = "argv prompt", false
	got, err := querySystemPrompt(strings.NewReader("ignored"))
	if err != nil || got != "argv prompt" {
		t.Fatalf("flag prompt = %q, %v", got, err)
	}

	aiFlagSystemPrompt, aiFlagSystemPromptStdin = "", true
	got, err = querySystemPrompt(strings.NewReader("private context\n-- with dashes"))
	if err != nil || got != "private context\n-- with dashes" {
		t.Fatalf("stdin prompt = %q, %v", got, err)
	}

	if _, err := querySystemPrompt(strings.NewReader("")); err == nil {
		t.Fatal("an empty stdin with --system-prompt-stdin must fail, not run without the prompt")
	}

	atCap := strings.Repeat("x", maxStdinSystemPrompt)
	if got, err := querySystemPrompt(strings.NewReader(atCap)); err != nil || len(got) != maxStdinSystemPrompt {
		t.Fatalf("a prompt of exactly the cap: len %d, err %v", len(got), err)
	}
	if _, err := querySystemPrompt(strings.NewReader(atCap + "x")); err == nil {
		t.Fatal("a prompt over the cap must be refused")
	}
}

// TestQueryInput_PromptStdin (board #566): with --prompt-stdin the prompt
// and system prompt both come from one JSON object on stdin — the Desktop
// keeps the owner's typed message off argv — and no positional prompt is
// taken; without it the positional prompt still works for CLI users.
func TestQueryInput_PromptStdin(t *testing.T) {
	t.Cleanup(func() { aiFlagPromptStdin, aiFlagSystemPrompt, aiFlagSystemPromptStdin = false, "", false })

	aiFlagPromptStdin = true
	prompt, sys, err := queryInput(nil, strings.NewReader(`{"prompt":"-v owner text","system_prompt":"private context"}`))
	if err != nil || prompt != "-v owner text" || sys != "private context" {
		t.Fatalf("queryInput = %q, %q, %v", prompt, sys, err)
	}
	prompt, sys, err = queryInput(nil, strings.NewReader("{\"prompt\":\"hi\"}\n"))
	if err != nil || prompt != "hi" || sys != "" {
		t.Fatalf("no system prompt: %q, %q, %v", prompt, sys, err)
	}
	for name, in := range map[string]string{
		"empty stdin":   "",
		"no prompt":     `{"system_prompt":"s"}`,
		"not JSON":      "hello",
		"unknown field": `{"prompt":"hi","model":"x"}`,
		"two objects":   `{"prompt":"hi"}{"prompt":"again"}`,
		"trailing text": `{"prompt":"hi"} extra`,
	} {
		if _, _, err := queryInput(nil, strings.NewReader(in)); err == nil {
			t.Errorf("%s: must be refused", name)
		}
	}
	if _, _, err := queryInput([]string{"also positional"}, strings.NewReader(`{"prompt":"hi"}`)); err == nil {
		t.Error("--prompt-stdin with a positional prompt must be refused")
	}

	aiFlagPromptStdin, aiFlagSystemPrompt = false, "argv sys"
	prompt, sys, err = queryInput([]string{"positional"}, strings.NewReader("ignored"))
	if err != nil || prompt != "positional" || sys != "argv sys" {
		t.Fatalf("positional form = %q, %q, %v", prompt, sys, err)
	}
	if _, _, err := queryInput(nil, strings.NewReader("")); err == nil {
		t.Error("no prompt at all must be refused")
	}
}

func TestAIQueryCmd_SystemPromptFlagsMutuallyExclusive(t *testing.T) {
	resetSystemPromptFlags(t)
	t.Cleanup(func() { resetSystemPromptFlags(t) })
	origFlagConfig := flagConfig
	flagConfig = filepath.Join(t.TempDir(), "does-not-exist.yaml")
	t.Cleanup(func() { flagConfig = origFlagConfig })
	origRunE := aiQueryCmd.RunE
	t.Cleanup(func() {
		aiQueryCmd.RunE = origRunE
		aiFlagSystemPrompt, aiFlagSystemPromptStdin = "", false
		rootCmd.SetArgs(nil)
	})
	aiQueryCmd.RunE = func(*cobra.Command, []string) error { return nil }
	rootCmd.SetArgs([]string{"ai", "query", "--system-prompt", "", "--system-prompt-stdin", "--", "hi"})
	if err := rootCmd.Execute(); err == nil {
		t.Fatal("--system-prompt with --system-prompt-stdin must be refused, even with an empty value")
	}
}

// TestAIQueryCmd_SystemPromptStdinFlagParses: the flag reaches RunE when the
// Desktop places it ahead of the "--" separator.
func TestAIQueryCmd_SystemPromptStdinFlagParses(t *testing.T) {
	resetSystemPromptFlags(t)
	t.Cleanup(func() { resetSystemPromptFlags(t) })
	origFlagConfig := flagConfig
	flagConfig = filepath.Join(t.TempDir(), "does-not-exist.yaml")
	t.Cleanup(func() { flagConfig = origFlagConfig })
	origRunE := aiQueryCmd.RunE
	t.Cleanup(func() {
		aiQueryCmd.RunE = origRunE
		aiFlagSystemPromptStdin = false
		rootCmd.SetArgs(nil)
	})
	var got bool
	aiQueryCmd.RunE = func(_ *cobra.Command, _ []string) error {
		got = aiFlagSystemPromptStdin
		return nil
	}
	rootCmd.SetArgs([]string{"ai", "query", "--system-prompt-stdin", "--", "hi"})
	if err := rootCmd.Execute(); err != nil {
		t.Fatal(err)
	}
	if !got {
		t.Fatal("--system-prompt-stdin did not reach RunE")
	}
}

// runAIQueryStub runs rootCmd with args and aiQueryCmd's RunE replaced by
// a stub that records the positional args it got (nil when RunE never ran).
func runAIQueryStub(t *testing.T, args ...string) (gotArgs []string, ran bool, err error) {
	t.Helper()
	resetSystemPromptFlags(t)
	origFlagConfig, origProvider := flagConfig, flagProvider
	flagConfig = filepath.Join(t.TempDir(), "does-not-exist.yaml")
	origRunE := aiQueryCmd.RunE
	t.Cleanup(func() {
		aiQueryCmd.RunE = origRunE
		flagConfig, flagProvider = origFlagConfig, origProvider
		rootCmd.PersistentFlags().Lookup("provider").Changed = false
		resetSystemPromptFlags(t)
		rootCmd.SetArgs(nil)
	})
	aiQueryCmd.RunE = func(_ *cobra.Command, a []string) error {
		gotArgs, ran = a, true
		return nil
	}
	rootCmd.SetArgs(args)
	err = rootCmd.Execute()
	return gotArgs, ran, err
}

// The Desktop's form (board #566): `ai query --prompt-stdin` with flags and
// no positional prompt at all parses and reaches RunE with the flag set.
func TestAIQueryCmd_PromptStdinWithoutPositional(t *testing.T) {
	var flagSeen bool
	got, ran, err := runAIQueryStub(t, "ai", "query", "--prompt-stdin", "--provider", "codex")
	flagSeen = aiFlagPromptStdin
	if err != nil || !ran {
		t.Fatalf("ai query --prompt-stdin --provider codex: ran %v, err %v", ran, err)
	}
	if len(got) != 0 {
		t.Errorf("positional args = %v, want none", got)
	}
	if !flagSeen {
		t.Error("--prompt-stdin did not reach RunE")
	}
}

// --prompt-stdin carries the system prompt itself: either system-prompt
// flag next to it is refused before RunE.
func TestAIQueryCmd_PromptStdinRefusesSystemPromptFlags(t *testing.T) {
	for _, extra := range [][]string{
		{"--system-prompt", "S"},
		{"--system-prompt", ""},
		{"--system-prompt-stdin"},
	} {
		args := append([]string{"ai", "query", "--prompt-stdin"}, extra...)
		if _, ran, err := runAIQueryStub(t, args...); err == nil || ran {
			t.Errorf("%v: must be refused before RunE (ran %v, err %v)", extra, ran, err)
		}
	}
}

// resetSystemPromptFlags clears both system-prompt flags, values and pflag
// "changed" state alike: aiQueryCmd is a package singleton, and the
// mutual-exclusion check reads "changed" left over from an earlier test.
func resetSystemPromptFlags(t *testing.T) {
	t.Helper()
	aiFlagSystemPrompt, aiFlagSystemPromptStdin, aiFlagPromptStdin = "", false, false
	for _, name := range []string{"system-prompt", "system-prompt-stdin", "prompt-stdin"} {
		aiQueryCmd.Flags().Lookup(name).Changed = false
	}
}

// setAIChatFlags sets the --tools chat binding flags and restores them.
func setAIChatFlags(t *testing.T, surface string, conversation int64, turn, ctxType, ctxID string) {
	t.Helper()
	s, c, tu, ct, ci := aiFlagSurface, aiFlagConversation, aiFlagTurn, aiFlagContextType, aiFlagContextID
	t.Cleanup(func() {
		aiFlagSurface, aiFlagConversation, aiFlagTurn, aiFlagContextType, aiFlagContextID = s, c, tu, ct, ci
	})
	aiFlagSurface, aiFlagConversation, aiFlagTurn, aiFlagContextType, aiFlagContextID = surface, conversation, turn, ctxType, ctxID
}

// editorChatToolNames starts the chat server from args the way the provider
// relaunches this binary (`watchtower mcp <args>`) and lists its tools.
func editorChatToolNames(t *testing.T, args []string) map[string]bool {
	t.Helper()
	resetMCPFlags(t)
	resetMCPChatBindingFlags(t)
	// Parse sets only the flags it sees: start from the defaults.
	mcpFlagSurface, mcpFlagConversation, mcpFlagTurn, mcpFlagContextType, mcpFlagContextID = "main", 0, "", "", ""
	require.NoError(t, mcpCmd.Flags().Parse(args))
	require.True(t, mcpFlagChat)
	database := openMCPTestDB(t)
	opts, err := mcpModeOptions(&config.Config{ActiveWorkspace: "test-ws"}, database, mcpFlagTurn, nil)
	require.NoError(t, err)
	names, _ := localToolNames(t, database, opts)
	return names
}

func TestAiQuery_PassesAutomationEditorSurfaceAndContext(t *testing.T) {
	setAIChatFlags(t, tools.AutomationEditorSurface, 3, "t1", "automation", "7")
	got := strings.Join(chatMCPArgs(), " ")
	assert.Contains(t, got, "--surface automation_editor")
	assert.Contains(t, got, "--context-type automation --context-id 7")
	names := editorChatToolNames(t, chatMCPArgs())
	assert.True(t, names["draft_automation"] && names["save_automation"])
	assert.Equal(t, "automation", mcpFlagContextType)
	assert.Equal(t, "7", mcpFlagContextID)
}

// A new draft (the "New automation" sheet) has no automation yet: the editor
// surface without a context is accepted and mounts the same tools.
func TestAiQuery_AutomationEditorWithoutContextForNewDraft(t *testing.T) {
	setAIChatFlags(t, tools.AutomationEditorSurface, 3, "t1", "automation", "7")
	withContext := editorChatToolNames(t, chatMCPArgs())

	setAIChatFlags(t, tools.AutomationEditorSurface, 3, "t1", "", "")
	args := chatMCPArgs()
	assert.NotContains(t, args, "--context-type")
	assert.NotContains(t, args, "--context-id")
	assert.Equal(t, withContext, editorChatToolNames(t, args))
}
