// Package connectwire is the wire between `watchtower mcp --connect <svc>`
// and the per-run socket the Desktop serves for one connect assistant run
// (agent connect spec §5.3): JSON lines over a Unix socket, a hello line
// first, then one request and one response per connect tool call.
//
// The Swift ConnectWire implements the same contract; testdata/
// wire_cases.json pins every line shape and both sides decode it.
package connectwire

import (
	"encoding/json"
	"time"
)

// The run's socket path and 256-bit token reach the MCP server through its
// environment, never its argv.
const (
	SocketEnv = "WATCHTOWER_CONNECT_SOCKET"
	TokenEnv  = "WATCHTOWER_CONNECT_TOKEN"
)

// ProtocolVersion is Hello.V.
const ProtocolVersion = 1

// WaitBudget is how long the Desktop holds a call that waits on the
// customer or a flow (connect_wait, request_secret, a confirm-gated call,
// company_check) before it answers {"state":"waiting"}; the agent then calls
// again and re-attaches to the same step (spec §5.3). The Desktop (Tasks 8
// and 9) uses this value, never CallTimeout.
const WaitBudget = 45 * time.Second

// CallTimeout is the MCP side's read deadline for one call: longer than
// WaitBudget plus the socket and parsing slack, so a waiting answer always
// arrives, and shorter than Codex's 60-s MCP tool timeout.
const CallTimeout = 55 * time.Second

// MaxLine caps one JSON line in either direction.
const MaxLine = 1 << 20

// Error codes.
const (
	CodeBusy        = "busy"
	CodePolicy      = "policy"
	CodeLimit       = "limit"
	CodeUnknownTool = "unknown_tool"
	CodeBadArgs     = "bad_args"
	CodeDeclined    = "declined"
	CodeClosed      = "closed"
	CodeFailed      = "failed"
)

// Hello is the connection's first line, from the MCP server.
type Hello struct {
	V       int    `json:"v"`
	Token   string `json:"token"`
	Service string `json:"service"`
}

// HelloReply answers a Hello: {"ok":true}, or {"ok":false,"error":{…}} when
// the run admits no second peer (busy). A bad token gets no reply: the
// Desktop closes the socket.
type HelloReply struct {
	OK    bool   `json:"ok"`
	Error *Error `json:"error,omitempty"`
}

// Request is one tool call.
type Request struct {
	ID   int64           `json:"id"`
	Tool string          `json:"tool"`
	Args json.RawMessage `json:"args"`
}

// Response answers the Request with the same ID: a Result or an Error.
type Response struct {
	ID     int64           `json:"id"`
	Result json.RawMessage `json:"result,omitempty"`
	Error  *Error          `json:"error,omitempty"`
}

// Error is a refused or failed call; Code is one of the Code* constants.
type Error struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func (e *Error) Error() string {
	if e.Message == "" {
		return e.Code
	}
	return e.Code + ": " + e.Message
}

// The result shapes below are what the Desktop puts in Response.Result. The
// MCP server forwards a result untouched; these types pin the contract
// (wire_cases.json decodes into them strictly).

// Status is connect_status.
type Status struct {
	Service      string    `json:"service"`
	Accounts     []Account `json:"accounts"`
	PolicyLocked bool      `json:"policy_locked"`
	// Flow is the running flow, null when none.
	Flow *Flow `json:"flow"`
	// Setup is a half-done vendor setup (Slack "pending_create"), null when
	// none.
	Setup *Setup `json:"setup"`
}

// Account is one account of the service.
type Account struct {
	Name   string `json:"name"`
	Status string `json:"status"`
}

// Flow is a running sign-in flow.
type Flow struct {
	ID    string `json:"id"`
	State string `json:"state"`
}

// Setup is a half-done setup stage.
type Setup struct {
	Stage string `json:"stage"`
}

// Started is connect_start's own result.
type Started struct {
	FlowID string `json:"flow_id"`
}

// Waited is connect_wait: state connected (Account), failed (Reason),
// waiting or timeout.
type Waited struct {
	State   string `json:"state"`
	Account string `json:"account,omitempty"`
	Reason  string `json:"reason,omitempty"`
}

// SecretSent is request_secret: state sent (Result is the verb's result,
// never the secret), waiting, cancelled or timeout.
type SecretSent struct {
	State  string          `json:"state"`
	Result json.RawMessage `json:"result,omitempty"`
}

// Pending replaces the own result of a call that waits on the customer: a
// confirm-gated call (connect_start with a confirm option, company_publish)
// or company_check's sign-in. State is waiting, declined, cancelled or
// timeout (the step's 15-minute budget is spent).
type Pending struct {
	State string `json:"state"`
}

// Choices is choose.
type Choices struct {
	Items []Choice `json:"items"`
}

// Choice is one board, team or space.
type Choice struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Selected bool   `json:"selected"`
}

// CompanyDraft is company_draft: the wizard draft without its secrets, only
// whether each is set.
type CompanyDraft struct {
	Company string                 `json:"company"`
	Vendors map[string]VendorDraft `json:"vendors"`
}

// VendorDraft is one vendor's part of the draft.
type VendorDraft struct {
	ClientID        string `json:"client_id,omitempty"`
	Site            string `json:"site,omitempty"`
	ClientSecretSet bool   `json:"client_secret_set"`
}

// CompanyChecked is company_check's own result: ok (Account is the
// signed-in address, empty for a dry check), admin_consent
// (AdminConsentURL for the tenant's IT admin) or replace_needed (check
// again: the panel asks the customer to replace the stored app). A failed
// check is an error.
type CompanyChecked struct {
	Result          string `json:"result"`
	Account         string `json:"account,omitempty"`
	AdminConsentURL string `json:"admin_consent_url,omitempty"`
}

// CompanyPublished is company_publish's own result: ok (the link is on the
// Slack app's About page) or no_slack. Slug names the stored company; the
// link and code stay on the wizard's Publish page. A failed Publish is an
// error.
type CompanyPublished struct {
	Result string `json:"result"`
	Slug   string `json:"slug"`
}

// Done is the result of a call with nothing to return (connect_cancel,
// set_fields): {}.
type Done struct{}
