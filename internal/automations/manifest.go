package automations

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"path"
	"regexp"
	"slices"
	"strings"
	"unicode"

	"watchtower/internal/db"
	"watchtower/internal/tools"
)

// Permission kinds that are not capability rows (spec §3.1).
const (
	kindTool  = "tool"
	kindMCP   = "mcp"
	kindShell = "shell"
)

// scopeRule is how a capability takes an "@scope".
type scopeRule int

const (
	scopeNone     scopeRule = iota // "@" refused
	scopeRequired                  // "@scope" required, "*" = all
	scopeOptional                  // "@kind" optional, none = every kind
)

// capabilitySpec is one row of the spec §3.1 capability table.
type capabilitySpec struct {
	verbs []string
	scope scopeRule
	// upperScope marks scopes normalised to upper case (Jira project keys,
	// Confluence space keys); every other scope is lower case.
	upperScope bool
	// scopeValues, when set, is the closed set an optional scope may take.
	scopeValues []string
	// workbenchOnly capabilities are refused in a personal recipe (D7).
	workbenchOnly bool
}

var readWrite = []string{"read", "write"}

var capabilitySpecs = map[string]capabilitySpec{
	"slack":       {verbs: readWrite, scope: scopeRequired},
	"gmail":       {verbs: readWrite, scope: scopeRequired},
	"calendar":    {verbs: readWrite, scope: scopeRequired},
	"jira":        {verbs: readWrite, scope: scopeRequired, upperScope: true},
	"confluence":  {verbs: readWrite, scope: scopeRequired, upperScope: true},
	"targets":     {verbs: readWrite},
	"tracks":      {verbs: readWrite},
	"ideas":       {verbs: readWrite},
	"digests":     {verbs: readWrite},
	"people":      {verbs: readWrite},
	"transcripts": {verbs: readWrite},
	"meetings":    {verbs: []string{"read"}},
	"dayplan":     {verbs: []string{"read"}},
	"llm":         {verbs: []string{"light", "strong"}},
	"agent":       {verbs: []string{"run"}},
	"ask":         {verbs: []string{"owner"}, workbenchOnly: true},
	"session":     {verbs: []string{"start"}, scope: scopeOptional, scopeValues: []string{"claude", "codex"}, workbenchOnly: true},
}

// removedCapabilities are capability names refused with a pointer to the
// tool: entries to list instead: their tools read across sources, so only an
// explicit tool:<name> admits each (spec §3.1, D21).
var removedCapabilities = map[string]string{
	"knowledge": "there is no knowledge capability; list the tools: " +
		"tool:search_knowledge, tool:get_knowledge_document, tool:get_task_context",
}

// outputKinds are the kinds a recipe may list under outputs (spec §2.3).
var outputKinds = []string{"inbox", "briefing", "report", "target", "slack"}

var toolNamePattern = regexp.MustCompile(`^[a-z0-9_]+$`)

// Permission is one parsed manifest entry (spec §3.1). Capability is the
// capability name for capability rows and "tool"/"mcp"/"shell" otherwise.
type Permission struct {
	Raw        string
	Capability string
	Verb       string
	Scope      string
	Tool       string
	MCPServer  string
	MCPGlob    string
	Shell      string
}

// ParsePermission parses one manifest entry.
func ParsePermission(s string) (Permission, error) {
	raw := s
	s = strings.TrimSpace(s)
	head, rest, ok := strings.Cut(s, ":")
	if !ok {
		return Permission{}, fmt.Errorf("invalid permission %q: want capability:verb[@scope], tool:<name>, mcp:<server>/<glob> or shell:\"<command>\"", raw)
	}
	var (
		p   Permission
		err error
	)
	switch strings.ToLower(head) {
	case kindTool:
		p, err = parseToolPermission(rest)
	case kindMCP:
		p, err = parseMCPPermission(rest)
	case kindShell:
		p, err = parseShellPermission(rest)
	default:
		p, err = parseCapabilityPermission(strings.ToLower(head), rest)
	}
	if err != nil {
		return Permission{}, fmt.Errorf("invalid permission %q: %w", raw, err)
	}
	p.Raw = raw
	return p, nil
}

