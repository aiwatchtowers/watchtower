package chat

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"slices"
	"strings"
	"sync"
	"time"

	"watchtower/internal/chat/connectorpolicy"
	"watchtower/internal/fsutil"
)

// The claude.ai connector catalog (#737, spec D2): what the warm session's
// mcp_status says about the owner's account connectors, kept live for the
// gate's policy and mirrored into a 0600 sidecar file the Desktop reads for
// Settings → AI → claude.ai connectors.
//
// Sidecar file: <dir of the db path>/claude-ai-connectors.json, written by
// temp file + rename (a reader sees the old file or the new one), pinned by
// testdata/claude_ai_connectors.json:
//
//	{
//	  "updated_at": "2026-10-17T09:30:00Z",     // RFC 3339, UTC
//	  "available": true,                          // false: claude.ai tools are off for this chat
//	  "unavailable_reason": "",                   // why, when !available ("" otherwise)
//	  "servers": [                                // account connectors only, sorted by name
//	    {
//	      "name": "Connector A",                  // display name, without the "claude.ai " prefix —
//	                                              // the spelling ai.claude_ai.disabled_connectors holds
//	      "status": "connected",                  // connected | needs-auth | failed | pending | disabled
//	      "tools": [                              // only for connected (and disabled) servers; may be empty
//	        {"name": "search", "read_only": true},           // a hint is present only when the
//	        {"name": "send", "read_only": false},            // connector declares it
//	        {"name": "delete", "destructive": true}
//	      ]
//	    }
//	  ]
//	}
//
// "disabled" is a server the owner switched off (ai.claude_ai.disabled_connectors);
// a CLI status other than the four live ones is written as "failed". With
// ai.claude_ai.connectors false the CLI loads no connector, so the file keeps
// the last known list, every server "disabled" and its tools dropped. Keys
// the Desktop does not know must be ignored (more may be added).
//
// Config keys (cmd/config.go, internal/config): ai.claude_ai.connectors
// (bool, default true; false = no connector loads, publishing stays) and
// ai.claude_ai.disabled_connectors (list of display names as in "name"
// above; `config set` takes them comma-separated, "" = none disabled).
// A switch takes effect when the next chat session starts.

// ConnectorsFileName is the sidecar's base name, beside the database.
const ConnectorsFileName = "claude-ai-connectors.json"

// claudeAIServerPrefix starts every account connector's server name.
const claudeAIServerPrefix = "claude.ai "

// Sidecar server statuses.
const (
	ConnectorConnected = "connected"
	ConnectorNeedsAuth = "needs-auth"
	ConnectorFailed    = "failed"
	ConnectorPending   = "pending"
	ConnectorDisabled  = "disabled"
)

// ConnectorSnapshot is one view of the account's claude.ai connectors. It is
// the gate policy's Catalog: only a server it lists, with the source and
// config type of an account connector, is a connector at all.
type ConnectorSnapshot struct {
	UpdatedAt         time.Time
	Available         bool
	UnavailableReason string
	// Servers are account connectors only (isAccountConnector); Name keeps
	// the "claude.ai " prefix, as mcp_status and can_use_tool spell it.
	Servers []MCPServerStatus
}

var _ connectorpolicy.Catalog = ConnectorSnapshot{}

// isAccountConnector reports whether an mcp_status server is one of the
// owner's claude.ai account connectors, not a local or Quick Connection
// server.
func isAccountConnector(s MCPServerStatus) bool {
	return s.Source == "claudeai" && s.ConfigType == "claudeai-proxy" &&
		strings.HasPrefix(s.Name, claudeAIServerPrefix)
}

func (s ConnectorSnapshot) server(token string) (MCPServerStatus, bool) {
	if !s.Available {
		return MCPServerStatus{}, false
	}
	for _, srv := range s.Servers {
		if isAccountConnector(srv) && connectorpolicy.ServerToken(srv.Name) == token {
			return srv, true
		}
	}
	return MCPServerStatus{}, false
}

// Connector implements connectorpolicy.Catalog.
func (s ConnectorSnapshot) Connector(serverToken string) bool {
	_, ok := s.server(serverToken)
	return ok
}

