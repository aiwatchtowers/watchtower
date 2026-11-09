package cmd

import (
	"context"
	"encoding/json"
	"fmt"
	"io"

	"watchtower/internal/agentkind"
	"watchtower/internal/sessionagent"
)

// hookEvent is a workbench hook's input, Claude Code's or Codex's, in one
// shape: the session adapter's Event (spec 2026-11-05 §3.5).
type hookEvent = sessionagent.Event

// stopHookInput is the Stop hook's input: the shared hook event.
type stopHookInput = hookEvent

// parseHookEvent decodes one hook input of agent through its session
// adapter (sessionagent.Adapter.Normalize). Empty input (a manual run with
// stdin closed) is io.EOF, a clean exit; input that is no JSON object is an
// error. An unknown event decodes: each hook ignores events it does not
// handle.
func parseHookEvent(agent agentkind.Kind, raw []byte) (hookEvent, error) {
	a, ok := sessionagent.For(agent)
	if !ok {
		return hookEvent{}, fmt.Errorf("unknown agent %q", briefClip(string(agent), 40))
	}
	return a.Normalize(raw)
}

// readHookEvent reads one hook input of agent from stdin, at most limit
// bytes and until ctx ends (readHookInputLimit), and decodes it.
func readHookEvent(ctx context.Context, stdin io.Reader, limit int64, agent agentkind.Kind) (hookEvent, error) {
	raw, err := readHookInputLimit[json.RawMessage](ctx, stdin, limit)
	if err != nil {
		return hookEvent{}, err
	}
	return parseHookEvent(agent, raw)
}
