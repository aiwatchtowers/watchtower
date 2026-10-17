// Package connectorpolicy is the pure decision table behind the claude.ai
// session gate (spec D3, decision Q1): every can_use_tool request the warm
// main-chat session sends is classified here as Allow, Ask (an approval card)
// or Deny. Reads are free, private publishing needs no confirmation, connector
// writes go through Approve, and anything the table does not recognise fails
// closed.
package connectorpolicy

import (
	"bytes"
	"encoding/json"
	"fmt"
	"path/filepath"
	"strings"
)

// Verdict is the gate's answer to one tool call.
type Verdict int

// The zero value is Deny, so a Decision nobody filled in fails closed.
const (
	Deny Verdict = iota
	Allow
	Ask
)

func (v Verdict) String() string {
	switch v {
	case Allow:
		return "allow"
	case Ask:
		return "ask"
	default:
		return "deny"
	}
}

// Decision is the verdict plus the reason the model (Deny) or the owner (Ask)
// sees. UpdatedInput, when non-nil, replaces the call's input on Allow.
type Decision struct {
	Verdict      Verdict
	Reason       string
	UpdatedInput json.RawMessage
}

// Call is one can_use_tool request.
type Call struct {
	// Tool is the raw CLI name: mcp__claude_ai_Gmail__send, Artifact, Write.
	Tool string
	// Server is the request's mcp_server; "" for built-ins.
	Server string
	Input  json.RawMessage
}

// Annotations are a connector tool's own MCP hints (nil = not declared).
type Annotations struct {
	ReadOnly, Destructive *bool
}

// Catalog resolves a connector tool's annotations from the session's
// mcp_status snapshot.
type Catalog interface {
	Lookup(serverToken, tool string) (Annotations, bool)
}

// Policy is the per-session input of the decision table. Every nil field fails
// closed: no Catalog asks for every connector call, no PathCheck denies every
// path, no OwnArtifact asks before updating any existing artifact.
type Policy struct {
	Catalog Catalog
	// Disabled holds the server tokens switched off in Settings → AI.
	Disabled map[string]bool
	// PathCheck returns nil only for a path inside the session's publish dir.
	PathCheck  func(path string) error
	PublishDir string
	// OwnArtifact reports whether this session published the artifact at url.
	OwnArtifact func(url string) bool
}

const (
	mcpPrefix         = "mcp__"
	claudeAITokenHead = "claude_ai_"
)

// Decide classifies one call. Rules apply in order, first match wins.
func (p Policy) Decide(c Call) Decision {
	if c.Server == "" {
		switch c.Tool {
		case "Write", "Edit", "Read":
			return p.decideFileTool(c)
		case "Artifact":
			return p.decideArtifact(c.Input)
		}
	}

	server, tool, ok := ParseToolName(c.Tool)
	if !ok || !strings.HasPrefix(server, claudeAITokenHead) {
		return deny("%s is not available in this chat", c.Tool)
	}
	// The request's own server name must map to the token in the tool name;
	// a mismatch means the classification below would be about another server.
	if c.Server == "" || ServerToken(c.Server) != server {
		return deny("%s is not available in this chat", c.Tool)
	}
	name := displayName(c.Server)
	if p.Disabled[server] {
		return deny("%s is switched off in Settings → AI", name)
	}
	if tool == "authenticate" || tool == "complete_authentication" {
		return deny("connect %s on claude.ai first", name)
	}
	if row, ok := findOverride(server, tool); ok {
		return row.decide(c.Input)
	}
	if p.Catalog != nil {
		if ann, ok := p.Catalog.Lookup(server, tool); ok &&
			isTrue(ann.ReadOnly) && !isTrue(ann.Destructive) {
			return Decision{Verdict: Allow, Reason: "read-only connector tool"}
		}
	}
	return Decision{Verdict: Ask, Reason: "connector tool that may change data"}
}

// decideFileTool confines the file built-ins to the publish dir.
func (p Policy) decideFileTool(c Call) Decision {
	var in struct {
		FilePath *string `json:"file_path"`
	}
	if err := json.Unmarshal(c.Input, &in); err != nil || in.FilePath == nil || *in.FilePath == "" ||
		p.checkPath(*in.FilePath) != nil {
		return deny("%s may only write inside %s", c.Tool, p.PublishDir)
	}
	return Decision{Verdict: Allow, Reason: "inside the publish dir"}
}

// artifactInput holds the Artifact fields the gate reads. Raw fields are
// decoded on use so an unexpected shape denies instead of being skipped.
type artifactInput struct {
	Action    *string         `json:"action"`
	FilePath  *string         `json:"file_path"`
	FilePaths []string        `json:"file_paths"`
	Files     json.RawMessage `json:"files"`
	Root      *string         `json:"root"`
	URL       *string         `json:"url"`
	Force     *bool           `json:"force"`
	OutDir    *string         `json:"out_dir"`
}

