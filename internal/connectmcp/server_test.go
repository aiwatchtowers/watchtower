package connectmcp

import (
	"context"
	"encoding/json"
	"slices"
	"strings"
	"sync"
	"testing"

	"github.com/google/jsonschema-go/jsonschema"
	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/connectplay"
	"watchtower/internal/connectwire"
)

// fakeCaller records forwarded calls and answers with result or err.
type fakeCaller struct {
	mu     sync.Mutex
	calls  []string
	args   []string
	result string
	err    error
}

func (f *fakeCaller) Call(_ context.Context, tool string, args json.RawMessage) (json.RawMessage, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = append(f.calls, tool)
	f.args = append(f.args, string(args))
	if f.err != nil {
		return nil, f.err
	}
	return json.RawMessage(f.result), nil
}

func (f *fakeCaller) forwarded() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return slices.Clone(f.calls)
}

func session(t *testing.T, c Caller, pbs ...connectplay.Playbook) *mcpsdk.ClientSession {
	t.Helper()
	ctx := context.Background()
	srv := NewServer(c, pbs)
	st, ct := mcpsdk.NewInMemoryTransports()
	ss, err := srv.s.Connect(ctx, st, nil)
	require.NoError(t, err)
	t.Cleanup(func() { _ = ss.Close() })
	cs, err := mcpsdk.NewClient(&mcpsdk.Implementation{Name: "test", Version: "0"}, nil).Connect(ctx, ct, nil)
	require.NoError(t, err)
	t.Cleanup(func() { _ = cs.Close() })
	return cs
}

func call(t *testing.T, cs *mcpsdk.ClientSession, name string, args any) (string, bool) {
	t.Helper()
	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{Name: name, Arguments: args})
	require.NoError(t, err)
	require.Len(t, res.Content, 1)
	return res.Content[0].(*mcpsdk.TextContent).Text, res.IsError
}

func slack(t *testing.T) connectplay.Playbook {
	t.Helper()
	pb, err := connectplay.Load("slack")
	require.NoError(t, err)
	return pb
}

func toolNames(ts []*mcpsdk.Tool) []string {
	var names []string
	for _, t := range ts {
		names = append(names, t.Name)
	}
	return names
}

func TestTools_OnlyPlaybookTools(t *testing.T) {
	pb := slack(t)
	assert.ElementsMatch(t, pb.Tools, toolNames(Tools(pb)))

	listed, err := session(t, &fakeCaller{}, pb).ListTools(context.Background(), nil)
	require.NoError(t, err)
	var mounted []string
	for _, tl := range listed.Tools {
		mounted = append(mounted, tl.Name)
		assert.False(t, strings.HasPrefix(tl.Name, "company_"), "Slack mounts no company tool: %s", tl.Name)
	}
	assert.ElementsMatch(t, pb.Tools, mounted)
}

// Every known tool has a definition: a playbook may list any of them.
func TestTools_EveryKnownToolDefined(t *testing.T) {
	ts := toolSet{tools: connectplay.KnownTools, secrets: []string{"imap_password"}, vendors: []string{"google"}}
	assert.Equal(t, connectplay.KnownTools, toolNames(ts.mcpTools()))
	for _, tl := range ts.mcpTools() {
		_, err := tl.InputSchema.(*jsonschema.Schema).Resolve(nil)
		assert.NoError(t, err, tl.Name)
	}
}

// The company run mounts the union of every vendor's playbook.
func TestTools_UnionOfServicePlaybooks(t *testing.T) {
	a := connectplay.Playbook{Service: "company", Vendor: "google", Tools: []string{"company_check", "request_secret"}, Secrets: []string{"google_client_secret"}}
	b := connectplay.Playbook{Service: "company", Vendor: "atlassian", Tools: []string{"company_draft", "request_secret"}, Secrets: []string{"atlassian_client_secret"}}
	ts := setOf(a, b)
	assert.Equal(t, []string{"request_secret", "company_draft", "company_check"}, ts.tools)
	assert.Equal(t, []string{"google_client_secret", "atlassian_client_secret"}, ts.secrets)
	assert.Equal(t, []string{"google", "atlassian"}, ts.vendors)

	fc := &fakeCaller{result: `{"state":"waiting"}`}
	cs := session(t, fc, a, b)
	_, isErr := call(t, cs, "company_check", map[string]any{"vendor": "slack"})
	assert.True(t, isErr, "a vendor outside the playbooks is refused")
	text, isErr := call(t, cs, "company_check", map[string]any{"vendor": "atlassian"})
	assert.False(t, isErr)
	assert.JSONEq(t, `{"state":"waiting"}`, text)
}

