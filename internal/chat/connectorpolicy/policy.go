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

// Policy is the per-session input of the decision table. A nil Catalog asks
// for every connector call, a nil PathCheck denies every path and a nil
// OwnArtifact asks before updating any existing artifact. Disabled is the
// one field whose nil value allows: it means nothing is switched off, so the
// caller must not pass nil when it failed to load the owner's switches.
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

	// The request's own server name must map to the token in the tool name;
	// a mismatch means the rules below would classify another server's tool.
	server, tool, ok := ParseToolName(c.Tool)
	if !ok || !strings.HasPrefix(server, "claude_ai_") || ServerToken(c.Server) != server {
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
	in, err := parseObject(c.Input)
	if err == nil {
		var path string
		path, _, err = in.str("file_path")
		if err == nil {
			err = p.checkPath(path)
		}
	}
	if err != nil {
		return deny("%s may only use files inside %s", c.Tool, p.PublishDir)
	}
	return Decision{Verdict: Allow, Reason: "inside the publish dir"}
}

func (p Policy) decideArtifact(input json.RawMessage) Decision {
	in, err := parseObject(input)
	if err != nil {
		return deny("Artifact input: %v", err)
	}
	action, present, err := in.str("action")
	if err != nil {
		return deny("Artifact input: %v", err)
	}
	if !present {
		action = "publish"
	}
	switch action {
	case "publish":
		return p.decideArtifactPublish(in)
	case "read":
		return p.decideArtifactRead(in)
	case "list", "open", "quickstart":
		return Decision{Verdict: Allow, Reason: "Artifact " + action}
	case "delete", "pin", "unpin":
		return Decision{Verdict: Ask, Reason: "Artifact " + action + " changes an existing artifact"}
	default:
		return deny("Artifact action %q is not available in this chat", action)
	}
}

func (p Policy) decideArtifactPublish(in fields) Decision {
	sources, err := publishSources(in)
	if err != nil {
		return deny("Artifact publish: %v", err)
	}
	for _, src := range sources {
		if p.checkPath(src) != nil {
			return deny("Artifact may only publish files inside %s", p.PublishDir)
		}
	}
	force, err := in.flag("force")
	if err != nil {
		return deny("Artifact publish: %v", err)
	}
	pin, err := in.flag("pin")
	if err != nil {
		return deny("Artifact publish: %v", err)
	}
	url, _, err := in.str("url")
	if err != nil {
		return deny("Artifact publish: %v", err)
	}
	switch {
	case force:
		return Decision{Verdict: Ask, Reason: "Artifact publish with force overwrites a newer version"}
	case pin:
		return Decision{Verdict: Ask, Reason: "Artifact publish also pins the artifact"}
	case url != "" && (p.OwnArtifact == nil || !p.OwnArtifact(url)):
		return Decision{Verdict: Ask, Reason: "Artifact publish updates an artifact this chat did not publish"}
	}
	return Decision{Verdict: Allow, Reason: "private publish from the publish dir"}
}

