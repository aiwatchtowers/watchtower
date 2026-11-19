package slacklive

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/chat"
	"watchtower/internal/codex"
	"watchtower/internal/slackconnector"
)

var updateStepNames = flag.Bool("update", false, "rewrite testdata/slack_step_names.json")

// stepNamesFile is the LIVE-01 fixture the Swift guard reads
// (LiveSlack01GuardTests): every Slack connector tool's step name as the
// chat's translators produce it, so the Desktop's mark matches what Go
// really sends.
const stepNamesFile = "testdata/slack_step_names.json"

type stepNames struct {
	Claude []string `json:"claude"`
	Codex  []string `json:"codex"`
}

// claudeStepName runs one tool_use through the Claude stream translator, as
// the chat's warm session does, and returns the tool_start event's name.
func claudeStepName(t *testing.T, tool string) string {
	t.Helper()
	tr := chat.NewClaudeTranslator(func() string { return "t1" })
	var names []string
	for _, line := range []string{
		`{"type":"stream_event","event":{"type":"message_start","message":{"id":"m1","usage":{}}}}`,
		`{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"` +
			slackconnector.ClaudeToolPrefix + tool + `","input":{}}}}`,
		`{"type":"stream_event","event":{"type":"content_block_stop","index":0}}`,
	} {
		evs, err := tr.Feed([]byte(line))
		require.NoError(t, err)
		for _, e := range evs {
			if e.Type == chat.EventToolStart {
				names = append(names, e.Name)
			}
		}
	}
	require.Len(t, names, 1, tool)
	return names[0]
}

// codexStepNames runs a real `codex exec` mcp_tool_call stream (a stub CLI
// printing it) through the codex client and the chat's ChunkEvents, as a
// Codex chat turn does, and returns the tool_start names in order.
func codexStepNames(t *testing.T, tools []string) []string {
	t.Helper()
	var lines []string
	for i, tool := range tools {
		item := fmt.Sprintf(`"id":"c%d","type":"mcp_tool_call","server":"codex_apps","tool":"slack.%s","arguments":{}`, i, tool)
		lines = append(lines,
			`{"type":"item.started","item":{`+item+`,"status":"in_progress"}}`,
			`{"type":"item.completed","item":{`+item+`,"result":{"content":[{"type":"text","text":"ok"}]},"status":"completed"}}`)
	}
	lines = append(lines, `{"type":"item.completed","item":{"id":"m","type":"agent_message","text":"done"}}`,
		`{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}`)
	bin := filepath.Join(t.TempDir(), "codex")
	script := "#!/bin/sh\n[ \"$1\" = \"--version\" ] && { echo \"codex-cli 0.145.0\"; exit 0; }\ncat >/dev/null\ncat <<'__EOF__'\n" + strings.Join(lines, "\n") + "\n__EOF__\n"
	require.NoError(t, os.WriteFile(bin, []byte(script), 0o755))

	c := codex.NewClient("m", "", bin)
	c.EmitToolEvents() // as the chat's codex backend does
	chunks, errs, _ := c.Query(t.Context(), "sys", "msg", "")
	var names []string
	for ch := range chunks {
		for _, e := range chat.ChunkEvents("t1", ch) {
			if e.Type == chat.EventToolStart {
				names = append(names, e.Name)
			}
		}
	}
	require.NoError(t, <-errs)
	return names
}

// TestLIVE01_StepNamesFixture pins the step names a Slack connector call
// gets in the chat, for every connector tool on Claude (reads and writes:
// the chat may run a write after approval) and every read tool on Codex
// (its allow-list shows no write), in the fixture the Swift LIVE-01 guard
// marks against. -update rewrites it.
// BEHAVIOR LIVE-01 — see docs/inventory/chat.md
func TestLIVE01_StepNamesFixture(t *testing.T) {
	var got stepNames
	for _, tool := range append(append([]string{}, slackconnector.ReadTools...), slackconnector.WriteTools...) {
		got.Claude = append(got.Claude, claudeStepName(t, tool))
	}
	got.Codex = codexStepNames(t, slackconnector.ReadTools)
	require.Len(t, got.Codex, len(slackconnector.ReadTools))
	for _, n := range got.Claude {
		assert.True(t, strings.HasPrefix(n, ClaudeStepPrefix), n)
	}
	for _, n := range got.Codex {
		assert.True(t, strings.HasPrefix(n, CodexStepPrefix), n)
	}

	data, err := json.MarshalIndent(got, "", "  ")
	require.NoError(t, err)
	data = append(data, '\n')
	if *updateStepNames {
		require.NoError(t, os.WriteFile(stepNamesFile, data, 0o644))
	}
	want, err := os.ReadFile(stepNamesFile)
	require.NoError(t, err, "run with -update to write the fixture")
	assert.Equal(t, string(want), string(data), "the chat's Slack step names changed: run -update and check the Swift LIVE-01 guard")
}
