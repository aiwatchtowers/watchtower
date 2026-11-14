package slacklive

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"sync/atomic"
	"time"

	"watchtower/internal/chat"
)

// Result is one probe's verdict. For Claude, Teams holds permalink domain
// labels the caller maps to team ids; for Codex it holds team ids.
type Result struct {
	Provider    string
	Teams       []string
	Status      string
	ErrorClass  string
	ConnectorID string
}

const (
	claudeSlackServer = "claude.ai Slack"
	claudeSearchTool  = "mcp__claude_ai_Slack__slack_search_channels"
)

// Timing knobs; tests shrink them so no test waits on wall-clock.
var (
	connectTimeout = 15 * time.Second
	probeTimeout   = 90 * time.Second
	pollInterval   = 300 * time.Millisecond
)

// ErrNotConnected means the server never reported connected within the timeout.
var ErrNotConnected = errors.New("slack connector not connected")

// WaitConnected polls mcp_status over the claude child's stream until
// "claude.ai Slack" is connected, for at most timeout. lines is the child's
// stdout, write sends a line to its stdin. It returns ErrNotConnected on
// timeout, ctx.Err() on cancel, and an error when lines closes.
func WaitConnected(ctx context.Context, lines <-chan string, write func(string) error, timeout time.Duration) error {
	deadline := time.NewTimer(timeout)
	defer deadline.Stop()
	for n := 1; ; n++ {
		id := fmt.Sprintf("slack-live-status-%d", n)
		if err := write(chat.MCPStatusRequest(id)); err != nil {
			return fmt.Errorf("mcp_status: %w", err)
		}
	answer:
		for {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-deadline.C:
				return ErrNotConnected
			case line, ok := <-lines:
				if !ok {
					return errors.New("claude exited before the connector settled")
				}
				servers, ok := chat.ParseMCPStatus(line, id)
				if !ok {
					if reply := controlErrorFor(line); reply != "" {
						_ = write(reply)
					}
					continue
				}
				for _, s := range servers {
					if s.Name == claudeSlackServer && s.Status == "connected" {
						return nil
					}
				}
				break answer
			}
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-deadline.C:
			return ErrNotConnected
		case <-time.After(pollInterval):
		}
	}
}

type streamEvent struct {
	Type      string `json:"type"`
	Subtype   string `json:"subtype"`
	RequestID string `json:"request_id"`
	IsError   bool   `json:"is_error"`
	Result    string `json:"result"`
	APIKeySrc string `json:"apiKeySource"`
	Request   struct {
		Subtype  string          `json:"subtype"`
		ToolName string          `json:"tool_name"`
		Input    json.RawMessage `json:"input"`
	} `json:"request"`
	Message struct {
		Content json.RawMessage `json:"content"`
	} `json:"message"`
}

type contentBlock struct {
	Type      string          `json:"type"`
	ID        string          `json:"id"`
	Name      string          `json:"name"`
	ToolUseID string          `json:"tool_use_id"`
	IsError   bool            `json:"is_error"`
	Content   json.RawMessage `json:"content"`
}

// textOf flattens a tool_result content (a string or a list of text parts).
func textOf(raw json.RawMessage) string {
	var s string
	if json.Unmarshal(raw, &s) == nil {
		return s
	}
	var parts []struct {
		Text string `json:"text"`
	}
	if json.Unmarshal(raw, &parts) != nil {
		return ""
	}
	var b strings.Builder
	for _, p := range parts {
		b.WriteString(p.Text)
		b.WriteByte('\n')
	}
	return b.String()
}

var slackHost = regexp.MustCompile(`https?://([a-z0-9][a-z0-9-]*)\.slack\.com`)

const claudeProbePrompt = `Call the slack_search_channels tool exactly once with query "a" and limit 1, then reply with the single word done. Do not call any other tool.`

// claudeWriteTools are the connector's write tools, refused twice: the argv
// disallows them and the permission gate denies anything but the one search.
var claudeWriteTools = []string{"slack_send_message", "slack_schedule_message",
	"slack_send_message_draft", "slack_create_canvas", "slack_update_canvas", "slack_add_reaction"}

// claudeArgs is the chat's claude.ai-mode shape (no --strict-mcp-config, the
// connectors load) with user settings skipped and the write tools disallowed.
func claudeArgs() []string {
	disallowed := ClaudeDisallowedWrites()
	return []string{"-p", "--input-format", "stream-json", "--output-format", "stream-json",
		"--verbose", "--no-session-persistence", "--setting-sources", "project,local",
		"--permission-prompt-tool", "stdio", "--disallowedTools", strings.Join(disallowed, ",")}
}

// ClaudeConnectorPrefix is the claude.ai Slack connector's tool prefix as
// the CLI names its tools (mcp__claude_ai_Slack__<name>).
const ClaudeConnectorPrefix = "mcp__claude_ai_Slack__"

