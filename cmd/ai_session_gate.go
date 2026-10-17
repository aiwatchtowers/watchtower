package cmd

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"path/filepath"
	"strings"
	"time"

	"watchtower/internal/ai"
	"watchtower/internal/chat"
	"watchtower/internal/chat/connectorpolicy"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/providers"
	"watchtower/internal/tools"
)

// sessionCallOrphanAge is how old another conversation's open
// claude_ai_connector_call row must be before a starting session fails it:
// no live session waits longer than the 15-minute approval window.
const sessionCallOrphanAge = 20 * time.Minute

// Test seams for the gate's timing (zero = the gate's defaults).
var (
	aiSessionApprovalTimeout time.Duration
	aiSessionGatePoll        time.Duration
)

// claudeAISetup is the main chat's claude.ai mode, decided once per `ai
// session` process from one chat.ClaudeAIAvailability answer: the backend's
// mode, the prompt's section and the publish dir always agree.
type claudeAISetup struct {
	mode   chat.ClaudeAIMode
	prompt chat.ClaudeAIPrompt
	// publish is the conversation's publish dir; nil unless mode.On.
	publish *chat.PublishDir
	// reason is what Settings shows for a main chat without claude.ai
	// tools (the unavailable sidecar); "" when it has them, the surface is
	// not main, or the cause is this conversation's own (its publish dir) —
	// the sidecar is shared by every conversation.
	reason string
}

// resolveClaudeAI decides the session's claude.ai mode. env is the child's
// whole environment (os.Environ() plus whatever ClaudeOptions.Env adds —
// claudeSessionOptions adds nothing), so an API key the app inherited turns
// the mode off. Embedded surfaces get nothing (decision Q2); a Codex or
// Ollama main chat gets the prompt's one line; a Claude main chat gets the
// tools, or the reason it cannot have them.
func resolveClaudeAI(cfg *config.Config, surface string, convID int64, env []string, warn io.Writer) claudeAISetup {
	if surface != "main" {
		return claudeAISetup{}
	}
	provider := providers.ByID(cfg.AI.Provider).ID
	on, reason := chat.ClaudeAIAvailability(env, provider, surface)
	switch {
	case provider != "claude":
		return claudeAISetup{prompt: chat.ClaudeAIPrompt{Kind: chat.ClaudeAIPromptOtherProvider}, reason: reason}
	case !on:
		return claudeAISetup{prompt: chat.ClaudeAIPrompt{Kind: chat.ClaudeAIPromptUnavailable, Reason: reason}, reason: reason}
	}
	publish, err := chat.NewPublishDir(chat.NeutralWorkDir(), convID)
	if err != nil {
		fmt.Fprintf(warn, "claude.ai tools are off: %v\n", err)
		return claudeAISetup{prompt: chat.ClaudeAIPrompt{Kind: chat.ClaudeAIPromptUnavailable,
			Reason: "claude.ai tools are off: the chat's publish folder could not be prepared."}}
	}
	mode := chat.ClaudeAIMode{On: true, Connectors: cfg.AI.ClaudeAI.Connectors}
	return claudeAISetup{mode: mode, publish: publish, prompt: chat.ClaudeAIPrompt{
		Kind: chat.ClaudeAIPromptOn, PublishDir: publish.Path(), Connectors: mode.Connectors}}
}

// connectorsFilePath is the claude.ai connectors sidecar beside the database.
func connectorsFilePath(dbPath string) string {
	return filepath.Join(filepath.Dir(dbPath), chat.ConnectorsFileName)
}

// writeUnavailableConnectors tells Settings why the main chat has no
// claude.ai connectors. Only the main surface writes it: an embedded chat's
// "none" says nothing about the main chat's.
func writeUnavailableConnectors(dbPath string, s claudeAISetup, warn io.Writer) {
	if s.mode.On || s.reason == "" {
		return
	}
	if err := chat.WriteConnectorsFile(connectorsFilePath(dbPath), chat.UnavailableConnectors(time.Now(), s.reason)); err != nil {
		fmt.Fprintf(warn, "claude.ai connectors: %v\n", err)
	}
}

// withClaudeAI turns on claude.ai mode in a Claude session's options: the
// claude.ai built-ins, the switched-off connectors (and every connector's
// sign-in tools) hidden, the sidecar, and the permission gate over sink —
// whose Disabled map is never nil, so the gate always knows the owner's
// switches.
func withClaudeAI(opts chat.ClaudeOptions, w sessionWiring, ext []ai.ExternalMCPServer, sink chat.ActionSink) chat.ClaudeOptions {
	c := w.claudeAI
	disabled := w.cfg.AI.ClaudeAI.DisabledConnectors
	opts.ClaudeAI = c.mode
	opts.Tools = ai.ClaudeAISessionBuiltinTools
	opts.ConnectorsFile = connectorsFilePath(w.dbPath)
	last, err := chat.ReadConnectorsFile(opts.ConnectorsFile)
	if err != nil {
		// Hiding is a convenience; the gate's rules are the enforcement.
		fmt.Fprintf(w.warn, "claude.ai connectors: %v\n", err)
	}
	hidden := ai.ClaudeAISessionDisallowedTools
	if extra := chat.DisabledToolTokens(disabled, last); len(extra) > 0 {
		hidden += "," + strings.Join(extra, ",")
	}
	opts.DisallowedTools = ai.WithExternalDisallowed(hidden, ext)
	opts.Gate = &chat.GateOptions{
		Sink: sink, Publish: c.publish,
		Policy:          connectorpolicy.Policy{Disabled: chat.DisabledConnectorTokens(disabled)},
		ApprovalTimeout: aiSessionApprovalTimeout, PollInterval: aiSessionGatePoll,
	}
	return opts
}

