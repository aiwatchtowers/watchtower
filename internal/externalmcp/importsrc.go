package externalmcp

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"regexp"
	"slices"
	"strconv"
	"strings"

	toml "github.com/pelletier/go-toml/v2"
)

// ImportCandidate is one MCP server the owner configured for their own codex
// (~/.codex/config.toml) or Claude Code (~/.claude.json), offered for import
// as a Quick Connection (`connections import`, board #594). Skip says why it
// cannot be imported ("" = it can); Note says why its name differs from the
// source's. Enabled is false for a server the source config turned off: it
// is imported disabled. Secret carries its env vars (stdio) or headers
// (http), resolved from the environment where the source names a variable;
// it never leaves this process except into the connection's 0600 secret
// file.
type ImportCandidate struct {
	Name      string   `json:"name"`
	Source    string   `json:"source"` // "codex" | "claude"
	Kind      string   `json:"kind"`   // "stdio" | "http" (or the unsupported transport)
	Command   string   `json:"command,omitempty"`
	Args      []string `json:"args,omitempty"`
	URL       string   `json:"url,omitempty"`
	Enabled   bool     `json:"enabled"`
	HasSecret bool     `json:"has_secret"`
	Skip      string   `json:"skip,omitempty"`
	Note      string   `json:"note,omitempty"`
	Secret    *Secret  `json:"-"`
}

// importNameUnsafe matches what a Quick Connection name may not hold (the
// cmd layer's connectionNamePattern is [A-Za-z0-9_-]+).
var importNameUnsafe = regexp.MustCompile(`[^A-Za-z0-9_-]+`)

// DiscoverImports reads the MCP servers of the owner's codex config
// (codexConfig, a config.toml) and Claude Code config (claudeConfig, a
// .claude.json — its user-scope mcpServers), codex first, each sorted by
// name. A missing file adds nothing; an unreadable one adds a warning and
// the other source still counts; one server that cannot be read is listed
// with a skip reason, the rest still count. Names are made
// Quick-Connection-safe and unique: a Claude server that is the same server
// as a codex one of that name is dropped, any other clash gets -2, -3, …
// with a note. getenv resolves the variables a source names.
func DiscoverImports(codexConfig, claudeConfig string, getenv func(string) string) ([]ImportCandidate, []string) {
	var all []ImportCandidate
	var warnings []string
	for _, read := range []func() ([]ImportCandidate, error){
		func() ([]ImportCandidate, error) { return readCodexServers(codexConfig, getenv) },
		func() ([]ImportCandidate, error) { return readClaudeServers(claudeConfig, getenv) },
	} {
		got, err := read()
		if err != nil {
			warnings = append(warnings, err.Error())
		}
		all = append(all, got...)
	}
	return uniqueNames(all), warnings
}

// uniqueNames drops a Claude duplicate of a codex server and renames every
// other name clash deterministically (input order wins).
func uniqueNames(cands []ImportCandidate) []ImportCandidate {
	out := make([]ImportCandidate, 0, len(cands))
	taken := func(name string) int {
		return slices.IndexFunc(out, func(o ImportCandidate) bool { return strings.EqualFold(o.Name, name) })
	}
	for _, c := range cands {
		i := taken(c.Name)
		if i < 0 {
			out = append(out, c)
			continue
		}
		if out[i].Source != c.Source && sameServer(out[i], c) {
			continue
		}
		base := c.Name
		for n := 2; taken(c.Name) >= 0; n++ {
			c.Name = base + "-" + strconv.Itoa(n)
		}
		c.Note = joinNote(c.Note, fmt.Sprintf("named %s: %s is taken by another server", c.Name, base))
		out = append(out, c)
	}
	return out
}

func joinNote(a, b string) string {
	if a == "" {
		return b
	}
	return a + "; " + b
}

func sameServer(a, b ImportCandidate) bool {
	return a.Kind == b.Kind && a.Command == b.Command && a.URL == b.URL && slices.Equal(a.Args, b.Args)
}

// codexServer is one [mcp_servers.<name>] table of codex's config.toml.
// EnvVars entries are a name or a {name, source} table.
type codexServer struct {
	Command           string            `toml:"command"`
	Args              []string          `toml:"args"`
	Env               map[string]string `toml:"env"`
	EnvVars           []any             `toml:"env_vars"`
	Cwd               string            `toml:"cwd"`
	URL               string            `toml:"url"`
	BearerTokenEnvVar string            `toml:"bearer_token_env_var"`
	HTTPHeaders       map[string]string `toml:"http_headers"`
	EnvHTTPHeaders    map[string]string `toml:"env_http_headers"`
	Enabled           *bool             `toml:"enabled"`
}

