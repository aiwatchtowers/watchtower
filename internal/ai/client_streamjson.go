package ai

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"slices"
	"strings"
	"sync"
	"time"

	"watchtower/internal/fsutil"
	"watchtower/internal/logredact"
	"watchtower/internal/providers"
	"watchtower/internal/streamline"
)

// streamDrainGrace bounds how long a stream-json child may keep its output
// open after its result event and the end of its input; a var for tests.
var streamDrainGrace = 5 * time.Second

// StreamJSONHooks drive a stream-json run (SetStreamJSONInput). The caller
// owns the protocol answers, so this package needs no chat or connector code.
type StreamJSONHooks struct {
	// ExtraAllowed are appended to --allowedTools (e.g. the Slack connector's
	// read tools as mcp__claude_ai_Slack__<name>).
	ExtraAllowed []string
	// ExtraDisallowed are appended to --disallowedTools.
	ExtraDisallowed []string
	// WaitReady runs once the child started, before the user message is
	// sent: lines is the child's stdout (closed when it ends), write sends
	// one line to its stdin. An error ends the run with it. nil = none.
	WaitReady func(ctx context.Context, lines <-chan string, write func(string) error) error
	// OnControl answers one control_request line with the line to write
	// back ("" = no answer). Every tool not in --allowedTools reaches it as
	// a can_use_tool request (--permission-prompt-tool stdio), so it must
	// deny what it does not know. nil = every request is left unanswered,
	// which the CLI never gets past: set it.
	OnControl func(line string) string
	// OnToolResult observes each finished tool call: its name as the model
	// called it, whether it failed, and its result text. nil = none.
	OnToolResult func(name string, isError bool, text string)
}

// SetStreamJSONInput turns the stream-json input mode on for QuerySync (an
// automation agent() child with slack:live, #1709): the CLI starts with
// --input-format stream-json --output-format stream-json --verbose
// --permission-prompt-tool stdio and without --strict-mcp-config, so the
// account's claude.ai connectors load; the hooks (SetStreamJSONHooks) wait
// for the connector and answer every permission prompt. Off (the default)
// keeps every argv byte-for-byte as before.
func (c *Client) SetStreamJSONInput(on bool) { c.streamJSON = on }

// SetStreamJSONHooks sets the stream-json run's hooks (SetStreamJSONInput).
func (c *Client) SetStreamJSONHooks(h StreamJSONHooks) { c.streamHooks = h }

// withStreamTools appends extra to a comma-separated tool list in
// stream-json mode only.
func (c *Client) withStreamTools(list string, extra []string) string {
	if !c.streamJSON || len(extra) == 0 {
		return list
	}
	if list == "" {
		return strings.Join(extra, ",")
	}
	return list + "," + strings.Join(extra, ",")
}

// streamJSONArgs turns the batch argv into the stream-json one: no
// --strict-mcp-config (the claude.ai connectors load), the stream-json input
// and the permission prompts on stdio. --output-format stream-json and
// --verbose come from the caller's output format.
func (c *Client) streamJSONArgs(args []string) []string {
	args = slices.DeleteFunc(args, func(a string) bool { return a == "--strict-mcp-config" })
	return append(args, "--input-format", "stream-json", "--permission-prompt-tool", "stdio")
}

// streamUserLine is one user message in the stream-json input protocol.
func streamUserLine(text string) string {
	b, _ := json.Marshal(map[string]any{"type": "user", "message": map[string]any{
		"role": "user", "content": []map[string]string{{"type": "text", "text": text}}}})
	return string(b)
}

