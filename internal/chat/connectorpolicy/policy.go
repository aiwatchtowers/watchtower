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
// for every connector call, a nil PathCheck denies every path, a nil
// OwnArtifact asks before updating any existing artifact and a nil OwnDoc
// asks before any Claude Docs write to an existing doc. Disabled is the
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
	// OwnDoc reports whether this session created the Claude Docs doc id (a
	// bare id or its claude.ai link). A Docs write to any other doc asks:
	// only the owner's own new private doc is free (ask #236).
	OwnDoc func(id string) bool
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

	// Only a claude.ai connector passes, and the request's own server name
	// must map to the token in the tool name: a local server named
	// "claude_ai_Claude_Docs" or a mismatch would borrow another server's rules.
	server, tool, ok := ParseToolName(c.Tool)
	if !ok || !strings.HasPrefix(c.Server, "claude.ai ") || ServerToken(c.Server) != server {
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
		return p.decideOverride(row, c.Input)
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
			return joinRaw(root, p)
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
			var path string
			if json.Unmarshal(raw, &path) == nil {
				out = append(out, resolve(path))
				continue
			}
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
	for _, rel := range paths {
		if filepath.IsAbs(rel) || p.checkPath(joinRaw(outDir, rel)) != nil {
			return deny("Artifact read path %q must stay inside %s", rel, p.PublishDir)
		}
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
	return joinRaw(dir, "probe")
}

// joinRaw joins without filepath.Join's clean, so a ".." in either part still
// reaches checkPath's refusal.
func joinRaw(dir, rel string) string {
	return strings.TrimSuffix(dir, "/") + "/" + rel
}

// checkPath refuses a ".." component before PathCheck sees the path: a
// lexical clean would fold "dir/link/../x" without looking at "link".
func (p Policy) checkPath(path string) error {
	if p.PathCheck == nil || path == "" {
		return fmt.Errorf("no publish dir")
	}
	if hasDotDot(path) {
		return fmt.Errorf("path has a .. component")
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

// caseVariant reports whether f has a key spelled like one of keys in another
// case: the gate reads exact keys, a server matching them loosely might not.
func (f fields) caseVariant(keys ...string) bool {
	for k := range f {
		for _, want := range keys {
			if k != want && strings.EqualFold(k, want) {
				return true
			}
		}
	}
	return false
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

func (p Policy) decideOverride(o override, input json.RawMessage) Decision {
	if o.CheckDocsWrite {
		if reason, risky := docsWriteRisk(input); risky {
			return Decision{Verdict: Ask, Reason: reason}
		}
		if !p.docsWriteStaysInOwnDoc(o.Tool, input) {
			return Decision{Verdict: Ask, Reason: "Claude Docs call changes a doc this chat did not create"}
		}
	}
	return Decision{Verdict: o.Verdict, Reason: o.Why}
}

// docsWriteStaysInOwnDoc reports whether a Claude Docs create/update/batch
// only touches a doc this session created, read by exact key: a batch whose
// container births a new doc, or a container naming an own doc, with every
// ref anywhere inside the call proven to stay in it (refRule, nestedRefsOK). Anything else — a call naming no doc, a key
// it reads also spelled in another case, a value of the wrong type, a
// member-level container — fails: an unproven write asks.
func (p Policy) docsWriteStaysInOwnDoc(tool string, input json.RawMessage) bool {
	in, err := parseObject(input)
	if err != nil || in.caseVariant("container", "ref", "batch") {
		return false
	}
	rawContainer, hasContainer := in["container"]
	rawRef, hasRef := in["ref"]
	switch {
	case hasContainer:
		container, err := parseObject(rawContainer)
		if err != nil || container.caseVariant("kind", "id", "create") {
			return false
		}
		_, hasID := container["id"]
		if create, ok := container["create"]; ok && !hasID {
			if tool != "batch" || isNull(create) {
				return false
			}
		} else if !p.ownDocRef(container, "kind") {
			return false
		}
		if hasRef && !p.refRule(rawRef, false) {
			return false
		}
	case hasRef:
		// No container: the ref itself must be an own doc (a rename, a tabs
		// patch).
		ref, err := parseObject(rawRef)
		if err != nil || !p.ownDocRef(ref, "object") {
			return false
		}
	default:
		return false
	}
	return p.batchMembersStayInOwnDoc(in) && p.nestedRefsOK(in)
}

// ownDocRef reports whether obj names an own doc: obj[kindKey] is "project"
// and obj["id"] is a doc this session created.
func (p Policy) ownDocRef(obj fields, kindKey string) bool {
	if obj.caseVariant(kindKey, "id") {
		return false
	}
	kind, _, err := obj.str(kindKey)
	if err != nil || kind != "project" {
		return false
	}
	id, ok, err := obj.str("id")
	return err == nil && ok && id != "" && p.OwnDoc != nil && p.OwnDoc(id)
}

// refRule judges a ref inside an own (or newborn) container: a node is
// addressed through the container, a doc must be own — or, in a batch, the
// doc being born ("$lid:…") — and a tab may be one the batch itself makes.
// A tab, comment or anything else named by a real id may live in another
// doc (those ids are global), so it asks.
func (p Policy) refRule(raw json.RawMessage, inBatch bool) bool {
	ref, err := parseObject(raw)
	if err != nil {
		return false
	}
	return p.refFieldsRule(ref, inBatch)
}

func (p Policy) refFieldsRule(ref fields, inBatch bool) bool {
	if ref.caseVariant("object", "id") {
		return false
	}
	object, ok, err := ref.str("object")
	if err != nil || !ok {
		return false
	}
	id, ok, err := ref.str("id")
	if err != nil || !ok {
		return false
	}
	newborn := inBatch && strings.HasPrefix(id, "$lid:")
	switch strings.ToLower(object) {
	case "node":
		return true
	case "project":
		return newborn || p.ownDocRef(ref, "object")
	case "file":
		return newborn
	default:
		return false
	}
}

// batchMembersStayInOwnDoc applies refRule to every batch member's ref; a
// member carrying its own container asks.
func (p Policy) batchMembersStayInOwnDoc(in fields) bool {
	raw, ok := in["batch"]
	if !ok || isNull(raw) {
		return true
	}
	var members []json.RawMessage
	if json.Unmarshal(raw, &members) != nil {
		return false
	}
	for _, m := range members {
		member, err := parseObject(m)
		if err != nil || member.caseVariant("ref", "container") {
			return false
		}
		if _, ok := member["container"]; ok {
			return false
		}
		if ref, ok := member["ref"]; ok && !p.refRule(ref, true) {
			return false
		}
	}
	return true
}

// nestedRefsOK walks every value of the call except the top-level container
// (checked by the caller) — and the type a create or a batch member names
// with its own "object" key — and holds each nested object to refRule: any
// object carrying an "object" key is a ref, any carrying "kind":"project"
// must name an own doc, and a "parent" or "answering" that is not a ref
// object (a bare comment or thread id) asks. So a comment's parent, a
// thread answer or a doc named deep in a payload is never one the gate did
// not check.
func (p Policy) nestedRefsOK(in fields) bool {
	for k, raw := range in {
		if k == "container" {
			continue
		}
		var v any
		if json.Unmarshal(raw, &v) != nil {
			return false
		}
		if strings.EqualFold(k, "parent") || strings.EqualFold(k, "answering") {
			if _, isObject := v.(map[string]any); !isObject {
				return false
			}
		}
		members := k == "batch"
		if list, ok := v.([]any); ok && members {
			for _, m := range list {
				member, ok := m.(map[string]any)
				if !ok || !p.childrenOK(member, true) {
					return false
				}
			}
			continue
		}
		if !p.valueOK(v, members) {
			return false
		}
	}
	return true
}

// valueOK applies the nestedRefsOK rules to v and everything under it.
func (p Policy) valueOK(v any, inBatch bool) bool {
	switch t := v.(type) {
	case map[string]any:
		for k, val := range t {
			s, _ := val.(string)
			switch {
			case strings.EqualFold(k, "object"):
				raw, err := json.Marshal(t)
				if err != nil || !p.refRule(raw, inBatch) {
					return false
				}
			case strings.EqualFold(k, "kind") && strings.EqualFold(s, "project"):
				if !p.ownDocRef(fieldsOf(t), k) {
					return false
				}
			}
		}
		return p.childrenOK(t, inBatch)
	case []any:
		for _, val := range t {
			if !p.valueOK(val, inBatch) {
				return false
			}
		}
	}
	return true
}

// childrenOK applies valueOK to every value of obj (not to obj itself), and
// asks when a "parent" or "answering" there is not an object.
func (p Policy) childrenOK(obj map[string]any, inBatch bool) bool {
	for k, val := range obj {
		if strings.EqualFold(k, "parent") || strings.EqualFold(k, "answering") {
			if _, isObject := val.(map[string]any); !isObject {
				return false
			}
		}
		if !p.valueOK(val, inBatch) {
			return false
		}
	}
	return true
}

// fieldsOf re-encodes a decoded object for the exact-key readers; a value
// that cannot be encoded back is dropped, which only fails a check.
func fieldsOf(m map[string]any) fields {
	f := fields{}
	for k, v := range m {
		if raw, err := json.Marshal(v); err == nil {
			f[k] = raw
		}
	}
	return f
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
	mention := false
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
		}
	}
	if mention && !harmlessMention(obj) {
		return "Claude Docs call mentions someone, which can email them", true
	}
	return "", false
}

// harmlessMention passes only a mention of the owner ("user": "me", the one
// user key anywhere in it) or of a tab or doc (a "ref" and no user key).
func harmlessMention(obj map[string]any) bool {
	switch countUserKeys(obj) {
	case 0:
		_, isRef := obj["ref"].(string)
		return isRef
	case 1:
		return obj["user"] == "me"
	default:
		return false
	}
}

// countUserKeys counts keys spelled like "user" in any case, at any depth.
func countUserKeys(v any) int {
	n := 0
	switch t := v.(type) {
	case map[string]any:
		for k, child := range t {
			if strings.EqualFold(k, "user") {
				n++
			}
			n += countUserKeys(child)
		}
	case []any:
		for _, child := range t {
			n += countUserKeys(child)
		}
	}
	return n
}
