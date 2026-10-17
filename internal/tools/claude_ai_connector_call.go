package tools

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"watchtower/internal/db"
)

// ClaudeAIConnectorCallTool is the agent_actions tool name of a claude.ai
// connector write the main chat's permission gate holds for the owner's
// Approve (spec 2026-10-16-chat-claude-ai-tools-design D5).
const ClaudeAIConnectorCallTool = "claude_ai_connector_call"

// connectorCallArgs is the schema shape only (jsonschema.For makes input an
// object); Validate and Revise decode into storedConnectorCall.
type connectorCallArgs struct {
	// Server is the connector's display name (e.g. "claude.ai Gmail"), Tool
	// the connector tool the model called, Input the exact arguments the
	// session sends once the owner approved.
	Server string         `json:"server"`
	Tool   string         `json:"tool"`
	Input  map[string]any `json:"input"`
	Reason string         `json:"reason"`
}

// storedConnectorCall decodes the stored args; Input stays raw so an
// approved call is sent byte for byte as the owner saw it.
type storedConnectorCall struct {
	Server string          `json:"server"`
	Tool   string          `json:"tool"`
	Input  json.RawMessage `json:"input"`
	Reason string          `json:"reason"`
}

type connectorCallPatch struct {
	Input json.RawMessage `json:"input"`
}

// NewClaudeAIConnectorCall is the session-applied record of one claude.ai
// connector write (AGENT-03 amendment, #737): External and AlwaysAsk, so no
// trust row or grant ever executes it, and AppliedBySession, so no MCP
// surface lists it and Apply refuses it — only the chat session whose CLI
// request is waiting claims the approved row and runs the call itself.
func NewClaudeAIConnectorCall() *Tool {
	return &Tool{
		Name: ClaudeAIConnectorCallTool,
		Description: "A write through one of the owner's claude.ai connectors, held by the chat session until the " +
			"owner approves it. Recorded by the session's permission gate; never offered to a model.",
		InputSchema:      mustWriteSchema[connectorCallArgs](ClaudeAIConnectorCallTool),
		Access:           AccessWrite,
		External:         true,
		AlwaysAsk:        true,
		AppliedBySession: true,
		Surfaces:         []string{"main"},
		Validate:         validateConnectorCall,
		Revise:           reviseConnectorCall,
		Execute: func(context.Context, *db.DB, Call) (any, error) {
			// Unreachable through the registry (Apply refuses the tool before
			// its claim); a direct caller gets the same refusal.
			return nil, fmt.Errorf("%s %w", ClaudeAIConnectorCallTool, ErrSessionApplied)
		},
	}
}

func validateConnectorCall(_ context.Context, _ *db.DB, raw json.RawMessage) error {
	var a storedConnectorCall
	if err := decodeStrict(raw, &a); err != nil {
		return err
	}
	if strings.TrimSpace(a.Server) == "" || strings.TrimSpace(a.Tool) == "" {
		return &ValidationError{Msg: "server and tool are required"}
	}
	if !isJSONObject(a.Input) {
		return &ValidationError{Msg: "input must be a JSON object"}
	}
	return nil
}

// reviseConnectorCall takes the owner's edit of the call's arguments: the
// patch {"input": {…}} replaces input whole; server and tool are not editable.
func reviseConnectorCall(_ context.Context, _ *db.DB, stored, patch json.RawMessage) (json.RawMessage, error) {
	var p connectorCallPatch
	if err := decodeStrict(patch, &p); err != nil {
		return nil, err
	}
	if !isJSONObject(p.Input) {
		return nil, &ValidationError{Msg: `the edit must be {"input": {…}} with a JSON object`}
	}
	return mergeJSON(stored, map[string]any{"input": p.Input})
}

// isJSONObject reports whether raw is a JSON object (not null, not an array).
func isJSONObject(raw json.RawMessage) bool {
	raw = bytes.TrimSpace(raw)
	return len(raw) > 0 && raw[0] == '{' && json.Valid(raw)
}