// queryStreamJSON is QuerySync in stream-json mode: start the child, let
// WaitReady settle the connectors, send the message, answer control
// requests through OnControl until the result event, then end the input.
func (c *Client) queryStreamJSON(ctx context.Context, systemPrompt, userMessage string) (text string, _ *Usage, err error) {
	h := c.streamHooks
	args, _, payloads := c.buildArgs(systemPrompt, userMessage, "stream-json")
	runCtx, cancelRun := context.WithCancel(ctx)
	defer cancelRun()
	cmd := exec.CommandContext(runCtx, c.claudeCmd, args...)
	_, closePayloads, err := fsutil.AttachPayloads(cmd, payloads...)
	if err != nil {
		return "", nil, err
	}
	defer closePayloads()
	reap := ConfigureChild(cmd)
	defer reap()
	cmd.Dir = c.workDir()
	cmd.Env = c.childEnviron()
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return "", nil, fmt.Errorf("creating stdin pipe: %w", err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return "", nil, fmt.Errorf("creating stdout pipe: %w", err)
	}
	var stderrBuf strings.Builder
	cmd.Stderr = &limitedWriter{w: &stderrBuf, limit: 64 * 1024}

	start := time.Now()
	var result *cliResponse
	defer func() {
		var u *resultUsage
		if result != nil {
			u = &result.resultUsage
		}
		recordClaude(ctx, c.model, u, cmd.Process != nil, start, err, systemPrompt+userMessage, text)
	}()
	if err := cmd.Start(); err != nil {
		return "", nil, classifyError(err, "")
	}
	closePayloads()

	lines := make(chan string)
	done := make(chan struct{})
	reader := streamline.NewWithLimit(stdout, maxStreamLine)
	var readWG sync.WaitGroup
	readWG.Add(1)
	go func() {
		defer readWG.Done()
		defer close(lines)
		for {
			line, err := reader.Next()
			if err != nil {
				return
			}
			if len(line) == 0 {
				continue
			}
			select {
			case lines <- string(line):
			case <-done:
				return
			}
		}
	}()
	var stdinMu sync.Mutex
	stdinOpen := true
	write := func(line string) error {
		stdinMu.Lock()
		defer stdinMu.Unlock()
		if !stdinOpen {
			return errors.New("claude input is closed")
		}
		_, err := io.WriteString(stdin, line+"\n")
		return err
	}
	closeInput := func() {
		stdinMu.Lock()
		defer stdinMu.Unlock()
		if stdinOpen {
			stdinOpen = false
			_ = stdin.Close()
		}
	}
	// stop ends the child and reaps the reader before returning.
	stop := func() {
		closeInput()
		cancelRun()
		close(done)
		_ = cmd.Wait()
		readWG.Wait()
	}

	if h.WaitReady != nil {
		if werr := h.WaitReady(runCtx, lines, write); werr != nil {
			stop()
			return "", nil, werr
		}
	}
	if werr := write(streamUserLine(userMessage)); werr != nil {
		stop()
		return "", nil, classifyError(werr, stderrBuf.String())
	}

	names := map[string]string{} // tool_use id → name
	for result == nil {
		var line string
		var ok bool
		select {
		case <-ctx.Done():
			stop()
			return "", nil, ctx.Err()
		case line, ok = <-lines:
		}
		if !ok {
			break
		}
		result = c.handleStreamLine(line, names, write)
	}
	closeInput()
	// Drain to EOF so Wait never races the reader; a child that does not
	// end within streamDrainGrace of its result is cancelled (its group
	// interrupted, then killed), which ends the output.
	grace := time.NewTimer(streamDrainGrace)
	for open := true; open; {
		select {
		case _, open = <-lines:
		case <-grace.C:
			cancelRun()
		}
	}
	grace.Stop()
	close(done)
	waitErr := cmd.Wait()
	readWG.Wait()

	switch {
	case result != nil && result.IsError:
		return "", nil, providers.ClaudeResultFailure(result.Type, result.Subtype, result.IsError, result.Error, result.Result, result.limit,
			withCause(logredact.Errorf("claude returned error (subtype=%s): %s", result.Subtype, envelopeMessage(result.Result)), waitErr))
	case waitErr != nil && result == nil:
		return "", nil, classifyError(waitErr, stderrBuf.String())
	case result == nil:
		return "", nil, noResultFailure(errNoResultEvent, stderrBuf.String())
	}
	return strings.TrimRight(result.Result, "\n"), &Usage{Tokens: result.tokens()}, nil
}

// handleStreamLine answers a control request, reports finished tool calls
// and returns the result event when line is one.
func (c *Client) handleStreamLine(line string, names map[string]string, write func(string) error) *cliResponse {
	h := c.streamHooks
	var ev streamEvent
	if json.Unmarshal([]byte(line), &ev) != nil {
		return nil
	}
	switch ev.Type {
	case "control_request":
		if h.OnControl != nil {
			if reply := h.OnControl(line); reply != "" {
				_ = write(reply)
			}
		}
	case "assistant", "user":
		if ev.Message == nil {
			return nil
		}
		for _, b := range ev.Message.Content {
			switch b.Type {
			case "tool_use":
				names[b.ID] = b.Name
			case "tool_result":
				if h.OnToolResult != nil {
					h.OnToolResult(names[b.ToolUseID], b.IsError, ToolResultText(b.Content))
				}
				delete(names, b.ToolUseID)
			}
		}
	case "result":
		var resp cliResponse
		if json.Unmarshal([]byte(line), &resp) != nil {
			return nil
		}
		resp.limit = providers.ClaudeResultLimit([]byte(line))
		return &resp
	}
	return nil
}
