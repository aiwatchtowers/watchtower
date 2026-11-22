// Package connectmcp is `watchtower mcp --connect <svc>`: an MCP server that
// mounts only the connect tools of that service's playbooks and forwards each
// call to the Desktop's run socket (agent connect spec §5.3). It refuses
// arguments the playbooks do not allow (a secret kind outside the playbook,
// a label over 80 characters, a secret-looking set_fields key) before
// anything reaches the Desktop; everything else — limits, policy, confirm
// cards, the one-flow rule — is the Desktop's.
package connectmcp

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"slices"

	"github.com/google/jsonschema-go/jsonschema"
	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"

	"watchtower/internal/connectplay"
	"watchtower/internal/connectwire"
)

// version is reported to MCP clients in the server handshake.
const version = "0.1.0"

// labelMax is request_secret's label cap (spec §5.3).
const labelMax = 80

// secretKeyRe matches a field name that may hold a secret; set_fields and a
// company_draft save refuse it (secrets come only through request_secret).
var secretKeyRe = regexp.MustCompile(`(?i)password|token|secret|key`)

// Caller forwards one call to the run (a *connectwire.Client).
type Caller interface {
	Call(ctx context.Context, tool string, args json.RawMessage) (json.RawMessage, error)
}

// Server wraps the SDK server.
type Server struct {
	s *mcpsdk.Server
}

// NewServer mounts Tools of the union of pbs (one service's playbooks; for
// "company" every vendor's) and forwards every call to c.
func NewServer(c Caller, pbs []connectplay.Playbook) *Server {
	s := mcpsdk.NewServer(&mcpsdk.Implementation{Name: "watchtower", Title: "Watchtower connect", Version: version}, nil)
	for _, t := range setOf(pbs...).mcpTools() {
		res, err := t.InputSchema.(*jsonschema.Schema).Resolve(&jsonschema.ResolveOptions{})
		if err != nil {
			panic(fmt.Sprintf("connectmcp: schema of %s: %v", t.Name, err))
		}
		s.AddTool(t, handler(c, t.Name, res))
	}
	return &Server{s: s}
}

// ServeStdio runs the server over stdio until ctx ends or the client leaves.
func (srv *Server) ServeStdio(ctx context.Context) error {
	return srv.s.Run(ctx, &mcpsdk.StdioTransport{})
}

// toolSet is what one or more playbooks allow: tools (KnownTools order),
// secrets, connect_start options and company vendors.
type toolSet struct {
	tools, secrets, options, vendors []string
}

// setOf is the union of the playbooks' tool sets.
func setOf(pbs ...connectplay.Playbook) toolSet {
	var u toolSet
	add := func(dst *[]string, src ...string) {
		for _, s := range src {
			if s != "" && !slices.Contains(*dst, s) {
				*dst = append(*dst, s)
			}
		}
	}
	for _, p := range pbs {
		add(&u.tools, p.Tools...)
		add(&u.secrets, p.Secrets...)
		add(&u.options, p.Options...)
		add(&u.vendors, p.Vendor)
	}
	slices.SortStableFunc(u.tools, func(a, b string) int {
		return slices.Index(connectplay.KnownTools, a) - slices.Index(connectplay.KnownTools, b)
	})
	return u
}

// Tools are exactly pb.Tools with their input schemas, less a tool no call
// could satisfy (request_secret when pb.Secrets is empty).
func Tools(pb connectplay.Playbook) []*mcpsdk.Tool {
	return setOf(pb).mcpTools()
}

func (ts toolSet) mcpTools() []*mcpsdk.Tool {
	var out []*mcpsdk.Tool
	for _, name := range ts.tools {
		if t := tool(name, ts); t != nil {
			out = append(out, t)
		}
	}
	return out
}

func object(props map[string]*jsonschema.Schema, required ...string) *jsonschema.Schema {
	if props == nil {
		props = map[string]*jsonschema.Schema{}
	}
	return &jsonschema.Schema{
		Type: "object", Properties: props, Required: required,
		AdditionalProperties: &jsonschema.Schema{Not: &jsonschema.Schema{}},
	}
}

func enum(desc string, values []string) *jsonschema.Schema {
	e := make([]any, len(values))
	for i, v := range values {
		e[i] = v
	}
	return &jsonschema.Schema{Type: "string", Description: desc, Enum: e}
}

// stringMap is an object of string values (non-secret form fields).
func stringMap(desc string) *jsonschema.Schema {
	return &jsonschema.Schema{Type: "object", Description: desc, AdditionalProperties: &jsonschema.Schema{Type: "string"}}
}

const waitNote = " If it returns {\"state\":\"waiting\"}, call it again: it re-attaches to the same step."

