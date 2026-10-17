package codex

import (
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"slices"
	"strings"

	toml "github.com/pelletier/go-toml/v2"

	"watchtower/internal/ai"
)

// OwnerHome is the owner's own codex home: CODEX_HOME, else ~/.codex.
func OwnerHome() string {
	if v := os.Getenv("CODEX_HOME"); v != "" {
		return v
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".codex")
}

// systemConfigPath is codex's system-wide config layer (a var for tests).
var systemConfigPath = "/etc/codex/config.toml"

// ownerServerNames are the MCP servers the owner's codex config layers
// declare — CODEX_HOME/config.toml, the system config and the run folder's
// .codex/config.toml (cwd; empty = none). A run that mounts its own servers
// disables each of them (mcpOverride): a `-c mcp_servers={…}` override is
// merged into the file layers, it does not replace them (codex 0.145,
// verified with a real run), so only `enabled = false` per server keeps
// them out. A file that cannot be parsed fails the run: codex would refuse
// it too, and a server it hides must not slip through.
func ownerServerNames(cwd string) ([]string, error) {
	paths := []string{filepath.Join(OwnerHome(), "config.toml"), systemConfigPath}
	if cwd != "" {
		paths = append(paths, filepath.Join(cwd, ".codex", "config.toml"))
	}
	var names []string
	for _, p := range paths {
		got, err := serverNamesIn(p)
		if err != nil {
			return nil, err
		}
		names = append(names, got...)
	}
	slices.Sort(names)
	return slices.Compact(names), nil
}

// serverNamesIn is the mcp_servers names one config layer declares; none
// when the file is missing or unreadable for permissions.
func serverNamesIn(path string) ([]string, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) || errors.Is(err, os.ErrPermission) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("reading codex config %s: %w", path, err)
	}
	var cfg struct {
		MCPServers map[string]any `toml:"mcp_servers"`
	}
	if err := toml.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("parsing codex config %s: %w", path, err)
	}
	names := make([]string, 0, len(cfg.MCPServers))
	for name := range cfg.MCPServers {
		names = append(names, name)
	}
	return names, nil
}

// mcpOverride is the one `-c mcp_servers={…}` value of a run, plus the
// environment its servers read secrets from. Every server of the owner's
// own config layers (owner) gets `enabled = false`; then the watchtower
// server (`<this binary> mcp --db-path <db> <extra…>`, env_vars = envVars:
// codex starts MCP servers with a filtered environment) when dbPath is set,
// and each Quick Connection limited to its QC-02 allowed tools by
// enabled_tools (codex runs with approvals off, so any other tool stays
// hidden rather than callable). A connection's secret never sits on argv
// (QC-03): stdio env values go into the child's environment and are named
// in env_vars; http headers go into WATCHTOWER_QC_* variables named in
// env_http_headers. A connection whose env would change a variable codex
// itself already has, or that another connection sets differently, is not
// mounted (logged). A connection named like an owner server is mounted as
// <name>-qc so the two never merge.
func mcpOverride(dbPath string, extra, envVars []string, external []ai.ExternalMCPServer, owner, baseEnv []string) (string, []string) {
	taken := map[string]bool{}
	var entries []string
	for _, name := range owner {
		taken[name] = true
		if dbPath != "" && name == "watchtower" {
			continue // ours replaces its command and args below
		}
		entries = append(entries, TOMLString(name)+"={enabled=false}")
	}
	if dbPath != "" {
		taken["watchtower"] = true
		entries = append(entries, watchtowerEntry(dbPath, extra, envVars))
	}
	ext, env := externalEntries(external, taken, envMap(baseEnv))
	return "mcp_servers={" + strings.Join(append(entries, ext...), ",") + "}", env
}

// watchtowerEntry is the watchtower server's table: `<this binary> mcp
// --db-path <db> <extra…>`, env_vars = envVars.
func watchtowerEntry(dbPath string, extra, envVars []string) string {
	args := append([]string{"mcp", "--db-path", dbPath}, extra...)
	fields := []string{"command=" + TOMLString(watchtowerBinary()), "args=" + TOMLStringArray(args)}
	if len(envVars) > 0 {
		fields = append(fields, "env_vars="+TOMLStringArray(envVars))
	}
	return `"watchtower"={` + strings.Join(fields, ",") + "}"
}

// externalEntries is one table per mountable Quick Connection (a key not in
// taken) and the environment carrying their secrets; set is the
// environment so far.
func externalEntries(external []ai.ExternalMCPServer, taken map[string]bool, set map[string]string) ([]string, []string) {
	var entries, env []string
	for _, s := range external {
		key := s.Name
		for taken[key] {
			key += "-qc"
		}
		fields, sEnv, ok := externalFields(s, key, set)
		if !ok {
			continue
		}
		taken[key] = true
		for _, kv := range sEnv {
			k, v, _ := strings.Cut(kv, "=")
			set[k] = v
		}
		env = append(env, sEnv...)
		entries = append(entries, TOMLString(key)+"={"+strings.Join(fields, ",")+"}")
	}
	return entries, env
}