func readCodexServers(path string, getenv func(string) string) ([]ImportCandidate, error) {
	data, err := readSource(path)
	if data == nil {
		return nil, err
	}
	var cfg struct {
		MCPServers map[string]any `toml:"mcp_servers"`
	}
	if err := toml.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("parsing %s: %w", path, err)
	}
	var out []ImportCandidate
	for _, name := range sortedKeys(cfg.MCPServers) {
		var s codexServer
		c := ImportCandidate{Name: name, Source: "codex", Enabled: true, Secret: &Secret{}}
		if err := redecodeTOML(cfg.MCPServers[name], &s); err != nil {
			c.Skip = "its settings could not be read: " + err.Error()
		} else {
			c = codexCandidate(c, s, getenv)
		}
		out = append(out, finish(c))
	}
	return out, nil
}

// redecodeTOML decodes one generic TOML value into dst, so a single odd
// server fails alone.
func redecodeTOML(v any, dst any) error {
	b, err := toml.Marshal(v)
	if err != nil {
		return err
	}
	return toml.Unmarshal(b, dst)
}

func codexCandidate(c ImportCandidate, s codexServer, getenv func(string) string) ImportCandidate {
	c.Command, c.Args, c.URL = s.Command, s.Args, s.URL
	if s.Enabled != nil {
		c.Enabled = *s.Enabled
	}
	switch {
	case s.URL != "":
		return codexHTTP(c, s, getenv)
	case s.Command != "":
		return codexStdio(c, s, getenv)
	}
	c.Skip = "it has neither a command nor a url"
	return c
}

// codexHTTP is an http server's headers: http_headers, the bearer token and
// env_http_headers read from the environment.
func codexHTTP(c ImportCandidate, s codexServer, getenv func(string) string) ImportCandidate {
	c.Kind = "http"
	c.Secret.Headers = copyMap(s.HTTPHeaders)
	if s.BearerTokenEnvVar != "" {
		c.Secret.Headers = setKey(c.Secret.Headers, "Authorization", "Bearer "+getenv(s.BearerTokenEnvVar))
		c.Skip = needVar(c.Skip, s.BearerTokenEnvVar, getenv)
	}
	for _, h := range sortedKeys(s.EnvHTTPHeaders) {
		v := s.EnvHTTPHeaders[h]
		c.Secret.Headers = setKey(c.Secret.Headers, h, getenv(v))
		c.Skip = needVar(c.Skip, v, getenv)
	}
	return c
}

// codexStdio is a stdio server's env: env plus env_vars read from the
// environment.
func codexStdio(c ImportCandidate, s codexServer, getenv func(string) string) ImportCandidate {
	c.Kind = "stdio"
	c.Secret.Env = copyMap(s.Env)
	for _, e := range s.EnvVars {
		name := envVarName(e)
		if name == "" {
			c.Skip = joinNote(c.Skip, "an env_vars entry has no name")
			continue
		}
		c.Secret.Env = setKey(c.Secret.Env, name, getenv(name))
		c.Skip = needVar(c.Skip, name, getenv)
	}
	if s.Cwd != "" && c.Skip == "" {
		c.Skip = "it runs in a set working folder (cwd), which Quick Connections do not support"
	}
	return c
}

// envVarName is a codex env_vars entry's variable: the string itself, or a
// {name, source} table's name.
func envVarName(e any) string {
	switch v := e.(type) {
	case string:
		return v
	case map[string]any:
		name, _ := v["name"].(string)
		return name
	}
	return ""
}

// claudeServer is one entry of .claude.json's mcpServers.
type claudeServer struct {
	Type    string            `json:"type"`
	Command string            `json:"command"`
	Args    []string          `json:"args"`
	Env     map[string]string `json:"env"`
	URL     string            `json:"url"`
	Headers map[string]string `json:"headers"`
}

