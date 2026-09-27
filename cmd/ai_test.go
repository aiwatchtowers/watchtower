package cmd

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/spf13/cobra"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/ai"
	"watchtower/internal/chat"
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
		aiFlagSystemPrompt = ""
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