// publishSources lists every local path an Artifact publish reads: file_path,
// file_paths, each files source and root. A files source relative to root is
// joined to it, the way the CLI resolves it.
func publishSources(in fields) ([]string, error) {
	var out []string
	root, hasRoot, err := in.str("root")
	if err != nil {
		return nil, err
	}
	if hasRoot {
		out = append(out, dirProbe(root))
	}
	resolve := func(p string) string {
		if root != "" && !filepath.IsAbs(p) {
			return filepath.Join(root, p)
		}
		return p
	}
	if path, ok, err := in.str("file_path"); err != nil {
		return nil, err
	} else if ok {
		out = append(out, path)
	}
	paths, err := in.strList("file_paths")
	if err != nil {
		return nil, err
	}
	out = append(out, paths...)

	files := bytes.TrimSpace(in["files"])
	if len(files) == 0 || bytes.Equal(files, []byte("null")) {
		return out, nil
	}
	switch files[0] {
	case '[':
		var list []json.RawMessage
		if err := json.Unmarshal(files, &list); err != nil {
			return nil, fmt.Errorf("files list has an unexpected shape")
		}
		for i, raw := range list {
			entry, err := parseObject(raw)
			if err != nil {
				return nil, fmt.Errorf("files[%d]: %w", i, err)
			}
			path, ok, err := entry.str("path")
			if err != nil || !ok {
				return nil, fmt.Errorf("files[%d] has no path", i)
			}
			out = append(out, resolve(path))
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
	obj, err := parseObject(raw)
	if err != nil {
		return "", false, fmt.Errorf("unexpected source shape")
	}
	from, hasFrom, err := obj.str("from")
	if err != nil {
		return "", false, err
	}
	_, hasArtifact, err := obj.str("artifact")
	if err != nil {
		return "", false, err
	}
	switch {
	case hasFrom && !hasArtifact:
		return from, true, nil
	case hasArtifact && !hasFrom:
		return "", false, nil
	default:
		return "", false, fmt.Errorf("unexpected source shape")
	}
}

// decideArtifactRead keeps a read's saved files in the publish dir: an
// out_dir must be inside it, a missing one is set to it, and a published
// path that could climb out of out_dir is refused.
func (p Policy) decideArtifactRead(in fields) Decision {
	paths, err := in.strList("paths")
	if err != nil {
		return deny("Artifact read: %v", err)
	}
	path, hasPath, err := in.str("path")
	if err != nil {
		return deny("Artifact read: %v", err)
	}
	if hasPath {
		paths = append(paths, path)
	}
	for _, rel := range paths {
		if filepath.IsAbs(rel) || hasDotDot(rel) {
			return deny("Artifact read path %q must stay inside %s", rel, p.PublishDir)
		}
	}

	outDir, hasOutDir, err := in.str("out_dir")
	if err != nil {
		return deny("Artifact read: %v", err)
	}
	if !hasOutDir {
		outDir = p.PublishDir
	}
	if p.checkPath(dirProbe(outDir)) != nil {
		return deny("Artifact may only save inside %s", p.PublishDir)
	}
	if hasOutDir {
		return Decision{Verdict: Allow, Reason: "read into the publish dir"}
	}
	// Marshalling a string and a map of valid raw values cannot fail.
	in["out_dir"], _ = json.Marshal(p.PublishDir)
	updated, _ := json.Marshal(map[string]json.RawMessage(in))
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

// checkPath refuses a ".." component before PathCheck sees the path: a
// lexical clean would fold "dir/link/../x" without looking at "link".
func (p Policy) checkPath(path string) error {
	if p.PathCheck == nil || path == "" {
		return fmt.Errorf("no publish dir")
	}
	if hasDotDot(path) {
		return fmt.Errorf("path climbs with ..")
	}
	return p.PathCheck(path)
}

func hasDotDot(path string) bool {
	for _, part := range strings.Split(filepath.ToSlash(path), "/") {
		if part == ".." {
			return true
		}
	}
	return false
}

// fields is a tool input read by exact key. encoding/json matches struct
// fields case-insensitively while the CLI reads exact keys, so a struct would
// let {"file_path": outside, "FILE_PATH": inside} check one path and run the
// other.
type fields map[string]json.RawMessage

func parseObject(raw json.RawMessage) (fields, error) {
	var m fields
	if err := json.Unmarshal(raw, &m); err != nil || m == nil {
		return nil, fmt.Errorf("input is not a JSON object")
	}
	return m, nil
}

func isNull(raw json.RawMessage) bool {
	return bytes.Equal(bytes.TrimSpace(raw), []byte("null"))
}

// str reads a string field; present but null or not a string is an error.
func (f fields) str(key string) (string, bool, error) {
	raw, ok := f[key]
	if !ok {
		return "", false, nil
	}
	var s string
	if isNull(raw) || json.Unmarshal(raw, &s) != nil {
		return "", true, fmt.Errorf("%s is not a string", key)
	}
	return s, true, nil
}

// flag reads a bool field; absent is false, null or not a bool is an error.
func (f fields) flag(key string) (bool, error) {
	raw, ok := f[key]
	if !ok {
		return false, nil
	}
	var b bool
	if isNull(raw) || json.Unmarshal(raw, &b) != nil {
		return false, fmt.Errorf("%s is not a boolean", key)
	}
	return b, nil
}

// strList reads a list of strings; absent is empty, anything else is an error.
func (f fields) strList(key string) ([]string, error) {
	raw, ok := f[key]
	if !ok {
		return nil, nil
	}
	var list []string
	if isNull(raw) || json.Unmarshal(raw, &list) != nil {
		return nil, fmt.Errorf("%s is not a list of strings", key)
	}
	return list, nil
}

// ServerToken maps a server display name to the CLI's mcp__<token>__ form:
// every rune outside [A-Za-z0-9_-] becomes "_" ("claude.ai Claude Docs" →
// "claude_ai_Claude_Docs"). For a claude.ai connector the CLI also folds runs
// of "_" into one and trims them from both ends.
func ServerToken(displayName string) string {
	var b strings.Builder
	for _, r := range displayName {
		if r == '_' || r == '-' || (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') {
			b.WriteRune(r)
		} else {
			b.WriteByte('_')
		}
	}
	token := b.String()
	if !strings.HasPrefix(displayName, "claude.ai ") {
		return token
	}
	for strings.Contains(token, "__") {
		token = strings.ReplaceAll(token, "__", "_")
	}
	return strings.Trim(token, "_")
}

// ParseToolName splits mcp__<server>__<tool> the way the CLI does: the server
// token runs to the first "__" after the prefix, the rest is the tool.
func ParseToolName(raw string) (serverToken, tool string, ok bool) {
	rest, found := strings.CutPrefix(raw, "mcp__")
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

// override is one row of overrides.go. CheckDocsWrite asks instead of the
// row's verdict when a Claude Docs write could reach beyond the owner's
// private doc (docsWriteRisk).
type override struct {
	Server, Tool   string
	Verdict        Verdict
	CheckDocsWrite bool
	Why            string
}

func findOverride(server, tool string) (override, bool) {
	for _, row := range overrides {
		if row.Server == server && row.Tool == tool {
			return row, true
		}
	}
	return override{}, false
}

func (o override) decide(input json.RawMessage) Decision {
	if o.CheckDocsWrite {
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
// it must go through Approve: an object delete, a JSON-patch remove, a share
// field, a mention of anyone but the owner (a mention can email them), or a
// payload sent as a string the walk cannot see into. Input that is not a JSON
// object asks too. Keys and values compare case-insensitively, so a spelling
// the server would ignore only asks more often.
func docsWriteRisk(input json.RawMessage) (string, bool) {
	var v map[string]any
	if err := json.Unmarshal(input, &v); err != nil || v == nil {
		return "Claude Docs input could not be read", true
	}
	return walkDocsValue(v)
}

func walkDocsValue(v any) (string, bool) {
	switch t := v.(type) {
	case map[string]any:
		if reason, risky := docsObjectRisk(t); risky {
			return reason, true
		}
		for _, child := range t {
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

func docsObjectRisk(obj map[string]any) (string, bool) {
	var mention, refMention bool
	userKeys := 0
	for k, val := range obj {
		s, isString := val.(string)
		switch key := strings.ToLower(k); {
		case shareKeys[key]:
			return "Claude Docs call may change who can see a doc", true
		case key == "verb" && strings.EqualFold(s, "delete"):
			return "Claude Docs call deletes a doc object", true
		case key == "op" && strings.EqualFold(s, "remove"):
			return "Claude Docs call removes part of a doc", true
		case key == "payload" && isString:
			return "Claude Docs call sends a payload the gate cannot inspect", true
		case key == "type" && strings.EqualFold(s, "mention"):
			mention = true
		case key == "user":
			userKeys++
		case key == "ref":
			refMention = isString
		}
	}
	ownerMention := userKeys == 1 && obj["user"] == "me"
	if mention && !ownerMention && (userKeys > 0 || !refMention) {
		return "Claude Docs call mentions someone, which can email them", true
	}
	return "", false
}