// tool is one connect tool's definition; nil for a name outside KnownTools
// and for one no call could satisfy (request_secret without secrets,
// company_check without vendors).
func tool(name string, ts toolSet) *mcpsdk.Tool {
	var desc string
	var schema *jsonschema.Schema
	switch name {
	case "connect_status":
		desc = "The service's accounts and their status, whether your organization's policy locks it, the running sign-in flow and any half-done setup. Call it first."
		schema = object(nil)
	case "connect_start":
		opts := map[string]*jsonschema.Schema{}
		for _, o := range ts.options {
			opts[o] = &jsonschema.Schema{Description: "connect_start option " + o + " (see the playbook)"}
		}
		desc = "Start the service's sign-in with the playbook's options; the sign-in page opens in the customer's default browser. Returns the flow id. An option that needs the customer's confirm shows a card in the panel first." + waitNote
		schema = object(opts)
	case "connect_wait":
		desc = "Wait up to 45 s for the running flow to end: connected (with the account), failed (with the reason), waiting or timeout." + waitNote
		schema = object(nil)
	case "connect_cancel":
		desc = "Cancel the running sign-in flow."
		schema = object(nil)
	case "request_secret":
		if len(ts.secrets) == 0 {
			return nil // an empty kind enum no call could satisfy
		}
		desc = "Show a secure field card in the panel for the customer to paste a secret into. You never see the secret; you get the result of the step it feeds." + waitNote
		schema = object(map[string]*jsonschema.Schema{
			"kind":  enum("the secret's kind, from the playbook", ts.secrets),
			"label": {Type: "string", Description: "what the card asks for, shown to the customer", MaxLength: new(labelMax)},
		}, "kind", "label")
	case "set_fields":
		desc = "Set non-secret form values (host, port, URL, site, command) for the next connect_start or request_secret. Never a password, token, secret or key: those go through request_secret."
		schema = stringMap("field name → value")
	case "choose":
		desc = "List the boards, teams or spaces to sync, or select some by id."
		schema = object(map[string]*jsonschema.Schema{
			"what":   {Type: "string", Description: "what to list or select: jira_boards, linear_teams or confluence_spaces"},
			"select": {Type: "array", Items: &jsonschema.Schema{Type: "string"}, Description: "ids to select; omit to list"},
		}, "what")
	case "company_draft":
		desc = "Read the company setup draft (secrets show only as set or not), or save a vendor's non-secret values into it. Client secrets go through request_secret."
		schema = object(map[string]*jsonschema.Schema{
			"vendor": enum("the vendor whose values to save", ts.vendors),
			"fields": stringMap("field name → value; omit to read the draft"),
		})
	case "company_check":
		if len(ts.vendors) == 0 {
			return nil
		}
		desc = "Check a vendor's company setup; it may open a sign-in the customer approves." + waitNote
		schema = object(map[string]*jsonschema.Schema{"vendor": enum("the vendor to check", ts.vendors)}, "vendor")
	case "company_publish":
		desc = "Publish the company setup. The panel shows a confirm card, then a card for the Slack configuration token." + waitNote
		schema = object(nil)
	case "slack_live_probe":
		desc = "Check Slack Live (the Slack connector of the customer's own Claude or ChatGPT account): ok, not_connected, needs_admin, no_plan or unavailable." + waitNote
		schema = object(map[string]*jsonschema.Schema{"provider": enum("claude or codex", []string{"claude", "codex"})}, "provider")
	default:
		return nil
	}
	return &mcpsdk.Tool{Name: name, Description: desc, InputSchema: schema}
}

// handler validates a call's arguments and forwards it.
func handler(c Caller, name string, schema *jsonschema.Resolved) mcpsdk.ToolHandler {
	return func(ctx context.Context, req *mcpsdk.CallToolRequest) (*mcpsdk.CallToolResult, error) {
		args := req.Params.Arguments
		if len(args) == 0 {
			args = json.RawMessage(`{}`)
		}
		if err := validate(name, schema, args); err != nil {
			return errResult(err), nil
		}
		res, err := c.Call(ctx, name, args)
		if err != nil {
			return errResult(err), nil
		}
		return &mcpsdk.CallToolResult{Content: []mcpsdk.Content{&mcpsdk.TextContent{Text: string(res)}}}, nil
	}
}

// validate checks args against the schema, then refuses secret-looking
// field names.
func validate(name string, schema *jsonschema.Resolved, args json.RawMessage) error {
	var v any
	if err := json.Unmarshal(args, &v); err != nil {
		return &connectwire.Error{Code: connectwire.CodeBadArgs, Message: "the arguments are not valid JSON"}
	}
	if err := schema.Validate(v); err != nil {
		return &connectwire.Error{Code: connectwire.CodeBadArgs, Message: err.Error()}
	}
	var fields map[string]any
	switch name {
	case "set_fields":
		fields, _ = v.(map[string]any)
	case "company_draft":
		fields, _ = v.(map[string]any)["fields"].(map[string]any)
	}
	for k := range fields {
		if secretKeyRe.MatchString(k) {
			return &connectwire.Error{Code: connectwire.CodeBadArgs, Message: fmt.Sprintf("%s cannot carry %q: send a password, token, secret or key with request_secret", name, k)}
		}
	}
	return nil
}

// errResult is a tool error: "<code>: <message>" for a wire error.
func errResult(err error) *mcpsdk.CallToolResult {
	msg := err.Error()
	var we *connectwire.Error
	if !errors.As(err, &we) {
		msg = connectwire.CodeFailed + ": " + msg
	}
	return &mcpsdk.CallToolResult{IsError: true, Content: []mcpsdk.Content{&mcpsdk.TextContent{Text: msg}}}
}