func (p Policy) decideArtifact(input json.RawMessage) Decision {
	var in artifactInput
	if err := json.Unmarshal(input, &in); err != nil {
		return deny("Artifact input is not a JSON object")
	}
	action := "publish"
	if in.Action != nil {
		action = *in.Action
	}
	switch action {
	case "publish":
		return p.decideArtifactPublish(in)
	case "read":
		return p.decideArtifactRead(input, in)
	case "list", "open", "quickstart":
		return Decision{Verdict: Allow, Reason: "Artifact " + action}
	case "delete", "pin", "unpin":
		return Decision{Verdict: Ask, Reason: "Artifact " + action + " changes an existing artifact"}
	default:
		return deny("Artifact action %q is not available in this chat", action)
	}
}

func (p Policy) decideArtifactPublish(in artifactInput) Decision {
	sources, err := publishSources(in)
	if err != nil {
		return deny("Artifact publish: %v", err)
	}
	for _, src := range sources {
		if p.checkPath(src) != nil {
			return deny("Artifact may only publish files inside %s", p.PublishDir)
		}
	}
	if in.Force != nil && *in.Force {
		return Decision{Verdict: Ask, Reason: "Artifact publish with force overwrites a newer version"}
	}
	if in.URL != nil && *in.URL != "" && (p.OwnArtifact == nil || !p.OwnArtifact(*in.URL)) {
		return Decision{Verdict: Ask, Reason: "Artifact publish updates an artifact this chat did not publish"}
	}
	return Decision{Verdict: Allow, Reason: "private publish from the publish dir"}
}

// publishSources lists every local path an Artifact publish reads: file_path,
// file_paths, each files source and root. A files source relative to root is
// joined to it, the way the CLI resolves it.
func publishSources(in artifactInput) ([]string, error) {
	var root string
	var out []string
	if in.Root != nil {
		root = *in.Root
		out = append(out, dirProbe(root))
	}
	resolve := func(p string) string {
		if root != "" && !filepath.IsAbs(p) {
			return filepath.Join(root, p)
		}
		return p
	}
	if in.FilePath != nil {
		out = append(out, *in.FilePath)
	}
	out = append(out, in.FilePaths...)

	files := bytes.TrimSpace(in.Files)
	if len(files) == 0 || bytes.Equal(files, []byte("null")) {
		return out, nil
	}
	switch files[0] {
	case '[':
		var list []struct {
			Path *string `json:"path"`
		}
		if err := json.Unmarshal(files, &list); err != nil {
			return nil, fmt.Errorf("files list has an unexpected shape")
		}
		for _, f := range list {
			if f.Path == nil {
				return nil, fmt.Errorf("files entry without a path")
			}
			out = append(out, resolve(*f.Path))
		}
	case '{':
		var m map[string]json.RawMessage
		if err := json.Unmarshal(files, &m); err != nil {
			return nil, fmt.Errorf("files map has an unexpected shape")
		}
		for published, raw := range m {
			src, local, err := filesMapSource(raw)
			if err != nil {
				return nil, fmt.Errorf("files[%q]: %w", published, err)
			}
			if local {
				out = append(out, resolve(src))
			}
		}
	default:
		return nil, fmt.Errorf("files has an unexpected shape")
	}
	return out, nil
}

// filesMapSource reads one files-map value: a path string, {from}, a
// server-side {artifact, path} copy (no local file) or null (a removal).
func filesMapSource(raw json.RawMessage) (src string, local bool, err error) {
	raw = bytes.TrimSpace(raw)
	if bytes.Equal(raw, []byte("null")) {
		return "", false, nil
	}
	var s string
	if json.Unmarshal(raw, &s) == nil {
		return s, true, nil
	}
	var obj struct {
		From     *string `json:"from"`
		Artifact *string `json:"artifact"`
	}
	if err := json.Unmarshal(raw, &obj); err != nil {
		return "", false, fmt.Errorf("unexpected source shape")
	}
	switch {
	case obj.From != nil && obj.Artifact == nil:
		return *obj.From, true, nil
	case obj.Artifact != nil && obj.From == nil:
		return "", false, nil
	default:
		return "", false, fmt.Errorf("unexpected source shape")
	}
}

func (p Policy) decideArtifactRead(input json.RawMessage, in artifactInput) Decision {
	if in.OutDir != nil {
		if p.checkPath(dirProbe(*in.OutDir)) != nil {
			return deny("Artifact may only save inside %s", p.PublishDir)
		}
		return Decision{Verdict: Allow, Reason: "read into the publish dir"}
	}
	if p.PublishDir == "" {
		return deny("Artifact read has no publish dir to save into")
	}
	var m map[string]json.RawMessage
	if err := json.Unmarshal(input, &m); err != nil || m == nil {
		return deny("Artifact input is not a JSON object")
	}
	dir, err := json.Marshal(p.PublishDir)
	if err != nil {
		return deny("Artifact read: %v", err)
	}
	m["out_dir"] = dir
	updated, err := json.Marshal(m)
	if err != nil {
		return deny("Artifact read: %v", err)
	}
	return Decision{Verdict: Allow, Reason: "read into the publish dir", UpdatedInput: updated}
}