// ClaudeDisallowedWrites is the --disallowedTools list of the connector's
// write tools, as the probe passes it (an automation agent() child on Live
// passes the same).
func ClaudeDisallowedWrites() []string {
	out := make([]string, len(claudeWriteTools))
	for i, t := range claudeWriteTools {
		out[i] = ClaudeConnectorPrefix + t
	}
	return out
}

// ControlErrorFor answers a control_request of any subtype but
// can_use_tool with an error, so the CLI never waits on it; "" for any other
// line.
func ControlErrorFor(line string) string { return controlErrorFor(line) }

// controlErrorFor answers a control_request the probe does not serve (any
// subtype but can_use_tool) so the CLI never waits on it; "" for other lines.
func controlErrorFor(line string) string {
	var ev streamEvent
	if json.Unmarshal([]byte(line), &ev) != nil || ev.Type != "control_request" ||
		ev.RequestID == "" || ev.Request.Subtype == "can_use_tool" {
		return ""
	}
	b, _ := json.Marshal(map[string]any{"type": "control_response", "response": map[string]string{
		"subtype": "error", "request_id": ev.RequestID, "error": "not supported by the Slack Live probe"}})
	return string(b)
}

// ProbeClaude runs the real read call through the claude.ai Slack connector.
// A cancelled ctx returns a zero-status Result: the caller writes nothing.
func ProbeClaude(ctx context.Context, claudeBin string, env []string) Result {
	res := Result{Provider: "claude"}
	pctx, cancel := context.WithTimeout(ctx, probeTimeout)
	defer cancel()
	var apiKey atomic.Value
	apiKey.Store("")
	observe := func(line string) {
		var ev streamEvent
		if json.Unmarshal([]byte(line), &ev) == nil && ev.Type == "system" && ev.Subtype == "init" {
			apiKey.Store(ev.APIKeySrc)
		}
	}
	c, err := startChild(pctx, claudeBin, claudeArgs(), env, observe)
	if err != nil {
		res.Status, res.ErrorClass = StatusNotConnected, "cli_missing"
		return res
	}
	defer c.stop()

	connected := false
	readOK := false
	var text strings.Builder
	finish := func() Result {
		if ctx.Err() != nil {
			return Result{Provider: "claude"}
		}
		if pctx.Err() != nil {
			text.WriteString(" timeout")
		}
		if src, _ := apiKey.Load().(string); !readOK && src != "" && src != "none" {
			text.WriteString(" " + SentinelAPIKeyLogin)
		}
		res.Status, res.ErrorClass = classify(text.String(), c.stderr.String(), connected, readOK)
		return res
	}

	if err := WaitConnected(pctx, c.lines, c.write, connectTimeout); err != nil {
		return finish()
	}
	connected = true
	msg, _ := json.Marshal(map[string]any{"type": "user", "message": map[string]any{
		"role": "user", "content": []map[string]string{{"type": "text", "text": claudeProbePrompt}}}})
	if err := c.write(string(msg)); err != nil {
		return finish()
	}

	searchIDs := map[string]bool{}
	for done := false; !done; {
		select {
		case <-pctx.Done():
			return finish()
		case line, ok := <-c.lines:
			if !ok {
				return finish()
			}
			var ev streamEvent
			if json.Unmarshal([]byte(line), &ev) != nil {
				continue
			}
			switch ev.Type {
			case "control_request":
				if reply := controlErrorFor(line); reply != "" {
					_ = c.write(reply)
					continue
				}
				if ev.Request.Subtype != "can_use_tool" || ev.RequestID == "" {
					continue
				}
				if ev.Request.ToolName == claudeSearchTool {
					input := ev.Request.Input
					if len(input) == 0 {
						input = json.RawMessage(`{}`)
					}
					if out, err := chat.PermissionAllow(ev.RequestID, input); err == nil {
						_ = c.write(strings.TrimRight(string(out), "\n"))
						continue
					}
				}
				_ = c.write(strings.TrimRight(string(chat.PermissionDeny(ev.RequestID,
					"Slack Live probe: only slack_search_channels may run")), "\n"))
			case "assistant", "user":
				var blocks []contentBlock
				if json.Unmarshal(ev.Message.Content, &blocks) != nil {
					continue
				}
				for _, b := range blocks {
					switch b.Type {
					case "tool_use":
						if b.Name == claudeSearchTool {
							searchIDs[b.ID] = true
						}
					case "tool_result":
						body := textOf(b.Content)
						switch {
						case b.IsError:
							text.WriteString(" " + body)
						case searchIDs[b.ToolUseID]:
							readOK = true
							if m := slackHost.FindStringSubmatch(body); m != nil && len(res.Teams) == 0 {
								res.Teams = []string{m[1]}
							}
						}
					}
				}
			case "result":
				if ev.IsError {
					text.WriteString(" " + ev.Result)
				}
				done = true
			}
		}
	}
	return finish()
}