func parseToolPermission(name string) (Permission, error) {
	if !toolNamePattern.MatchString(name) {
		return Permission{}, fmt.Errorf("tool name must match %s", toolNamePattern.String())
	}
	return Permission{Capability: kindTool, Tool: name}, nil
}

func parseMCPPermission(rest string) (Permission, error) {
	server, glob, ok := strings.Cut(rest, "/")
	switch {
	case !ok || server == "" || glob == "":
		return Permission{}, errors.New("want mcp:<server>/<tool-glob>")
	case strings.ContainsAny(server, `*?[\`):
		return Permission{}, errors.New("the server name is exact; a glob is allowed only in the tool part")
	case strings.Contains(glob, "/"):
		return Permission{}, errors.New("the tool glob cannot contain /")
	}
	if _, err := path.Match(glob, ""); err != nil {
		return Permission{}, fmt.Errorf("bad tool glob: %w", err)
	}
	return Permission{Capability: kindMCP, MCPServer: server, MCPGlob: glob}, nil
}

func parseShellPermission(rest string) (Permission, error) {
	if !strings.HasPrefix(rest, `"`) {
		return Permission{}, errors.New(`the command must be double-quoted, e.g. shell:"make release"`)
	}
	var cmd string
	if err := json.Unmarshal([]byte(rest), &cmd); err != nil {
		return Permission{}, fmt.Errorf("the command must be one JSON string: %w", err)
	}
	if strings.TrimSpace(cmd) == "" {
		return Permission{}, errors.New("the command is empty")
	}
	return Permission{Capability: kindShell, Shell: cmd}, nil
}

func parseCapabilityPermission(capability, rest string) (Permission, error) {
	if msg, ok := removedCapabilities[capability]; ok {
		return Permission{}, errors.New(msg)
	}
	spec, ok := capabilitySpecs[capability]
	if !ok {
		return Permission{}, fmt.Errorf("unknown capability %q", capability)
	}
	verb, scope, hasScope := strings.Cut(rest, "@")
	verb = strings.ToLower(verb)
	if !slices.Contains(spec.verbs, verb) {
		return Permission{}, fmt.Errorf("capability %s has no verb %q (want %s)", capability, verb, strings.Join(spec.verbs, "|"))
	}
	scope, err := checkScope(capability, spec, scope, hasScope)
	if err != nil {
		return Permission{}, err
	}
	return Permission{Capability: capability, Verb: verb, Scope: scope}, nil
}

// checkScope validates and normalises an entry's scope against its row.
func checkScope(capability string, spec capabilitySpec, scope string, hasScope bool) (string, error) {
	if err := checkScopePresence(capability, spec.scope, scope, hasScope); err != nil || !hasScope {
		return "", err
	}
	scope = normaliseScope(spec, scope)
	if len(spec.scopeValues) > 0 && !slices.Contains(spec.scopeValues, scope) {
		return "", fmt.Errorf("%s scope must be one of %s", capability, strings.Join(spec.scopeValues, "|"))
	}
	if _, err := path.Match(scope, ""); err != nil {
		return "", fmt.Errorf("bad scope glob %q: %w", scope, err)
	}
	return scope, nil
}

// checkScopePresence enforces the row's scope rule: refused, required or
// optional (but never empty after "@").
func checkScopePresence(capability string, rule scopeRule, scope string, hasScope bool) error {
	switch {
	case rule == scopeNone && hasScope:
		return fmt.Errorf("%s takes no @scope", capability)
	case rule == scopeRequired && (!hasScope || scope == ""):
		return fmt.Errorf("%s needs an @scope (an account, project or space; @* = all)", capability)
	case hasScope && scope == "":
		return fmt.Errorf("%s: empty @scope", capability)
	case strings.ContainsFunc(scope, unicode.IsSpace):
		return fmt.Errorf("%s: the @scope cannot contain whitespace", capability)
	}
	return nil
}

func normaliseScope(spec capabilitySpec, scope string) string {
	if spec.upperScope {
		return strings.ToUpper(scope)
	}
	return strings.ToLower(scope)
}

// String is the normalised form (spec §3.1): lower-case capability, verb and
// scope (Jira and Confluence scopes upper-case); a shell command re-quoted as
// JSON without HTML escaping.
func (p Permission) String() string {
	switch p.Capability {
	case kindTool:
		return "tool:" + p.Tool
	case kindMCP:
		return "mcp:" + p.MCPServer + "/" + p.MCPGlob
	case kindShell:
		return "shell:" + quoteJSON(p.Shell)
	}
	s := p.Capability + ":" + p.Verb
	if p.Scope != "" {
		s += "@" + normaliseScope(capabilitySpecs[p.Capability], p.Scope)
	}
	return s
}

func quoteJSON(s string) string {
	var buf bytes.Buffer
	writeCanonical(&buf, s)
	return buf.String()
}

// ManifestError is a manifest entry ParseManifest refuses; Field is
// "permissions" or "outputs" and Index the entry's position in it.
type ManifestError struct {
	Field string
	Index int
	Msg   string
}

func (e *ManifestError) Error() string { return e.Msg }

// Manifest is a recipe's validated permissions and outputs.
type Manifest struct {
	entries []Permission
	outputs []string
}

// ParseManifest validates a recipe's permissions and outputs (spec §3.1).
// Duplicates are folded; every refusal is a *ManifestError.
func ParseManifest(entries []string, outputs []string, scope Scope) (*Manifest, error) {
	m := &Manifest{entries: []Permission{}, outputs: []string{}}
	seen := map[string]bool{}
	for i, e := range entries {
		p, err := ParsePermission(e)
		if err != nil {
			return nil, &ManifestError{Field: "permissions", Index: i, Msg: err.Error()}
		}
		if scope.Kind != ScopeWorkbench && workbenchOnly(p) {
			return nil, &ManifestError{Field: "permissions", Index: i,
				Msg: fmt.Sprintf("%q is allowed only in a workbench recipe, not a personal one", e)}
		}
		if n := p.String(); !seen[n] {
			seen[n] = true
			m.entries = append(m.entries, p)
		}
	}
	for i, o := range outputs {
		if !slices.Contains(outputKinds, o) {
			return nil, &ManifestError{Field: "outputs", Index: i,
				Msg: fmt.Sprintf("unknown output %q (want %s)", o, strings.Join(outputKinds, "|"))}
		}
		if !slices.Contains(m.outputs, o) {
			m.outputs = append(m.outputs, o)
		}
	}
	slices.Sort(m.outputs)
	return m, nil
}

func workbenchOnly(p Permission) bool {
	return p.Capability == kindShell || capabilitySpecs[p.Capability].workbenchOnly
}

// Normalized returns the normalised entries, sorted and deduplicated (never
// nil) — what ApprovalHash binds.
func (m *Manifest) Normalized() []string {
	out := make([]string, 0, len(m.entries))
	for _, p := range m.entries {
		out = append(out, p.String())
	}
	slices.Sort(out)
	return out
}

// Outputs returns the declared output kinds, sorted and deduplicated.
func (m *Manifest) Outputs() []string { return slices.Clone(m.outputs) }

// normalizedPermissions is the hash form of raw entries: each normalised when
// it parses, kept verbatim when it does not (such a recipe is never runnable,
// so its hash binds nothing), sorted and deduplicated.
func normalizedPermissions(raw []string) []string {
	out := make([]string, 0, len(raw))
	for _, e := range raw {
		if p, err := ParsePermission(e); err == nil {
			e = p.String()
		}
		out = append(out, e)
	}
	return sortedCopy(out)
}

// PermissionDenied is a check the manifest refuses; Needed is the entry that
// would have admitted the call (thrown to the script as needed, AUTO-11).
type PermissionDenied struct {
	// Needed is empty when no entry can admit the call (Reason says why).
	Needed string
	// Reason, when set, replaces the default message.
	Reason string
	// Cause is the scope lookup error behind a denial (a DB or context
	// error, undecodable args), for the executor's log; the script only
	// sees Needed.
	Cause error
}

func (e *PermissionDenied) Error() string {
	msg := "permission denied: the recipe needs " + e.Needed
	if e.Reason != "" {
		msg = "permission denied: " + e.Reason
	}
	if e.Cause != nil {
		msg += " (" + e.Cause.Error() + ")"
	}
	return msg
}

func (e *PermissionDenied) Unwrap() error { return e.Cause }

func denied(needed string) error { return &PermissionDenied{Needed: needed} }

// AllowTool checks one registry tool call (spec §3.2). d resolves account
// ids/addresses to labels; it may be nil for tools whose scope needs no
// lookup (a lookup on a nil d is denied, never a panic).
func (m *Manifest) AllowTool(ctx context.Context, d *db.DB, t *tools.Tool, args json.RawMessage) (string, error) {
	toolEntry := "tool:" + t.Name
	if !t.VisibleOn(tools.AutomationSurface) {
		return "", &PermissionDenied{Reason: t.Name + " is not available to automations"}
	}
	if m.has(toolEntry) {
		return toolEntry, nil
	}
	c, ok := ToolCapabilities[t.Name]
	if !ok {
		return "", denied(toolEntry)
	}
	spec := capabilitySpecs[c.Capability]
	if spec.scope != scopeRequired {
		return m.allowUnscoped(c.Capability, c.Verb)
	}
	units, err := c.scopes(ctx, d, args)
	if err != nil {
		return "", &PermissionDenied{Needed: Permission{Capability: c.Capability, Verb: c.Verb, Scope: "*"}.String(), Cause: err}
	}
	return m.allowUnits(c.Capability, c.Verb, units)
}

func (m *Manifest) has(normalised string) bool {
	return slices.ContainsFunc(m.entries, func(p Permission) bool { return p.String() == normalised })
}

func (m *Manifest) allowUnscoped(capability, verb string) (string, error) {
	e := Permission{Capability: capability, Verb: verb}.String()
	if m.has(e) {
		return e, nil
	}
	return "", denied(e)
}

// allowUnits admits a scoped call when every unit is covered by some entry
// of the capability+verb; no unit (an absent scope) is covered only by @*.
func (m *Manifest) allowUnits(capability, verb string, units []CallScope) (string, error) {
	need := func(scope string) error {
		return denied(Permission{Capability: capability, Verb: verb, Scope: scope}.String())
	}
	if len(units) == 0 {
		star := Permission{Capability: capability, Verb: verb, Scope: "*"}.String()
		if m.has(star) {
			return star, nil
		}
		return "", need("*")
	}
	var by []string
	for _, u := range units {
		e, ok := m.entryCovering(capability, verb, u)
		if !ok {
			return "", need(u.Values[0])
		}
		if !slices.Contains(by, e) {
			by = append(by, e)
		}
	}
	return strings.Join(by, ", "), nil
}

func (m *Manifest) entryCovering(capability, verb string, u CallScope) (string, bool) {
	for _, p := range m.entries {
		if p.Capability != capability || p.Verb != verb {
			continue
		}
		if slices.ContainsFunc(u.Values, func(v string) bool { return scopeMatches(p.Scope, v) }) {
			return p.String(), true
		}
	}
	return "", false
}

// scopeMatches is spec §3.2 scope matching: "*" covers everything, else
// case-insensitive equality or a path.Match glob.
func scopeMatches(pattern, value string) bool {
	if pattern == "*" {
		return true
	}
	if value == "" {
		return false
	}
	ok, err := path.Match(strings.ToLower(pattern), strings.ToLower(value))
	return err == nil && ok
}

// AllowLLM checks an llm() call of tier "light" or "strong"; llm:strong
// implies llm:light.
func (m *Manifest) AllowLLM(tier string) (string, error) {
	want := "llm:" + tier
	if m.has(want) {
		return want, nil
	}
	if tier == "light" && m.has("llm:strong") {
		return "llm:strong", nil
	}
	return "", denied(want)
}

// AllowOutput checks an output.<kind> call against outputs.
func (m *Manifest) AllowOutput(kind string) (string, error) {
	if slices.Contains(m.outputs, kind) {
		return "output:" + kind, nil
	}
	return "", denied("output:" + kind)
}

// AllowCapability checks a non-tool capability call (agent:run, ask:owner,
// session:start[@kind]). An entry without a scope on an optional-scope
// capability covers every scope.
func (m *Manifest) AllowCapability(capability, verb, scope string) (string, error) {
	capability, verb = strings.ToLower(capability), strings.ToLower(verb)
	spec := capabilitySpecs[capability]
	for _, p := range m.entries {
		if p.Capability != capability || p.Verb != verb {
			continue
		}
		if spec.scope == scopeNone || (spec.scope == scopeOptional && p.Scope == "") || scopeMatches(p.Scope, scope) {
			return p.String(), nil
		}
	}
	return "", denied(Permission{Capability: capability, Verb: verb, Scope: scope}.String())
}

// AllowMCP checks a Quick Connection tool call: exact server name, tool name
// matched against the entry's glob. QC-02's allowed-list verdict is the
// caller's second check.
func (m *Manifest) AllowMCP(server, tool string) (string, error) {
	for _, p := range m.entries {
		if p.Capability != kindMCP || p.MCPServer != server {
			continue
		}
		if ok, err := path.Match(p.MCPGlob, tool); err == nil && ok {
			return p.String(), nil
		}
	}
	return "", denied("mcp:" + server + "/" + tool)
}

// AllowShell checks a shell() command: byte-exact equality with one entry.
func (m *Manifest) AllowShell(cmd string) (string, error) {
	for _, p := range m.entries {
		if p.Capability == kindShell && p.Shell == cmd {
			return p.String(), nil
		}
	}
	return "", denied("shell:" + quoteJSON(cmd))
}

// Covers returns the entries of next not covered by old (spec §3.3), in
// next's order, normalised and deduplicated; never nil. An entry of next that
// does not parse is reported verbatim; one of old that does not parse covers
// nothing.
func Covers(old, next []string) []string {
	var olds []Permission
	for _, e := range old {
		if p, err := ParsePermission(e); err == nil {
			olds = append(olds, p)
		}
	}
	out := []string{}
	for _, e := range next {
		p, err := ParsePermission(e)
		if err != nil {
			if !slices.Contains(out, e) {
				out = append(out, e)
			}
			continue
		}
		if !slices.ContainsFunc(olds, func(o Permission) bool { return permissionCovers(o, p) }) && !slices.Contains(out, p.String()) {
			out = append(out, p.String())
		}
	}
	return out
}

// permissionCovers reports whether entry o grants everything entry p grants.
func permissionCovers(o, p Permission) bool {
	if o.String() == p.String() {
		return true
	}
	switch {
	case o.Capability != p.Capability, o.Capability == kindTool, o.Capability == kindShell:
		// tool: and shell: entries cover only their exact twin (checked above).
		return false
	case o.Capability == kindMCP:
		return o.MCPServer == p.MCPServer && mcpGlobCovers(o.MCPGlob, p.MCPGlob)
	case o.Capability == "llm":
		return o.Verb == "strong"
	case o.Verb != p.Verb:
		return false
	case capabilitySpecs[o.Capability].scope == scopeOptional:
		return o.Scope == ""
	}
	return globCovers(o.Scope, p.Scope)
}

// mcpGlobCovers is globCovers for MCP tool globs, case-sensitive like
// AllowMCP.
func mcpGlobCovers(o, p string) bool {
	if o == "*" || o == p {
		return true
	}
	if strings.ContainsAny(p, `*?[\`) {
		return false
	}
	ok, err := path.Match(o, p)
	return err == nil && ok
}

// globCovers reports whether pattern o covers pattern p: "*" covers all, a
// literal p is covered by a matching glob, otherwise only equality.
func globCovers(o, p string) bool {
	if o == "*" || strings.EqualFold(o, p) {
		return true
	}
	if strings.ContainsAny(p, `*?[\`) {
		return false
	}
	return scopeMatches(o, p)
}