func readClaudeServers(path string, getenv func(string) string) ([]ImportCandidate, error) {
	data, err := readSource(path)
	if data == nil {
		return nil, err
	}
	var cfg struct {
		MCPServers map[string]json.RawMessage `json:"mcpServers"`
	}
	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("parsing %s: %w", path, err)
	}
	var out []ImportCandidate
	for _, name := range sortedKeys(cfg.MCPServers) {
		var s claudeServer
		c := ImportCandidate{Name: name, Source: "claude", Enabled: true, Secret: &Secret{}}
		if err := json.Unmarshal(cfg.MCPServers[name], &s); err != nil {
			c.Skip = "its settings could not be read: " + err.Error()
		} else {
			c = claudeCandidate(c, s, getenv)
		}
		out = append(out, finish(c))
	}
	return out, nil
}

func claudeCandidate(c ImportCandidate, s claudeServer, getenv func(string) string) ImportCandidate {
	x := expander{getenv: getenv}
	switch s.Type {
	case "", "stdio":
		c.Kind = "stdio"
		c.Command = x.expand(s.Command)
		for _, a := range s.Args {
			c.Args = append(c.Args, x.expand(a))
		}
		c.Secret.Env = x.expandMap(s.Env)
		if c.Command == "" {
			c.Skip = "it has no command"
		}
	case "http":
		c.Kind = "http"
		c.URL = x.expand(s.URL)
		c.Secret.Headers = x.expandMap(s.Headers)
	default:
		c.Kind = s.Type
		c.Skip = fmt.Sprintf("its %s transport is not supported (only stdio and http)", s.Type)
	}
	if c.Skip == "" && x.missing != "" {
		c.Skip = fmt.Sprintf("it needs $%s, which is not set", x.missing)
	}
	return c
}

// readSource is a source file's content; nil with no error when it does
// not exist.
func readSource(path string) ([]byte, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("reading %s: %w", path, err)
	}
	return data, nil
}

// finish makes c's name Quick-Connection-safe (noting a change), drops an
// empty secret, and never offers Watchtower's own server.
func finish(c ImportCandidate) ImportCandidate {
	if safe := strings.Trim(importNameUnsafe.ReplaceAllString(c.Name, "-"), "-"); safe != c.Name {
		c.Note = fmt.Sprintf("renamed from %q: names hold only letters, digits, - and _", c.Name)
		c.Name = safe
	}
	if len(c.Secret.Env) == 0 {
		c.Secret.Env = nil
	}
	if len(c.Secret.Headers) == 0 {
		c.Secret.Headers = nil
	}
	c.HasSecret = c.Secret.Env != nil || c.Secret.Headers != nil
	if !c.HasSecret {
		c.Secret = nil
	}
	if c.Skip == "" && strings.HasPrefix(strings.ToLower(c.Name), "watchtower") {
		c.Skip = "it is Watchtower's own server"
	}
	return c
}

// needVar records the first variable a server needs that getenv lacks.
func needVar(skip, name string, getenv func(string) string) string {
	if skip != "" || getenv(name) != "" {
		return skip
	}
	return fmt.Sprintf("it needs $%s, which is not set", name)
}

// claudeVar is Claude Code's ${VAR} / ${VAR:-default} expansion.
var claudeVar = regexp.MustCompile(`\$\{([A-Za-z_][A-Za-z0-9_]*)(:-([^}]*))?\}`)

type expander struct {
	getenv  func(string) string
	missing string // the first variable with no value and no default
}

func (x *expander) expand(s string) string {
	return claudeVar.ReplaceAllStringFunc(s, func(m string) string {
		g := claudeVar.FindStringSubmatch(m)
		if v := x.getenv(g[1]); v != "" {
			return v
		}
		if g[2] != "" {
			return g[3]
		}
		if x.missing == "" {
			x.missing = g[1]
		}
		return ""
	})
}

func (x *expander) expandMap(m map[string]string) map[string]string {
	if len(m) == 0 {
		return nil
	}
	out := make(map[string]string, len(m))
	for k, v := range m {
		out[k] = x.expand(v)
	}
	return out
}

func copyMap(m map[string]string) map[string]string {
	if len(m) == 0 {
		return nil
	}
	out := make(map[string]string, len(m))
	for k, v := range m {
		out[k] = v
	}
	return out
}

func setKey(m map[string]string, k, v string) map[string]string {
	if m == nil {
		m = map[string]string{}
	}
	m[k] = v
	return m
}

func sortedKeys[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	slices.Sort(keys)
	return keys
}
