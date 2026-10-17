package externalmcp

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"regexp"
	"slices"
	"strings"

	toml "github.com/pelletier/go-toml/v2"

	"watchtower/internal/netsec"
)

// ImportCandidate is one MCP server the owner configured for their own codex
// (~/.codex/config.toml) or Claude Code (~/.claude.json), offered for import
// as a Quick Connection (`connections import`, board #594). Skip says why it
// cannot be imported ("" = it can). Secret carries its env vars (stdio) or
// headers (http), resolved from the environment where the source names a
// variable; it never leaves this process except into the connection's 0600
// secret file.
type ImportCandidate struct {
	Name      string   `json:"name"`
	Source    string   `json:"source"` // "codex" | "claude"
	Kind      string   `json:"kind"`   // "stdio" | "http"
	Command   string   `json:"command,omitempty"`
	Args      []string `json:"args,omitempty"`
	URL       string   `json:"url,omitempty"`
	HasSecret bool     `json:"has_secret"`
	Skip      string   `json:"skip,omitempty"`
	Secret    *Secret  `json:"-"`
}

// importNameUnsafe matches what a Quick Connection name may not hold (the
// cmd layer's connectionNamePattern is [A-Za-z0-9_-]+).
var importNameUnsafe = regexp.MustCompile(`[^A-Za-z0-9_-]+`)

// DiscoverImports reads the MCP servers of the owner's codex config
// (codexConfig, a config.toml) and Claude Code config (claudeConfig, a
// .claude.json — its user-scope mcpServers), codex first. A missing file
// adds nothing; an unreadable one adds a warning and the other source still
// counts. Names are made Quick-Connection-safe; a Claude server with the
// same name as a codex one is dropped when it is the same server, else
// renamed <name>-claude. getenv resolves the variables a source names.
func DiscoverImports(codexConfig, claudeConfig string, getenv func(string) string) ([]ImportCandidate, []string) {
	var out []ImportCandidate
	var warnings []string
	codex, err := readCodexServers(codexConfig, getenv)
	if err != nil {
		warnings = append(warnings, err.Error())
	}
	out = append(out, codex...)
	claude, err := readClaudeServers(claudeConfig, getenv)
	if err != nil {
		warnings = append(warnings, err.Error())
	}
	for _, c := range claude {
		i := slices.IndexFunc(out, func(o ImportCandidate) bool { return strings.EqualFold(o.Name, c.Name) })
		if i >= 0 {
			if sameServer(out[i], c) {
				continue
			}
			c.Name += "-claude"
			if slices.ContainsFunc(out, func(o ImportCandidate) bool { return strings.EqualFold(o.Name, c.Name) }) {
				continue
			}
		}
		out = append(out, c)
	}
	return out, warnings
}

func sameServer(a, b ImportCandidate) bool {
	return a.Kind == b.Kind && a.Command == b.Command && a.URL == b.URL && slices.Equal(a.Args, b.Args)
}

// codexServer is one [mcp_servers.<name>] table of codex's config.toml.
type codexServer struct {
	Command           string            `toml:"command"`
	Args              []string          `toml:"args"`
	Env               map[string]string `toml:"env"`
	EnvVars           []string          `toml:"env_vars"`
	Cwd               string            `toml:"cwd"`
	URL               string            `toml:"url"`
	BearerTokenEnvVar string            `toml:"bearer_token_env_var"`
	HTTPHeaders       map[string]string `toml:"http_headers"`
	EnvHTTPHeaders    map[string]string `toml:"env_http_headers"`
}

func readCodexServers(path string, getenv func(string) string) ([]ImportCandidate, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("reading %s: %w", path, err)
	}
	var cfg struct {
		MCPServers map[string]codexServer `toml:"mcp_servers"`
	}
	if err := toml.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("parsing %s: %w", path, err)
	}
	var out []ImportCandidate
	for _, name := range sortedKeys(cfg.MCPServers) {
		s := cfg.MCPServers[name]
		c := ImportCandidate{Name: name, Source: "codex", Command: s.Command, Args: s.Args, URL: s.URL, Secret: &Secret{}}
		switch {
		case s.URL != "":
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
		case s.Command != "":
			c.Kind = "stdio"
			c.Secret.Env = copyMap(s.Env)
			for _, v := range s.EnvVars {
				c.Secret.Env = setKey(c.Secret.Env, v, getenv(v))
				c.Skip = needVar(c.Skip, v, getenv)
			}
			if s.Cwd != "" && c.Skip == "" {
				c.Skip = "it runs in a set working folder (cwd), which Quick Connections do not support"
			}
		default:
			c.Skip = "it has neither a command nor a url"
		}
		out = append(out, finish(c))
	}
	return out, nil
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
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("reading %s: %w", path, err)
	}
	var cfg struct {
		MCPServers map[string]claudeServer `json:"mcpServers"`
	}
	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("parsing %s: %w", path, err)
	}
	var out []ImportCandidate
	for _, name := range sortedKeys(cfg.MCPServers) {
		s := cfg.MCPServers[name]
		x := expander{getenv: getenv}
		c := ImportCandidate{Name: name, Source: "claude", Secret: &Secret{}}
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
		out = append(out, finish(c))
	}
	return out, nil
}

// finish makes c's name Quick-Connection-safe and applies the checks every
// source shares: Watchtower's own server is never imported, and headers
// never go to a remote host over plain http (netsec, as `connections add`).
func finish(c ImportCandidate) ImportCandidate {
	c.Name = strings.Trim(importNameUnsafe.ReplaceAllString(c.Name, "-"), "-")
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
	if c.Skip != "" {
		return c
	}
	switch {
	case c.Name == "":
		c.Skip = "its name has no letters or digits"
	case strings.HasPrefix(strings.ToLower(c.Name), "watchtower"):
		c.Skip = "it is Watchtower's own server"
	case c.Kind == "http" && c.HasSecret:
		if err := netsec.RequireSecureURL(c.URL, "a connection with headers"); err != nil {
			c.Skip = err.Error()
		}
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