// dirProbe turns a directory argument into a path checked as a file inside
// it: PathCheck accepts only paths strictly inside the publish dir, while a
// directory argument may be the publish dir itself.
func dirProbe(dir string) string {
	if dir == "" {
		return ""
	}
	return filepath.Join(dir, "probe")
}

func (p Policy) checkPath(path string) error {
	if p.PathCheck == nil || path == "" {
		return fmt.Errorf("no publish dir")
	}
	return p.PathCheck(path)
}

// ServerToken maps a server display name to the CLI's mcp__<token>__ form:
// every rune outside [A-Za-z0-9_-] becomes "_" ("claude.ai Claude Docs" →
// "claude_ai_Claude_Docs").
func ServerToken(displayName string) string {
	var b strings.Builder
	for _, r := range displayName {
		if r == '_' || r == '-' || (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') {
			b.WriteRune(r)
		} else {
			b.WriteByte('_')
		}
	}
	return b.String()
}

// ParseToolName splits mcp__<server>__<tool> the way the CLI does: the server
// token runs to the first "__" after the prefix, the rest is the tool.
func ParseToolName(raw string) (serverToken, tool string, ok bool) {
	rest, found := strings.CutPrefix(raw, mcpPrefix)
	if !found {
		return "", "", false
	}
	serverToken, tool, found = strings.Cut(rest, "__")
	if !found || serverToken == "" || tool == "" {
		return "", "", false
	}
	return serverToken, tool, true
}

// displayName strips the claude.ai connector prefix for reason texts
// ("claude.ai Gmail" → "Gmail").
func displayName(server string) string {
	if name, ok := strings.CutPrefix(server, "claude.ai "); ok && name != "" {
		return name
	}
	return server
}

func isTrue(b *bool) bool { return b != nil && *b }

func deny(format string, args ...any) Decision {
	return Decision{Verdict: Deny, Reason: fmt.Sprintf(format, args...)}
}

// override is one row of overrides.go.
type override struct {
	Server, Tool string
	Verdict      Verdict
	Inspect      inspection
	Why          string
}

// inspection names an input check an override row runs before its verdict.
type inspection int

const (
	inspectNone inspection = iota
	// inspectDocsWrite asks when a Claude Docs write could reach beyond the
	// owner's private doc: an object delete, a JSON-patch remove, a share
	// field, or a mention of someone else (a mention can email them).
	inspectDocsWrite
)

func findOverride(server, tool string) (override, bool) {
	for _, row := range overrides {
		if row.Server == server && row.Tool == tool {
			return row, true
		}
	}
	return override{}, false
}

func (o override) decide(input json.RawMessage) Decision {
	if o.Inspect == inspectDocsWrite {
		if reason, risky := docsWriteRisk(input); risky {
			return Decision{Verdict: Ask, Reason: reason}
		}
	}
	return Decision{Verdict: o.Verdict, Reason: o.Why}
}

// shareKeys are object keys that would change who can see a doc. No Claude
// Docs tool shares today; a key like these appearing asks instead of passing.
var shareKeys = map[string]bool{
	"share": true, "sharing": true, "shared": true, "visibility": true,
	"permission": true, "permissions": true, "access": true, "public": true,
	"collaborators": true, "invite": true, "invites": true,
}

// docsWriteRisk walks a Claude Docs write input and reports the first reason
// it must go through Approve. Input that does not parse asks too.
func docsWriteRisk(input json.RawMessage) (string, bool) {
	var v any
	if err := json.Unmarshal(input, &v); err != nil {
		return "Claude Docs input could not be read", true
	}
	return walkDocsValue(v)
}

func walkDocsValue(v any) (string, bool) {
	switch t := v.(type) {
	case map[string]any:
		if verb, _ := t["verb"].(string); verb == "delete" {
			return "Claude Docs call deletes a doc object", true
		}
		if op, _ := t["op"].(string); op == "remove" {
			return "Claude Docs call removes part of a doc", true
		}
		if typ, _ := t["type"].(string); typ == "mention" {
			if user, has := t["user"]; has && user != "me" {
				return "Claude Docs call mentions someone, which can email them", true
			}
		}
		for k, child := range t {
			if shareKeys[strings.ToLower(k)] {
				return "Claude Docs call may change who can see a doc", true
			}
			if reason, risky := walkDocsValue(child); risky {
				return reason, true
			}
		}
	case []any:
		for _, child := range t {
			if reason, risky := walkDocsValue(child); risky {
				return reason, true
			}
		}
	}
	return "", false
}