// Lookup implements connectorpolicy.Catalog: the tool's own annotations,
// false when the server is unlisted or does not list the tool.
func (s ConnectorSnapshot) Lookup(serverToken, tool string) (connectorpolicy.Annotations, bool) {
	srv, ok := s.server(serverToken)
	if !ok {
		return connectorpolicy.Annotations{}, false
	}
	for _, t := range srv.Tools {
		if t.Name == tool {
			return connectorpolicy.Annotations{ReadOnly: t.ReadOnly, Destructive: t.Destructive}, true
		}
	}
	return connectorpolicy.Annotations{}, false
}

// settled reports whether an mcp_status answer is final enough to keep: the
// list is filled (it is empty right after spawn) and no account connector
// is still pending.
func connectorsSettled(servers []MCPServerStatus) bool {
	if len(servers) == 0 {
		return false
	}
	for _, s := range servers {
		if isAccountConnector(s) && s.Status == ConnectorPending {
			return false
		}
	}
	return true
}

// newConnectorSnapshot keeps the account connectors of an mcp_status answer,
// sorted by name, and marks the switched-off ones disabled.
func newConnectorSnapshot(now time.Time, servers []MCPServerStatus, disabled map[string]bool) ConnectorSnapshot {
	snap := ConnectorSnapshot{UpdatedAt: now.UTC(), Available: true, Servers: []MCPServerStatus{}}
	for _, s := range servers {
		if !isAccountConnector(s) {
			continue
		}
		if disabled[connectorpolicy.ServerToken(s.Name)] {
			s.Status = ConnectorDisabled
		}
		snap.Servers = append(snap.Servers, s)
	}
	sortServers(snap.Servers)
	return snap
}

// carriedOverSnapshot is the snapshot of a session whose connectors are all
// switched off: the CLI lists none, so the last known list is kept, every
// server disabled, so Settings still shows what can be switched back on.
func carriedOverSnapshot(now time.Time, last ConnectorSnapshot) ConnectorSnapshot {
	snap := ConnectorSnapshot{UpdatedAt: now.UTC(), Available: true, Servers: []MCPServerStatus{}}
	for _, s := range last.Servers {
		snap.Servers = append(snap.Servers, MCPServerStatus{Name: s.Name, Status: ConnectorDisabled,
			Source: s.Source, ConfigType: s.ConfigType})
	}
	sortServers(snap.Servers)
	return snap
}

// UnavailableConnectors is the snapshot of a main chat whose claude.ai tools
// are off (ClaudeAIAvailability's reason): no server is listed.
func UnavailableConnectors(now time.Time, reason string) ConnectorSnapshot {
	return ConnectorSnapshot{UpdatedAt: now.UTC(), UnavailableReason: reason, Servers: []MCPServerStatus{}}
}

func sortServers(servers []MCPServerStatus) {
	slices.SortStableFunc(servers, func(a, b MCPServerStatus) int { return strings.Compare(a.Name, b.Name) })
}

// connectorsFile is the sidecar's JSON shape (see the package comment above).
type connectorsFile struct {
	UpdatedAt         time.Time             `json:"updated_at"`
	Available         bool                  `json:"available"`
	UnavailableReason string                `json:"unavailable_reason"`
	Servers           []connectorFileServer `json:"servers"`
}

type connectorFileServer struct {
	Name   string              `json:"name"`
	Status string              `json:"status"`
	Tools  []connectorFileTool `json:"tools"`
}

type connectorFileTool struct {
	Name        string `json:"name"`
	ReadOnly    *bool  `json:"read_only,omitempty"`
	Destructive *bool  `json:"destructive,omitempty"`
}

// fileStatus maps a CLI status onto the sidecar's vocabulary.
func fileStatus(status string) string {
	switch status {
	case ConnectorConnected, ConnectorNeedsAuth, ConnectorPending, ConnectorDisabled:
		return status
	default:
		return ConnectorFailed
	}
}

// WriteConnectorsFile replaces the sidecar at path with s (0600, temp file +
// rename).
func WriteConnectorsFile(path string, s ConnectorSnapshot) error {
	f := connectorsFile{UpdatedAt: s.UpdatedAt.UTC(), Available: s.Available,
		UnavailableReason: s.UnavailableReason, Servers: []connectorFileServer{}}
	for _, srv := range s.Servers {
		if !isAccountConnector(srv) {
			continue
		}
		out := connectorFileServer{Name: strings.TrimPrefix(srv.Name, claudeAIServerPrefix),
			Status: fileStatus(srv.Status), Tools: []connectorFileTool{}}
		for _, t := range srv.Tools {
			out.Tools = append(out.Tools, connectorFileTool(t))
		}
		f.Servers = append(f.Servers, out)
	}
	data, err := json.MarshalIndent(f, "", "  ")
	if err != nil {
		return fmt.Errorf("encoding %s: %w", ConnectorsFileName, err)
	}
	return fsutil.WriteFileAtomic(path, append(data, '\n'), 0o600)
}