// externalFields is one Quick Connection's table fields and the env its
// secret travels in; false when its env conflicts with set (see mcpOverride).
func externalFields(s ai.ExternalMCPServer, key string, set map[string]string) ([]string, []string, bool) {
	var fields, env []string
	if s.Kind == "http" {
		fields, env = httpFields(s, key), httpEnv(s, key)
	} else {
		var ok bool
		if fields, env, ok = stdioFields(s, set); !ok {
			return nil, nil, false
		}
	}
	allow := s.AllowTools
	if allow == nil {
		allow = []string{}
	}
	return append(fields, "enabled_tools="+TOMLStringArray(allow)), env, true
}

// httpHeaderVar is the variable that carries header i of connection key.
func httpHeaderVar(key string, i int) string {
	return fmt.Sprintf("WATCHTOWER_QC_%s_%d", strings.ToUpper(strings.ReplaceAll(key, "-", "_")), i)
}

// httpFields is an http connection's url and env_http_headers (header ->
// the variable httpEnv sets).
func httpFields(s ai.ExternalMCPServer, key string) []string {
	fields := []string{"url=" + TOMLString(s.URL)}
	var headers []string
	for i, h := range sortedKeys(s.Headers) {
		headers = append(headers, TOMLString(h)+"="+TOMLString(httpHeaderVar(key, i)))
	}
	if len(headers) > 0 {
		fields = append(fields, "env_http_headers={"+strings.Join(headers, ",")+"}")
	}
	return fields
}

// httpEnv is the environment carrying an http connection's header values.
func httpEnv(s ai.ExternalMCPServer, key string) []string {
	var env []string
	for i, h := range sortedKeys(s.Headers) {
		env = append(env, httpHeaderVar(key, i)+"="+s.Headers[h])
	}
	return env
}

// stdioFields is a stdio connection's command, args and env_vars, and the
// environment carrying its values; false when a value would change codex's
// own environment or one another connection set (set).
func stdioFields(s ai.ExternalMCPServer, set map[string]string) ([]string, []string, bool) {
	fields := []string{"command=" + TOMLString(s.Command), "args=" + TOMLStringArray(s.Args)}
	keys := sortedKeys(s.Env)
	var env []string
	for _, k := range keys {
		if envConflicts(k, s.Env[k], set) {
			log.Printf("quick connection %q: not mounted under codex: its variable %s would change codex's own environment", s.Name, k)
			return nil, nil, false
		}
		env = append(env, k+"="+s.Env[k])
	}
	if len(keys) > 0 {
		fields = append(fields, "env_vars="+TOMLStringArray(keys))
	}
	return fields, env, true
}

func envConflicts(k, v string, set map[string]string) bool {
	if strings.HasPrefix(k, "CODEX_") || strings.HasPrefix(k, "OPENAI_") {
		return true
	}
	old, ok := set[k]
	return ok && old != v
}

func envMap(env []string) map[string]string {
	m := make(map[string]string, len(env))
	for _, kv := range env {
		if k, v, ok := strings.Cut(kv, "="); ok {
			m[k] = v
		}
	}
	return m
}

func sortedKeys(m map[string]string) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	slices.Sort(keys)
	return keys
}

// TOMLString is s as a TOML basic string. strconv.Quote is not one: Go's
// \x and \a escapes are not TOML, so control characters become \uXXXX
// (invalid UTF-8 reads as U+FFFD).
func TOMLString(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for _, r := range s {
		switch {
		case r == '"' || r == '\\':
			b.WriteByte('\\')
			b.WriteRune(r)
		case r < 0x20 || r == 0x7f:
			fmt.Fprintf(&b, `\u%04X`, r)
		default:
			b.WriteRune(r)
		}
	}
	b.WriteByte('"')
	return b.String()
}

// TOMLStringArray is ss as a TOML array of basic strings.
func TOMLStringArray(ss []string) string {
	quoted := make([]string, 0, len(ss))
	for _, s := range ss {
		quoted = append(quoted, TOMLString(s))
	}
	return "[" + strings.Join(quoted, ",") + "]"
}

// watchtowerBinary is the path used to relaunch this binary as an MCP server.
// In the desktop flow the running process IS the watchtower CLI (`ai query`),
// so os.Executable() is the correct self-path; fall back to a bare "watchtower"
// on the caller's PATH if it cannot be determined.
func watchtowerBinary() string {
	if exe, err := os.Executable(); err == nil && exe != "" {
		return exe
	}
	return "watchtower"
}
