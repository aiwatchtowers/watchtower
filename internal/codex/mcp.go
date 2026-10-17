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
	return codexHomeIn(os.Getenv("CODEX_HOME"))
}

// codexHomeIn is the codex home for a CODEX_HOME value ("" = ~/.codex).
func codexHomeIn(v string) string {
	if v != "" {
		return v
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".codex")
}

// systemConfigDir holds codex's system-wide layers, config.toml and
// managed_config.toml (SetSystemConfigDir for tests).
var systemConfigDir = "/etc/codex"

// SetSystemConfigDir points the system config layers at dir: tests keep
// the machine's own /etc/codex out of their runs.
func SetSystemConfigDir(dir string) { systemConfigDir = dir }

// codexLayer is what a codex config layer says that matters here.
type codexLayer struct {
	MCPServers         map[string]any `toml:"mcp_servers"`
	ProjectRootMarkers []string       `toml:"project_root_markers"`
}

// ownerServerNames are the MCP servers the codex config layers a run loads
// declare: home/config.toml (home = the child's CODEX_HOME), the system
// config.toml and managed_config.toml, and every .codex/config.toml from
// the project root (the nearest ancestor of cwd holding one of
// project_root_markers, default .git; cwd itself when none does) down to
// cwd. A run that mounts its own servers disables each of them
// (mcpOverride): a `-c mcp_servers={…}` override is merged into the file
// layers, it does not replace them (codex 0.145, verified with a real run),
// so only `enabled = false` per server keeps them out. A file that cannot
// be parsed fails the run: codex would refuse it too, and a server it
// hides must not slip through.
func ownerServerNames(home, cwd string) ([]string, error) {
	var names []string
	markers := []string{".git"}
	for _, p := range []string{
		filepath.Join(home, "config.toml"),
		filepath.Join(systemConfigDir, "config.toml"),
		filepath.Join(systemConfigDir, "managed_config.toml"),
	} {
		layer, err := readLayer(p)
		if err != nil {
			return nil, err
		}
		names = append(names, sortedKeys(layer.MCPServers)...)
		if layer.ProjectRootMarkers != nil {
			markers = layer.ProjectRootMarkers
		}
	}
	for _, dir := range projectDirs(cwd, markers) {
		layer, err := readLayer(filepath.Join(dir, ".codex", "config.toml"))
		if err != nil {
			return nil, err
		}
		names = append(names, sortedKeys(layer.MCPServers)...)
	}
	slices.Sort(names)
	return slices.Compact(names), nil
}

// projectDirs are cwd and its ancestors up to the project root: the
// nearest one holding a marker; only cwd when none does.
func projectDirs(cwd string, markers []string) []string {
	if cwd == "" {
		return nil
	}
	var dirs []string
	for dir := filepath.Clean(cwd); ; dir = filepath.Dir(dir) {
		dirs = append(dirs, dir)
		if hasMarker(dir, markers) {
			return dirs
		}
		if filepath.Dir(dir) == dir {
			return []string{filepath.Clean(cwd)}
		}
	}
}

func hasMarker(dir string, markers []string) bool {
	for _, m := range markers {
		if _, err := os.Lstat(filepath.Join(dir, m)); err == nil {
			return true
		}
	}
	return false
}

// readLayer is one config layer; empty when the file is missing or
// unreadable for permissions.
func readLayer(path string) (codexLayer, error) {
	var layer codexLayer
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) || errors.Is(err, os.ErrPermission) {
		return layer, nil
	}
	if err != nil {
		return layer, fmt.Errorf("reading codex config %s: %w", path, err)
	}
	if err := toml.Unmarshal(data, &layer); err != nil {
		return layer, fmt.Errorf("parsing codex config %s: %w", path, err)
	}
	return layer, nil
}