// ReadConnectorsFile reads the sidecar at path; a missing file is an empty,
// unavailable snapshot and no error.
func ReadConnectorsFile(path string) (ConnectorSnapshot, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return ConnectorSnapshot{Servers: []MCPServerStatus{}}, nil
	}
	if err != nil {
		return ConnectorSnapshot{}, fmt.Errorf("reading %s: %w", ConnectorsFileName, err)
	}
	var f connectorsFile
	if err := json.Unmarshal(data, &f); err != nil {
		return ConnectorSnapshot{}, fmt.Errorf("decoding %s: %w", ConnectorsFileName, err)
	}
	s := ConnectorSnapshot{UpdatedAt: f.UpdatedAt, Available: f.Available,
		UnavailableReason: f.UnavailableReason, Servers: []MCPServerStatus{}}
	for _, in := range f.Servers {
		srv := MCPServerStatus{Name: connectorServerName(in.Name), Status: in.Status,
			Source: "claudeai", ConfigType: "claudeai-proxy"}
		for _, t := range in.Tools {
			srv.Tools = append(srv.Tools, MCPToolInfo(t))
		}
		s.Servers = append(s.Servers, srv)
	}
	return s, nil
}

// connectorServerName is the server name of a connector's display name
// ("Gmail" → "claude.ai Gmail"); a name already carrying the prefix is kept.
func connectorServerName(display string) string {
	if strings.HasPrefix(display, claudeAIServerPrefix) {
		return display
	}
	return claudeAIServerPrefix + display
}

// DisabledConnectorTokens maps the owner's switched-off connectors (display
// names, as ai.claude_ai.disabled_connectors holds them) to the server
// tokens of connectorpolicy.Policy.Disabled. Never nil: an empty map means
// nothing is switched off.
func DisabledConnectorTokens(disabled []string) map[string]bool {
	out := map[string]bool{}
	for _, name := range disabled {
		if name = strings.TrimSpace(name); name != "" {
			out[connectorpolicy.ServerToken(connectorServerName(name))] = true
		}
	}
	return out
}

// DisabledToolTokens is the --disallowedTools addition of a claude.ai-mode
// session: mcp__<token> per switched-off connector (the CLI hides the whole
// connector, probe answer 6), and the authenticate / complete_authentication
// tools of every connector of last (the previous sidecar; a connector is
// connected on claude.ai, never from the chat). Sorted, no duplicates.
// Hiding is a convenience: the gate's Disabled rule and its authenticate
// rule are the enforcement, so a sidecar that could not be read only loses
// the second part.
func DisabledToolTokens(disabled []string, last ConnectorSnapshot) []string {
	set := map[string]bool{}
	for token := range DisabledConnectorTokens(disabled) {
		set["mcp__"+token] = true
	}
	for _, s := range last.Servers {
		token := connectorpolicy.ServerToken(connectorServerName(strings.TrimPrefix(s.Name, claudeAIServerPrefix)))
		set["mcp__"+token+"__authenticate"] = true
		set["mcp__"+token+"__complete_authentication"] = true
	}
	out := make([]string, 0, len(set))
	for t := range set {
		out = append(out, t)
	}
	slices.Sort(out)
	return out
}

// withoutReservedAllowTokens drops every --allowedTools entry naming a
// server in the claude.ai connectors' namespace (ReservedServerToken): in
// claude.ai mode such an entry — a Quick Connection named like an account
// connector — would pre-allow the connector's tools, writes included,
// before the gate ever saw them. Built-in names pass.
func withoutReservedAllowTokens(allowed string) string {
	if allowed == "" {
		return ""
	}
	var kept []string
	for _, tok := range strings.Split(allowed, ",") {
		if rest, ok := strings.CutPrefix(strings.TrimSpace(tok), "mcp__"); ok && connectorpolicy.ReservedServerToken(rest) {
			continue
		}
		kept = append(kept, tok)
	}
	return strings.Join(kept, ",")
}