// registrySink is the claude.ai permission gate's chat.ActionSink over the
// tool registry. Every row it proposes carries this `ai session` process's
// random session token, and every per-row call passes it, so no other
// process — a respawn, a resumed or replayed session of the same
// conversation — ever claims, finishes or cancels it (AGENT-05).
type registrySink struct {
	reg      *tools.Registry
	database *db.DB
	token    string
	binding  tools.Binding // the conversation's; TurnID is set per call
	now      func() time.Time
	warn     io.Writer
}

func newRegistrySink(reg *tools.Registry, database *db.DB, conv *db.ChatConversation, warn io.Writer) *registrySink {
	token := rand.Text()
	return &registrySink{reg: reg, database: database, token: token, now: time.Now, warn: warn,
		binding: tools.Binding{
			Surface: "main", ConversationID: conv.ID,
			ContextType: conv.ContextType, ContextID: conv.ContextID,
			SessionToken: token,
		}}
}

var _ chat.ActionSink = (*registrySink)(nil)

// connectorCallRecord is a claude_ai_connector_call row's args.
type connectorCallRecord struct {
	Server string          `json:"server"`
	Tool   string          `json:"tool"`
	Input  json.RawMessage `json:"input"`
	Reason string          `json:"reason"`
}

// ProposeConnectorCall records the call as a pending session-applied row on
// the turn the Desktop is running (its ChatTurnCommand turn id), the only
// way such a row comes to be (Propose refuses the tool).
func (s *registrySink) ProposeConnectorCall(ctx context.Context, c chat.ConnectorCall) (int64, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false) // the card shows the input as the model sent it
	if err := enc.Encode(connectorCallRecord{Server: c.Server, Tool: c.Tool, Input: c.Input, Reason: c.Reason}); err != nil {
		return 0, fmt.Errorf("encoding the connector call: %w", err)
	}
	b := s.binding
	b.TurnID = c.TurnID
	rc, err := s.reg.ProposeSessionCall(ctx, tools.ClaudeAIConnectorCallTool, bytes.TrimSpace(buf.Bytes()), b)
	if err != nil {
		return 0, err
	}
	if rc.Status != "pending" {
		// Unreachable while the tool is AlwaysAsk; a call no owner approved
		// must never look approved to the gate.
		return 0, fmt.Errorf("connector call #%d was recorded %s, not pending", rc.ActionID, rc.Status)
	}
	return rc.ActionID, nil
}

// ActionStatus reads the row's status; a row of another session is
// tools.ErrNotThisSession, never a status this session could act on.
func (s *registrySink) ActionStatus(_ context.Context, id int64) (string, error) {
	row, err := s.database.GetAgentAction(id)
	if err != nil {
		return "", err
	}
	if row == nil {
		return "", fmt.Errorf("#%d: %w", id, tools.ErrNotFound)
	}
	if row.SessionToken != s.token {
		return "", fmt.Errorf("#%d: %w", id, tools.ErrNotThisSession)
	}
	return row.Status, nil
}

// ClaimApproved takes the approved row and returns its stored input — the
// owner's edits included. Any error fails the row if the claim already moved
// it to executing (a failed re-read, an unreadable input): the gate then
// denies the call, and the row must not stay executing until the next
// session start calls its outcome unknown.
func (s *registrySink) ClaimApproved(_ context.Context, id int64) (json.RawMessage, bool, error) {
	row, ok, err := s.reg.ClaimSessionCall(id, s.token)
	if err == nil && !ok {
		return nil, false, nil
	}
	var input json.RawMessage
	if err == nil {
		input, err = approvedInput(row.ArgsJSON)
	}
	if err != nil {
		// Not executing (the claim itself failed) is ErrBadTransition: nothing to undo.
		if ferr := s.reg.FinishSessionCall(id, s.token, "", err.Error()); ferr != nil && !errors.Is(ferr, tools.ErrBadTransition) {
			err = fmt.Errorf("%w (and recording it: %v)", err, ferr)
		}
		return nil, false, err
	}
	return input, true, nil
}

// approvedInput is the input of a stored claude_ai_connector_call row.
func approvedInput(args string) (json.RawMessage, error) {
	var rec connectorCallRecord
	if err := json.Unmarshal([]byte(args), &rec); err != nil {
		return nil, fmt.Errorf("reading the approved input: %w", err)
	}
	if len(bytes.TrimSpace(rec.Input)) == 0 {
		return nil, errors.New("the approved call has no input")
	}
	return rec.Input, nil
}

func (s *registrySink) FinishCall(_ context.Context, id int64, result, callErr string) error {
	return s.reg.FinishSessionCall(id, s.token, result, callErr)
}

func (s *registrySink) CancelCall(_ context.Context, id int64, reason string) (bool, error) {
	_, ok, err := s.reg.CancelSessionCall(id, s.token, reason)
	return ok, err
}

func (s *registrySink) ExpireCall(_ context.Context, id int64, reason string) (bool, error) {
	return s.reg.ExpireSessionCall(id, s.token, reason)
}

// ExpireOrphans fails every open row of this conversation (its previous
// session is gone: this one is starting) and any other conversation's older
// than sessionCallOrphanAge.
func (s *registrySink) ExpireOrphans(context.Context) error {
	n, err := s.reg.ExpireSessionCalls(s.binding.ConversationID, s.now().Add(-sessionCallOrphanAge))
	if n > 0 {
		fmt.Fprintf(s.warn, "claude.ai gate: %d connector call(s) an ended session left open marked failed\n", n)
	}
	return err
}