func TestTools_SetFieldsRefusesSecretKeys(t *testing.T) {
	pb := connectplay.Playbook{Service: "company", Vendor: "atlassian", Tools: []string{"set_fields", "company_draft"}}
	fc := &fakeCaller{result: `{}`}
	cs := session(t, fc, pb)
	for _, key := range []string{"password", "api_token", "Client_Secret", "linear_key", "apiKey"} {
		text, isErr := call(t, cs, "set_fields", map[string]any{key: "x"})
		assert.True(t, isErr, key)
		assert.True(t, strings.HasPrefix(text, "bad_args: "), text)
		text, isErr = call(t, cs, "company_draft", map[string]any{"vendor": "atlassian", "fields": map[string]any{key: "x"}})
		assert.True(t, isErr, key)
		assert.True(t, strings.HasPrefix(text, "bad_args: "), text)
	}
	assert.Empty(t, fc.forwarded(), "a refused call never reaches the Desktop")

	_, isErr := call(t, cs, "set_fields", map[string]any{"host": "imap.example.com", "port": "993"})
	assert.False(t, isErr)
	_, isErr = call(t, cs, "set_fields", map[string]any{"port": 993})
	assert.True(t, isErr, "values are strings")
	_, isErr = call(t, cs, "company_draft", map[string]any{})
	assert.False(t, isErr, "no fields reads the draft")
	assert.Equal(t, []string{"set_fields", "company_draft"}, fc.forwarded())
}

func TestTools_LabelOver80Refused(t *testing.T) {
	fc := &fakeCaller{result: `{"state":"waiting"}`}
	cs := session(t, fc, slack(t))
	text, isErr := call(t, cs, "request_secret", map[string]any{"kind": "slack_config_token", "label": strings.Repeat("é", 81)})
	assert.True(t, isErr)
	assert.True(t, strings.HasPrefix(text, "bad_args: "), text)
	assert.Empty(t, fc.forwarded())

	text, isErr = call(t, cs, "request_secret", map[string]any{"kind": "slack_config_token", "label": strings.Repeat("é", 80)})
	assert.False(t, isErr, text)
	assert.JSONEq(t, `{"state":"waiting"}`, text)
	assert.Equal(t, []string{"request_secret"}, fc.forwarded())
}

func TestTools_SecretKindOutsidePlaybookRefused(t *testing.T) {
	fc := &fakeCaller{result: `{}`}
	cs := session(t, fc, slack(t))
	for _, args := range []map[string]any{
		{"kind": "imap_password", "label": "Password"},
		{"kind": "not_a_kind", "label": "x"},
		{"label": "no kind"},
	} {
		text, isErr := call(t, cs, "request_secret", args)
		assert.True(t, isErr, args)
		assert.True(t, strings.HasPrefix(text, "bad_args: "), text)
	}
	assert.Empty(t, fc.forwarded())
}

func TestTools_StartOptionsFromPlaybook(t *testing.T) {
	fc := &fakeCaller{result: `{"flow_id":"flow-1"}`}
	cs := session(t, fc, slack(t))
	_, isErr := call(t, cs, "connect_start", map[string]any{"with_confluence": true})
	assert.True(t, isErr, "an option the playbook does not name is refused")
	text, isErr := call(t, cs, "connect_start", map[string]any{"code": "https://acme.example.com/connect"})
	assert.False(t, isErr)
	assert.JSONEq(t, `{"flow_id":"flow-1"}`, text)
	assert.JSONEq(t, `{"code":"https://acme.example.com/connect"}`, fc.args[0], "args reach the Desktop untouched")
}

// A wire error reaches the agent as "<code>: <message>"; no-arg calls send {}.
func TestTools_WireErrorIsToolError(t *testing.T) {
	fc := &fakeCaller{err: &connectwire.Error{Code: connectwire.CodeBusy, Message: "a Slack sign-in is already running"}}
	cs := session(t, fc, slack(t))
	text, isErr := call(t, cs, "connect_status", nil)
	assert.True(t, isErr)
	assert.Equal(t, "busy: a Slack sign-in is already running", text)
	assert.Equal(t, "{}", fc.args[0])
}