// connectorCatalog is a session's live ConnectorSnapshot: the gate's policy
// reads it, the mcp_status answers replace it. Safe for concurrent use.
type connectorCatalog struct {
	mu   sync.Mutex
	snap ConnectorSnapshot
	// unavailable is set once a child showed it is not on the claude.ai
	// login (init.apiKeySource): it stays off for the session's life (a
	// respawn runs with the same environment).
	unavailable string
}

func newConnectorCatalog() *connectorCatalog {
	return &connectorCatalog{snap: ConnectorSnapshot{Servers: []MCPServerStatus{}}}
}

func (c *connectorCatalog) get() ConnectorSnapshot {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.snap
}

// set stores s unless the catalog was marked unavailable, and returns what
// it now holds.
func (c *connectorCatalog) set(s ConnectorSnapshot) ConnectorSnapshot {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.unavailable != "" {
		s = UnavailableConnectors(s.UpdatedAt, c.unavailable)
	}
	c.snap = s
	return s
}

// markUnavailable switches the catalog off for good with reason; false when
// it already was.
func (c *connectorCatalog) markUnavailable(now time.Time, reason string) (ConnectorSnapshot, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.unavailable != "" {
		return c.snap, false
	}
	c.unavailable = reason
	c.snap = UnavailableConnectors(now, reason)
	return c.snap, true
}

// Connector implements connectorpolicy.Catalog.
func (c *connectorCatalog) Connector(serverToken string) bool {
	return c.get().Connector(serverToken)
}

// Lookup implements connectorpolicy.Catalog.
func (c *connectorCatalog) Lookup(serverToken, tool string) (connectorpolicy.Annotations, bool) {
	return c.get().Lookup(serverToken, tool)
}

// knows reports whether the catalog lists the connector tool of call (a
// raw mcp__<token>__<tool> name): false sends the gate to refresh once.
func (c *connectorCatalog) knows(toolName string) bool {
	token, tool, ok := connectorpolicy.ParseToolName(toolName)
	if !ok {
		return true // not a connector tool: nothing to refresh
	}
	_, known := c.Lookup(token, tool)
	return known
}

// apiKeyUnavailableReason is the reason of a child whose init event shows
// it does not run on the claude.ai login; "" when it does or the field is
// absent.
func apiKeyUnavailableReason(apiKeySource string) string {
	if apiKeySource == "" || apiKeySource == "none" {
		return ""
	}
	return "claude.ai tools need a claude.ai login; this chat uses an API key (" + apiKeySource + ")."
}

// The connector watch bounds (spec D2): mcp_status is re-sent every second
// while the list settles, for at most 10 s after the spawn; one answer is
// awaited up to 2 s (also the gate's refresh bound).
const (
	connectorsPollInterval = time.Second
	connectorsSettleWindow = 10 * time.Second
	connectorsAnswerWait   = 2 * time.Second
)

// errChildGone ends an mcp_status query whose child exited or was replaced.
var errChildGone = errors.New("the chat session's CLI is gone")

type mcpStatusAnswer struct {
	servers []MCPServerStatus
	err     error
}

// queryMCPStatus asks p for its MCP servers and waits, up to connAnswer, for
// the answer the reader routes back (routeStatusAnswer).
func (b *claudeBackend) queryMCPStatus(p *claudeProc) ([]MCPServerStatus, error) {
	id := fmt.Sprintf("wt-mcp-status-%d", b.statusSeq.Add(1))
	ch := make(chan mcpStatusAnswer, 1)
	b.statusMu.Lock()
	b.statusWaits[id] = ch
	b.statusMu.Unlock()
	defer func() {
		b.statusMu.Lock()
		delete(b.statusWaits, id)
		b.statusMu.Unlock()
	}()
	if err := p.write(mcpStatusRequestLine(id)); err != nil {
		return nil, errChildGone
	}
	select {
	case a := <-ch:
		return a.servers, a.err
	case <-p.exited:
		return nil, errChildGone
	case <-p.stop:
		return nil, errChildGone
	case <-time.After(b.connAnswer):
		return nil, fmt.Errorf("mcp_status: no answer within %v", b.connAnswer)
	}
}

