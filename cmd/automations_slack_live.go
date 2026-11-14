package cmd

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"slices"
	"strings"
	"sync"
	"time"

	"watchtower/internal/ai"
	"watchtower/internal/chat"
	"watchtower/internal/codex"
	"watchtower/internal/db"
	"watchtower/internal/slacklive"
)

// Live Slack in an automation's agent() child (#1709 spec §4): a recipe with
// slack:live lets its agent read Slack through the owner's own connector —
// Claude's claude.ai Slack over the stream-json launch, Codex's Slack app
// through the read-only apps allow-list. Writes are never offered: the
// connector's write tools are disallowed on argv and denied at the
// permission gate (Watchtower's send_slack_message is the only send path,
// a proposal under AUTO-02).

// agentSlackConnectWait bounds the wait for claude.ai Slack to connect
// before the instruction is sent (the probe's 15 s); a var for tests.
var agentSlackConnectWait = 15 * time.Second

// agentSlackLivePromptLine is added to the agent's system prompt on a
// slack:live run only.
const agentSlackLivePromptLine = " The Slack connector's tools only read here; " +
	"to post to Slack use the send_slack_message tool when you have it."

// agentSlackWriteDenied is the gate's answer to a connector write.
const agentSlackWriteDenied = "use send_slack_message"

// agentToolNotAllowed is the gate's answer to any other tool outside the
// agent's allowed set (another claude.ai connector, a built-in).
const agentToolNotAllowed = "this tool is not available to this automation"

// agentSlackLive is one agent() child's Live Slack bookkeeping: whether it
// called a connector read tool, the writes the gate denied, and the status
// each finished connector call writes (as the chat's watcher does).
type agentSlackLive struct {
	database *db.DB // nil = no status written
	provider string
	now      func() time.Time
	classify func(provider, text string, connected, readOK bool) (string, string)

	mu     sync.Mutex
	used   bool
	denied []string
}

func newAgentSlackLive(database *db.DB, provider string) *agentSlackLive {
	return &agentSlackLive{database: database, provider: provider, now: time.Now, classify: slacklive.Classify}
}

// result is what the run reports back: UsedSlackLive and the denied writes.
func (l *agentSlackLive) result() (used bool, denied []string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.used, slices.Clone(l.denied)
}

// readEnded records one finished connector read call.
func (l *agentSlackLive) readEnded(ok bool, text string) {
	l.mu.Lock()
	l.used = true
	l.mu.Unlock()
	if l.database != nil {
		recordSlackLiveUse(l.database, l.classify, l.provider, text, ok, l.now())
	}
}

// claudeReadTool is the bare name of a claude.ai Slack read tool, "" when
// name is not one.
func claudeReadTool(name string) string {
	bare, ok := strings.CutPrefix(name, slacklive.ClaudeConnectorPrefix)
	if !ok || !slices.Contains(slacklive.ReadTools, bare) {
		return ""
	}
	return bare
}

// claudeHooks are the stream-json hooks of a Claude agent() child on Live:
// the read tools allowed, the probe's six writes disallowed, the connector
// wait, the permission gate and the use bookkeeping.
func (l *agentSlackLive) claudeHooks() ai.StreamJSONHooks {
	allowed := make([]string, len(slacklive.ReadTools))
	for i, t := range slacklive.ReadTools {
		allowed[i] = slacklive.ClaudeConnectorPrefix + t
	}
	return ai.StreamJSONHooks{
		ExtraAllowed:    allowed,
		ExtraDisallowed: slacklive.ClaudeDisallowedWrites(),
		WaitReady: func(ctx context.Context, lines <-chan string, write func(string) error) error {
			err := slacklive.WaitConnected(ctx, lines, write, agentSlackConnectWait)
			if errors.Is(err, slacklive.ErrNotConnected) {
				// The agent runs without Slack; its instruction may not need it.
				log.Printf("automation agent: the claude.ai Slack connector did not connect within %s", agentSlackConnectWait)
				return nil
			}
			return err
		},
		OnControl: l.claudeControl,
		OnToolResult: func(name string, isError bool, text string) {
			if claudeReadTool(name) != "" {
				l.readEnded(!isError, text)
			}
		},
	}
}

// claudeControl is the permission gate: a can_use_tool request for a Slack
// connector read tool (allowed on argv already) is allowed; one for any
// other connector Slack tool is a write and denied with
// agentSlackWriteDenied, and recorded for the run log; anything else is
// denied. Every other control request gets an error answer.
func (l *agentSlackLive) claudeControl(line string) string {
	var ev struct {
		Type      string `json:"type"`
		RequestID string `json:"request_id"`
		Request   struct {
			Subtype  string          `json:"subtype"`
			ToolName string          `json:"tool_name"`
			Input    json.RawMessage `json:"input"`
		} `json:"request"`
	}
	if json.Unmarshal([]byte(line), &ev) != nil || ev.Type != "control_request" || ev.RequestID == "" {
		return ""
	}
	if ev.Request.Subtype != "can_use_tool" {
		return slacklive.ControlErrorFor(line)
	}
	name := ev.Request.ToolName
	if claudeReadTool(name) != "" {
		input := ev.Request.Input
		if len(input) == 0 {
			input = json.RawMessage(`{}`)
		}
		if out, err := chat.PermissionAllow(ev.RequestID, input); err == nil {
			return strings.TrimRight(string(out), "\n")
		}
	}
	reason := agentToolNotAllowed
	if bare, isSlack := strings.CutPrefix(name, slacklive.ClaudeConnectorPrefix); isSlack && claudeReadTool(name) == "" {
		reason = agentSlackWriteDenied
		l.mu.Lock()
		l.denied = append(l.denied, bare)
		l.mu.Unlock()
	}
	return strings.TrimRight(string(chat.PermissionDeny(ev.RequestID, reason)), "\n")
}

// codexReadTool is the bare name of a Codex Slack app read tool, "" when
// the call is not one: server codex_apps, tool "slack.<name>" (or a bare
// "<name>"), <name> in slacklive.ReadTools — the only Slack tools the run's
// allow-list leaves visible.
func codexReadTool(call codex.ToolCall) string {
	if call.Server != "codex_apps" {
		return ""
	}
	bare := strings.TrimPrefix(call.Tool, "slack.")
	if !slices.Contains(slacklive.ReadTools, bare) {
		return ""
	}
	return bare
}

// observeCodex is the Codex child's tool-call observer.
func (l *agentSlackLive) observeCodex(call codex.ToolCall) {
	if codexReadTool(call) != "" {
		l.readEnded(!call.Failed, call.Text)
	}
}

// codexAgentSlackApps is the read-only Slack app allow-list of a Codex
// agent() child on Live, for the run's own CODEX_HOME (the home codex
// loads; its auth.json links the owner's): nil when the login is not a
// ChatGPT one, the owner's newest Codex probe is not ok with a connector id,
// or the allow-list cannot be built (fail closed: no apps).
func codexAgentSlackApps(database *db.DB, home string) []string {
	if database == nil {
		return nil
	}
	rows, err := database.ListSlackLiveStatus()
	if err != nil {
		log.Printf("automation agent: reading the Slack Live status: %v", err)
		return nil
	}
	id := codexSlackConnector(rows, home)
	if id == "" {
		return nil
	}
	overrides, err := codex.ReadOnlyAppOverrides(home, id, slacklive.ReadTools)
	if err != nil {
		log.Printf("automation agent: no Slack apps for this run: %v", err)
		return nil
	}
	return overrides
}