// WatchtowerServerTOML is the config.toml table that mounts this binary as
// codex's watchtower MCP server: `watchtower mcp --db-path <db> <extra…>`.
// envVars, when given, become the server's env_vars: codex starts MCP
// servers with a filtered environment, so a variable the server needs (an
// automation's run marker) must be named to reach it. The automation
// agent() child's own CODEX_HOME declares it (cmd's codexAgentHome).
func WatchtowerServerTOML(dbPath string, extra, envVars []string) string {
	args := append([]string{"mcp", "--db-path", dbPath}, extra...)
	s := fmt.Sprintf("[mcp_servers.watchtower]\ncommand = %s\nargs = [%s]\n", TOMLString(watchtowerBinary()), quotedList(args))
	if len(envVars) > 0 {
		s += fmt.Sprintf("env_vars = [%s]\n", quotedList(envVars))
	}
	return s
}

// quotedList is items as the inside of a TOML string array.
func quotedList(items []string) string {
	quoted := make([]string, 0, len(items))
	for _, a := range items {
		quoted = append(quoted, TOMLString(a))
	}
	return strings.Join(quoted, ", ")
}

// mcpOverride is the one `-c mcp_servers={…}` value of a run, plus the
// environment its servers read secrets from and the connections it could
// not mount (id → reason). Every server of the owner's own config layers
// (owner) gets `enabled = false`; then the watchtower server (`<this
// binary> mcp --db-path <db> <extra…>`, env_vars = envVars: codex starts
// MCP servers with a filtered environment) when dbPath is set — under a key
// no owner layer uses, so nothing of theirs merges into it —, and each
// Quick Connection limited to its QC-02 allowed tools by enabled_tools
// (codex runs with approvals off, so any other tool stays hidden rather
// than callable). A connection's secret never sits on argv (QC-03): stdio
// env values go into the child's environment and are named in env_vars;
// http headers go into WATCHTOWER_QC_<id>_<i> variables named in
// env_http_headers. A connection whose env would change a variable codex
// itself has, or that another connection sets differently, is not mounted.
// A connection named like an owner server is mounted as <name>-qc.
func mcpOverride(dbPath string, extra, envVars []string, external []ai.ExternalMCPServer, owner, baseEnv []string) (string, []string, map[int64]string) {
	taken := map[string]bool{}
	var entries []string
	for _, name := range owner {
		taken[name] = true
		entries = append(entries, TOMLString(name)+"={enabled=false}")
	}
	if dbPath != "" {
		key := freeKey("watchtower", "-app", taken)
		taken[key] = true
		entries = append(entries, watchtowerEntry(key, dbPath, extra, envVars))
	}
	ext, env, skipped := externalEntries(external, taken, envMap(baseEnv))
	return "mcp_servers={" + strings.Join(append(entries, ext...), ",") + "}", env, skipped
}

// EnvConflicts are the Quick Connections a codex launch with baseEnv could
// not mount (id → reason): the same check mcpOverride applies, so the
// caller can skip them before touching their credentials or tools and show
// why on the connection's row.
func EnvConflicts(external []ai.ExternalMCPServer, baseEnv []string) map[int64]string {
	_, _, skipped := externalEntries(external, map[string]bool{}, envMap(baseEnv))
	return skipped
}

func freeKey(key, suffix string, taken map[string]bool) string {
	for taken[key] {
		key += suffix
	}
	return key
}

// watchtowerEntry is the watchtower server's table: `<this binary> mcp
// --db-path <db> <extra…>`, env_vars = envVars, enabled.
func watchtowerEntry(key, dbPath string, extra, envVars []string) string {
	args := append([]string{"mcp", "--db-path", dbPath}, extra...)
	fields := []string{"command=" + TOMLString(watchtowerBinary()), "args=" + TOMLStringArray(args), "enabled=true"}
	if len(envVars) > 0 {
		fields = append(fields, "env_vars="+TOMLStringArray(envVars))
	}
	return TOMLString(key) + "={" + strings.Join(fields, ",") + "}"
}