// routeStatusAnswer hands the CLI's answer to a waiting mcp_status request
// to its query; false for every other line.
func (b *claudeBackend) routeStatusAnswer(line []byte) bool {
	if b.statusWaits == nil || !bytes.Contains(line, []byte(`"control_response"`)) {
		return false
	}
	env, ok := decodeObject(line)
	if !ok || env.str("type") != "control_response" {
		return false
	}
	body, _ := decodeObject(env["response"])
	id := body.str("request_id")
	b.statusMu.Lock()
	ch := b.statusWaits[id]
	b.statusMu.Unlock()
	if ch == nil {
		return false
	}
	servers, _, err := parseMCPStatusResponse(line, id)
	select {
	case ch <- mcpStatusAnswer{servers: servers, err: err}:
	default: // a duplicate answer: the first one counts
	}
	return true
}

// watchConnectors builds the connector catalog of a freshly spawned child:
// mcp_status until the list settles (it is empty right after the spawn and
// lists connectors pending for a second or two), for at most connSettle;
// then the chat goes on with whatever it has. With the connectors switched
// off the CLI lists none, and the sidecar keeps the last known list as
// disabled instead.
func (b *claudeBackend) watchConnectors(p *claudeProc) {
	defer b.watchers.Done()
	if !b.opts.ClaudeAI.Connectors {
		b.publishConnectors(carriedOverSnapshot(time.Now(), b.lastConnectors()))
		return
	}
	deadline := time.Now().Add(b.connSettle)
	for {
		servers, err := b.queryMCPStatus(p)
		if errors.Is(err, errChildGone) {
			return
		}
		if err != nil {
			fmt.Fprintf(b.warn(), "chat: reading the claude.ai connectors: %v\n", err)
		}
		final := (err == nil && connectorsSettled(servers)) || !time.Now().Before(deadline)
		if err == nil && (len(servers) > 0 || final) {
			b.storeConnectors(servers)
		}
		if final {
			return
		}
		select {
		case <-p.exited:
			return
		case <-p.stop:
			return
		case <-time.After(b.connPoll):
		}
	}
}

// refreshConnectors is the gate's one re-read of the catalog before it
// decides a connector call the catalog does not list.
func (b *claudeBackend) refreshConnectors(p *claudeProc) {
	servers, err := b.queryMCPStatus(p)
	if err != nil {
		if !errors.Is(err, errChildGone) {
			fmt.Fprintf(b.warn(), "chat: refreshing the claude.ai connectors: %v\n", err)
		}
		return
	}
	b.storeConnectors(servers)
}

// storeConnectors makes an mcp_status answer the session's catalog, the
// owner's switched-off servers marked disabled, and mirrors it into the
// sidecar.
func (b *claudeBackend) storeConnectors(servers []MCPServerStatus) {
	var disabled map[string]bool
	if b.opts.Gate != nil {
		disabled = b.opts.Gate.Policy.Disabled
	}
	b.publishConnectors(newConnectorSnapshot(time.Now(), servers, disabled))
}

func (b *claudeBackend) publishConnectors(s ConnectorSnapshot) {
	b.writeConnectorsFile(b.catalog.set(s))
}

// noteAPIKeySource switches the catalog off for good when the child's init
// event shows it does not run on the claude.ai login (an apiKeyHelper or a
// key the environment markers did not reveal): no connector call is then
// allowed, and the sidecar says why.
func (b *claudeBackend) noteAPIKeySource(source string) {
	reason := apiKeyUnavailableReason(source)
	if b.catalog == nil || reason == "" {
		return
	}
	if s, changed := b.catalog.markUnavailable(time.Now(), reason); changed {
		fmt.Fprintf(b.warn(), "chat: %s\n", reason)
		b.writeConnectorsFile(s)
	}
}

func (b *claudeBackend) writeConnectorsFile(s ConnectorSnapshot) {
	if b.opts.ConnectorsFile == "" {
		return
	}
	b.fileMu.Lock()
	defer b.fileMu.Unlock()
	if err := WriteConnectorsFile(b.opts.ConnectorsFile, s); err != nil {
		fmt.Fprintf(b.warn(), "chat: %v\n", err)
	}
}

// lastConnectors is the sidecar as the previous session left it (empty when
// there is none or it cannot be read).
func (b *claudeBackend) lastConnectors() ConnectorSnapshot {
	if b.opts.ConnectorsFile == "" {
		return ConnectorSnapshot{}
	}
	s, err := ReadConnectorsFile(b.opts.ConnectorsFile)
	if err != nil {
		fmt.Fprintf(b.warn(), "chat: %v\n", err)
	}
	return s
}