// externalEntries is one table per mountable Quick Connection (a key not in
// taken), the environment carrying their secrets, and the ones skipped for
// an env conflict (id → reason); set is the environment so far.
func externalEntries(external []ai.ExternalMCPServer, taken map[string]bool, set map[string]string) ([]string, []string, map[int64]string) {
	var entries, env []string
	skipped := map[int64]string{}
	for _, s := range external {
		key := freeKey(s.Name, "-qc", taken)
		fields, sEnv, reason := externalFields(s, set)
		if reason != "" {
			log.Printf("quick connection %q: not mounted under codex: %s", s.Name, reason)
			skipped[s.ID] = reason
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
	return entries, env, skipped
}

// externalFields is one Quick Connection's table fields and the env its
// secret travels in; a reason when that env conflicts with set.
func externalFields(s ai.ExternalMCPServer, set map[string]string) ([]string, []string, string) {
	var fields, env []string
	if s.Kind == "http" {
		fields, env = httpFields(s), httpEnv(s)
	} else {
		fields, env = stdioFields(s), stdioEnv(s)
	}
	for _, kv := range env {
		k, v, _ := strings.Cut(kv, "=")
		if envConflicts(k, v, set) {
			return nil, nil, fmt.Sprintf("its variable %s would change one codex itself uses", k)
		}
	}
	allow := s.AllowTools
	if allow == nil {
		allow = []string{}
	}
	return append(fields, "enabled_tools="+TOMLStringArray(allow)), env, ""
}

// httpHeaderVar is the variable that carries header i of connection id.
func httpHeaderVar(id int64, i int) string {
	return fmt.Sprintf("WATCHTOWER_QC_%d_%d", id, i)
}

// httpFields is an http connection's url and env_http_headers (header ->
// the variable httpEnv sets).
func httpFields(s ai.ExternalMCPServer) []string {
	fields := []string{"url=" + TOMLString(s.URL)}
	var headers []string
	for i, h := range sortedKeys(s.Headers) {
		headers = append(headers, TOMLString(h)+"="+TOMLString(httpHeaderVar(s.ID, i)))
	}
	if len(headers) > 0 {
		fields = append(fields, "env_http_headers={"+strings.Join(headers, ",")+"}")
	}
	return fields
}

// httpEnv is the environment carrying an http connection's header values.
func httpEnv(s ai.ExternalMCPServer) []string {
	var env []string
	for i, h := range sortedKeys(s.Headers) {
		env = append(env, httpHeaderVar(s.ID, i)+"="+s.Headers[h])
	}
	return env
}

// stdioFields is a stdio connection's command, args and env_vars (the
// names of the variables stdioEnv sets).
func stdioFields(s ai.ExternalMCPServer) []string {
	fields := []string{"command=" + TOMLString(s.Command), "args=" + TOMLStringArray(s.Args)}
	if keys := sortedKeys(s.Env); len(keys) > 0 {
		fields = append(fields, "env_vars="+TOMLStringArray(keys))
	}
	return fields
}

// stdioEnv is the environment carrying a stdio connection's env values.
func stdioEnv(s ai.ExternalMCPServer) []string {
	var env []string
	for _, k := range sortedKeys(s.Env) {
		env = append(env, k+"="+s.Env[k])
	}
	return env
}

// codexOwnVars are variables the codex process itself reads (its network,
// TLS, runtime, loader, locations and its own settings); codexOwnPrefixes
// the families of them. A Quick Connection's env lands in codex's own
// environment (env_vars passes it on), so one that sets any of these would
// reconfigure codex and is not mounted. Compared upper-cased.
var (
	codexOwnVars = []string{
		"PATH", "HOME", "TMPDIR", "SHELL", "USER", "LOGNAME", "LANG", "TERM",
		"HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "NO_PROXY",
		"SSL_CERT_FILE", "SSL_CERT_DIR", "CURL_CA_BUNDLE", "REQUESTS_CA_BUNDLE",
	}
	codexOwnPrefixes = []string{"CODEX_", "OPENAI_", "RUST_", "NODE_", "DYLD_", "LD_", "XDG_", "LC_"}
)

// envConflicts: k would reconfigure codex itself (codexOwnVars), or it
// already holds a different value in set.
func envConflicts(k, v string, set map[string]string) bool {
	upper := strings.ToUpper(k)
	if slices.Contains(codexOwnVars, upper) || slices.ContainsFunc(codexOwnPrefixes, func(p string) bool { return strings.HasPrefix(upper, p) }) {
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

func sortedKeys[V any](m map[string]V) []string {
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
