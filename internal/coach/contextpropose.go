package coach

import (
	"cmp"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"
	"unicode/utf8"

	"watchtower/internal/agentfiles"
	"watchtower/internal/agentlogdb"
	"watchtower/internal/agentreport"
	"watchtower/internal/db"
)

// The mechanical context proposer (spec 2026-11-12 part 2): no model call. It
// reads the Context facts and a names-only read of the owner's Claude Code
// config and files coach proposals of origin context, judged on start_tokens.
// Global destinations (a plugin, a user-scope MCP server, the claude.ai
// connectors) are decided on the calls of every workbench with analytics on
// (D3/C9) and stored without a workbench; the CLAUDE.md and memory index
// proposals are per workbench. It never files a protected source
// (IsProtected) and never files from fewer than judgeMinSessions measured
// sessions. Logs carry labels, names and counts, never a path or a value.

// Seams tests replace with fake facts.
var (
	// contextGlobalSources is the install-wide start-context sources (rules
	// 1–3), read once per pass.
	contextGlobalSources = agentreport.GlobalSources
	// contextMeasuredSessions is one workbench's measured sessions in the
	// window (rules 4–5): a light count, not a whole report.
	contextMeasuredSessions = agentreport.MeasuredSessions
)

// errContextNotRegular refuses a CLAUDE.md or memory index that is a symlink
// or a special file.
var errContextNotRegular = errors.New("the file is a symlink or not a regular file")

// ContextEnv is what the context proposer reads: both databases (only read,
// apart from the proposals it files), the home ~/.claude lives in, the clock
// and the owner's language for titles and reasons. Logger nil is
// log.Default().
type ContextEnv struct {
	DB       *db.DB
	AgentLog *agentlogdb.DB
	Home     string
	Now      func() time.Time
	Lang     agentreport.Lang
	Logger   *log.Logger
}

func (e ContextEnv) logf(format string, args ...any) {
	l := e.Logger
	if l == nil {
		l = log.Default()
	}
	l.Printf(format, args...)
}

func (e ContextEnv) now() time.Time {
	if e.Now == nil {
		return time.Now()
	}
	return e.Now()
}

// ProposeContext is one pass of the context proposer over the workbenches
// with agent analytics on (workbenchIDs): it files what PreviewContext finds
// and counts the new rows. A workbench's error does not stop the others: the
// proposals found are filed and the errors are returned joined. A cancelled
// ctx files nothing.
func ProposeContext(ctx context.Context, env ContextEnv, workbenchIDs []int64) (written int, err error) {
	props, err := PreviewContext(ctx, env, workbenchIDs)
	if ctx.Err() != nil {
		return 0, ctx.Err()
	}
	now := env.now()
	for _, p := range props {
		id, ierr := env.DB.InsertContextCoachProposal(p, now)
		if errors.Is(ierr, db.ErrCoachTextBusy) { // filed by a parallel run since the preview
			continue
		}
		if ierr != nil {
			return written, errors.Join(err, ierr)
		}
		if id != 0 {
			written++
		}
	}
	return written, err
}

// PreviewContext is ProposeContext without the writes (`coach run
// --dry-run`): the proposals whose fingerprint is new and whose text key has
// no open proposal. Rules 1–3 read GlobalSources over the last ctxWindowDays
// once per pass; rules 4–5 read each workbench's folder and memory index when
// the workbench has judgeMinSessions measured sessions in that window. ctx is
// checked between workbenches.
func PreviewContext(ctx context.Context, env ContextEnv, workbenchIDs []int64) ([]db.CoachProposal, error) {
	if len(workbenchIDs) == 0 {
		return nil, nil
	}
	now := env.now()
	since := now.Add(-ctxWindowDays * 24 * time.Hour)
	global, err := contextGlobalSources(env.DB, env.AgentLog, since, now)
	if err != nil {
		return nil, err
	}
	props := globalContextProposals(env, foldPluginServers(sourceGroups(global)))
	var errs []error
	for _, id := range workbenchIDs {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		ps, err := workbenchContextProposals(env, id, since, now)
		if err != nil {
			errs = append(errs, fmt.Errorf("workbench %d: %w", id, err))
			continue
		}
		props = append(props, ps...)
	}
	out, err := newContextProposals(env.DB, props)
	if err != nil {
		return nil, err
	}
	return out, errors.Join(errs...)
}

// workbenchContextProposals is rules 4–5 for one workbench.
func workbenchContextProposals(env ContextEnv, id int64, since, now time.Time) ([]db.CoachProposal, error) {
	wb, err := env.DB.GetWorkbench(id)
	if err != nil {
		return nil, err
	}
	measured, err := contextMeasuredSessions(env.AgentLog, id, since, now)
	if err != nil || measured < judgeMinSessions {
		return nil, err
	}
	var out []db.CoachProposal
	if p, ok := claudeMDProposal(env, wb, measured); ok {
		out = append(out, p)
	}
	if p, ok := memoryIndexProposal(env, wb, measured); ok {
		out = append(out, p)
	}
	return out, nil
}

// newContextProposals drops the proposals whose fingerprint is known (open,
// declined, accepted or any other: never revived) and those whose text key
// already has an open proposal.
func newContextProposals(d *db.DB, props []db.CoachProposal) ([]db.CoachProposal, error) {
	if len(props) == 0 {
		return nil, nil
	}
	known, err := d.CoachFingerprints()
	if err != nil {
		return nil, err
	}
	open, err := d.ListCoachProposals("open")
	if err != nil {
		return nil, err
	}
	busy := map[textKey]bool{}
	for _, p := range open {
		busy[keyOf(p.Destination, p.WorkbenchID, p.PromptID, p.Skill, p.SourceKey)] = true
	}
	var out []db.CoachProposal
	for _, p := range props {
		if _, ok := known[p.Fingerprint]; ok {
			continue
		}
		if busy[keyOf(p.Destination, p.WorkbenchID, p.PromptID, p.Skill, p.SourceKey)] {
			continue
		}
		out = append(out, p)
	}
	return out, nil
}

// contextFingerprint is the key (keyOf: destination, workbench, source) plus
// before and after. A restructure passes its size class as before, so an
// index auto-memory grew by a line is the same proposal, and one grown past
// the next multiple of its threshold is a new one.
func contextFingerprint(key textKey, before, after string) string {
	return fmt.Sprintf("context|%s|%d|%s|%s|%s", key.dest, key.wb, key.source, before, after)
}

// sourceGroup is one source group summed over its rows: tokens over the
// measured rows, calls over every row (calls-only rows included), measured
// the most sessions any of its parts was measured in.
type sourceGroup struct {
	group, kind             string
	tokens, calls, measured int
}

func sourceGroups(rows []agentreport.ContextSourceRow) []sourceGroup {
	var out []sourceGroup
	idx := map[[2]string]int{}
	for _, r := range rows {
		k := [2]string{r.Group, r.GroupKind}
		i, ok := idx[k]
		if !ok {
			i = len(out)
			idx[k] = i
			out = append(out, sourceGroup{group: r.Group, kind: r.GroupKind})
		}
		g := &out[i]
		if r.Measured > 0 {
			g.tokens += r.Tokens
		}
		g.calls += r.Calls
		g.measured = max(g.measured, r.Measured)
	}
	return out
}

// foldPluginServers adds to each plugin group its own MCP servers' groups
// (mcp_server "plugin_<plugin id>_<server>"). Their calls go to every plugin
// whose prefix matches, so a plugin used only through its server is used: a
// plugin name that is a prefix of another's ("a", "a_b") also takes the
// other's calls, which errs toward not proposing. Their measured tokens (the
// plugin's servers go off with it) go only to the plugin with the longest
// matching id, so no plugin crosses the threshold on another's weight.
func foldPluginServers(groups []sourceGroup) []sourceGroup {
	out := slices.Clone(groups)
	prefixes := map[int]string{}
	for i, g := range out {
		if g.kind == agentreport.GroupPlugin {
			prefixes[i] = "plugin_" + agentreport.MCPServerID(g.group) + "_"
		}
	}
	for _, s := range groups {
		if s.kind != agentreport.GroupMCPServer {
			continue
		}
		owner, longest := -1, 0
		for i, prefix := range prefixes {
			if !strings.HasPrefix(s.group, prefix) {
				continue
			}
			out[i].calls += s.calls
			out[i].measured = max(out[i].measured, s.measured)
			if len(prefix) > longest {
				owner, longest = i, len(prefix)
			}
		}
		if owner >= 0 {
			out[owner].tokens += s.tokens
		}
	}
	return out
}

// unused is whether g is a candidate of rules 1–3: weighs enough, never
// called in any workbench, measured in enough sessions.
func (g sourceGroup) unused() bool {
	return g.calls == 0 && g.tokens >= ctxUnusedMinTokens && g.measured >= judgeMinSessions
}

// claudeConfigRead is the names-only config, file by file: a file that cannot
// be read or is not JSON of its shape leaves its flag false, and only the
// rules that read it skip.
type claudeConfigRead struct {
	cfg                             ClaudeConfig
	settings, installed, claudeJSON bool
}

func readContextConfig(env ContextEnv) claudeConfigRead {
	r := claudeConfigRead{cfg: ClaudeConfig{Plugins: map[string]PluginState{}, ProjectServers: map[string][]string{}}}
	read := func(label string, fn func(string, *ClaudeConfig) error) bool {
		if err := fn(env.Home, &r.cfg); err != nil {
			// The readers' errors name the label and the failure, never the path.
			env.logf("coach: context: %s not readable (%v); the proposals that need it are skipped", label, err)
			return false
		}
		return true
	}
	r.settings = read("settings.json", readUserSettingsNames)
	r.installed = read("installed_plugins.json", readInstalledPlugins)
	r.claudeJSON = read(".claude.json", readServerNames)
	return r
}

// globalContextProposals applies rules 1–3 to the install-wide groups. The
// config is read only when some group is a candidate.
func globalContextProposals(env ContextEnv, groups []sourceGroup) []db.CoachProposal {
	var cands []sourceGroup
	for _, g := range groups {
		switch g.kind {
		case agentreport.GroupPlugin, agentreport.GroupMCPServer, agentreport.GroupConnectors:
			if g.unused() {
				cands = append(cands, g)
			}
		}
	}
	if len(cands) == 0 {
		return nil
	}
	if env.Home == "" { // never read a relative ".claude/…"
		env.logf("coach: context: no home folder; the settings proposals are skipped")
		return nil
	}
	conf := readContextConfig(env)
	var out []db.CoachProposal
	for _, g := range cands {
		var p db.CoachProposal
		var ok bool
		switch g.kind {
		case agentreport.GroupPlugin:
			p, ok = pluginProposal(env, conf, g)
		case agentreport.GroupMCPServer:
			p, ok = serverProposal(env, conf, g)
		default:
			p, ok = connectorsProposal(env, conf, g)
		}
		if ok {
			out = append(out, p)
		}
	}
	return out
}

// pluginProposal is rule 1: the one plugin id of the group's name enabled in
// the user settings (two marketplaces' plugins of one name are ambiguous:
// none is filed).
func pluginProposal(env ContextEnv, conf claudeConfigRead, g sourceGroup) (db.CoachProposal, bool) {
	if !conf.settings || !conf.installed {
		return db.CoachProposal{}, false
	}
	var ids []string
	for id, st := range conf.cfg.Plugins {
		if name, _, _ := strings.Cut(id, "@"); name == g.group && st.Enabled {
			ids = append(ids, id)
		}
	}
	if len(ids) != 1 || IsProtected(DestPluginOff, ids[0]) {
		return db.CoachProposal{}, false
	}
	id := ids[0]
	if pluginWorksWithoutCalls(env.Home, id) {
		return db.CoachProposal{}, false
	}
	var elsewhere []string
	for _, s := range conf.cfg.Plugins[id].Scopes {
		if s != "user" {
			elsewhere = append(elsewhere, s)
		}
	}
	return settingsProposal(env, g, DestPluginOff, id, ctxText(env.Lang, "ctx.plugin.title", g.group), elsewhere)
}

// serverProposal is rule 2: the one user-scope server whose tool-id name is
// the group's. A plugin's server (plugin_<p>_<s>) is not a user server and is
// never filed here.
func serverProposal(env ContextEnv, conf claudeConfigRead, g sourceGroup) (db.CoachProposal, bool) {
	if !conf.claudeJSON {
		return db.CoachProposal{}, false
	}
	var names []string
	for _, n := range conf.cfg.UserServers {
		if agentreport.MCPServerID(n) == g.group {
			names = append(names, n)
		}
	}
	if len(names) != 1 || IsProtected(DestMCPServerOff, names[0]) || IsProtected(DestMCPServerOff, g.group) {
		return db.CoachProposal{}, false
	}
	name := names[0]
	var elsewhere []string
	for folder, servers := range conf.cfg.ProjectServers {
		if slices.Contains(servers, name) {
			elsewhere = append(elsewhere, folder)
		}
	}
	return settingsProposal(env, g, DestMCPServerOff, name, ctxText(env.Lang, "ctx.server.title", name), elsewhere)
}

// connectorsProposal is rule 3: the group sums every claude_ai_* server, so
// its 0 calls mean no connector was called (C7). Already off files nothing.
func connectorsProposal(env ContextEnv, conf claudeConfigRead, g sourceGroup) (db.CoachProposal, bool) {
	if !conf.settings {
		return db.CoachProposal{}, false
	}
	switch strings.ToLower(strings.TrimSpace(conf.cfg.ConnectorsEnv)) {
	case "false", "0":
		return db.CoachProposal{}, false
	}
	return settingsProposal(env, g, DestConnectorsOff, "connectors", ctxText(env.Lang, "ctx.connectors.title"), nil)
}

// settingsProposal builds a settings-key proposal from the key's current text
// as Accept will compare it (readSettingsKey). A plugin must read "true" (on
// at user scope); a key that cannot be read files nothing.
func settingsProposal(env ContextEnv, g sourceGroup, dest, source, title string, elsewhere []string) (db.CoachProposal, bool) {
	p := db.CoachProposal{Kind: "cut", Destination: dest, SourceKey: source, Origin: "context"}
	cur, err := (&Applier{Home: env.Home}).readSettingsKey(p, CurrentText{Destination: dest})
	if err != nil {
		env.logf("coach: context: %s %s skipped: %v", dest, source, err)
		return db.CoachProposal{}, false
	}
	if dest == DestPluginOff && cur.Text != "true" {
		return db.CoachProposal{}, false
	}
	after := settingsKeyAfter(dest)
	// The connectors are on whether the key is absent or set to "true": one
	// before for the fingerprint, so a declined proposal never returns. A
	// plugin's before is always "true" and a server's "present".
	fpBefore := cur.Text
	if dest == DestConnectorsOff {
		fpBefore = "on"
	}
	p.Fingerprint = contextFingerprint(keyOf(dest, 0, "", "", source), fpBefore, after)
	p.Title = title
	p.Why = ctxText(env.Lang, "ctx.unused.why", g.tokens, ctxWindowDays)
	p.Metric = "start_tokens"
	p.BeforeText, p.AfterText = cur.Text, after
	p.Evidence = []db.CoachEvidence{{Kind: "source", Ref: fmt.Sprintf(
		"%s · %d tok · 0 calls in Watchtower sessions (all workbenches) in %d days", g.group, g.tokens, ctxWindowDays)}}
	if names := baseNames(elsewhere); len(names) > 0 {
		p.Evidence = append(p.Evidence, db.CoachEvidence{Kind: "elsewhere", Ref: "on in: " + strings.Join(names, ", ")})
	}
	p.Sources = g.measured
	return p, true
}

// pluginInstallPaths is the install folders (installPath) of plugin id in
// installed_plugins.json. They are used here only, to look for file names,
// and never kept in ClaudeConfig, a row or a log.
func pluginInstallPaths(home, id string) ([]string, error) {
	raw, _, ok, err := readRegularFile("installed_plugins.json", errInstalledNotRegular, installedPluginsPath(home))
	if err != nil || !ok {
		return nil, err
	}
	top, err := objectKeys(raw, errInstalledInvalid)
	if err != nil {
		return nil, err
	}
	plugins, err := objectKeys(top["plugins"], errInstalledInvalid)
	if err != nil {
		return nil, err
	}
	var installs []struct {
		InstallPath string `json:"installPath"`
	}
	if json.Unmarshal(plugins[id], &installs) != nil {
		return nil, errInstalledInvalid
	}
	var out []string
	for _, in := range installs {
		if in.InstallPath != "" {
			out = append(out, in.InstallPath)
		}
	}
	return out, nil
}

// pluginWorksWithoutCalls is whether plugin id may be load-bearing with no
// calls to show for it: one of its installs ships hooks (hooks/hooks.json, or
// a "hooks" key in .claude-plugin/plugin.json), output styles (an
// output-styles/ folder, or an "outputStyles" key) or LSP servers (.lsp.json,
// or an "lspServers" key). An install that cannot be
// read, or no known install folder, counts as yes: the plugin is not
// proposed. Only names are read: whether the files exist and the manifest's
// keys, never a value.
func pluginWorksWithoutCalls(home, id string) bool {
	installPaths, err := pluginInstallPaths(home, id)
	if err != nil || len(installPaths) == 0 {
		return true
	}
	for _, dir := range installPaths {
		if fi, err := os.Stat(dir); err != nil || !fi.IsDir() {
			return true
		}
		for _, rel := range []string{filepath.Join("hooks", "hooks.json"), "output-styles", ".lsp.json"} {
			_, err := os.Lstat(filepath.Join(dir, rel))
			if err == nil || !errors.Is(err, fs.ErrNotExist) {
				return true
			}
		}
		raw, _, ok, err := readRegularFile("plugin.json", errContextNotRegular, filepath.Join(dir, ".claude-plugin", "plugin.json"))
		if err != nil {
			return true
		}
		if !ok {
			continue
		}
		keys, err := objectKeys(raw, errContextNotRegular)
		if err != nil {
			return true
		}
		if _, hooks := keys["hooks"]; hooks {
			return true
		}
		for _, k := range []string{"outputStyles", "lspServers"} {
			if _, ok := keys[k]; ok {
				return true
			}
		}
	}
	return false
}

// baseNames is the folders' last elements, deduplicated and sorted: the card
// names the projects, never a path.
func baseNames(folders []string) []string {
	var out []string
	for _, f := range folders {
		if b := filepath.Base(f); b != "." && b != string(filepath.Separator) {
			out = append(out, b)
		}
	}
	slices.Sort(out)
	return slices.Compact(out)
}

// mdSection is one "## " section of a markdown file: its heading line and its
// bytes, the heading and every line up to the next "#" or "##" heading
// included.
type mdSection struct {
	heading string
	bytes   int
}

// mdSections splits text into its "## " sections; headings inside fenced
// code blocks (``` or ~~~) do not count.
func mdSections(text string) []mdSection {
	var out []mdSection
	cur := -1
	fenced := false
	for _, line := range strings.SplitAfter(text, "\n") {
		trimmed := strings.TrimRight(line, "\r\n")
		if t := strings.TrimSpace(trimmed); strings.HasPrefix(t, "```") || strings.HasPrefix(t, "~~~") {
			fenced = !fenced
		}
		if !fenced {
			switch {
			case strings.HasPrefix(trimmed, "## "):
				out = append(out, mdSection{heading: oneLine(trimmed)})
				cur = len(out) - 1
			case strings.HasPrefix(trimmed, "# "):
				cur = -1
			}
		}
		if cur >= 0 {
			out[cur].bytes += len(line)
		}
	}
	return out
}

func kb(n int) float64 { return float64(n) / 1024 }

// readContextFile reads a file the proposer measures; a missing file is
// ok false with no error.
func readContextFile(env ContextEnv, label, path string) (string, bool) {
	raw, _, ok, err := readRegularFile(label, errContextNotRegular, path)
	if err != nil {
		env.logf("coach: context: %s not readable (%v); skipped", label, err)
		return "", false
	}
	return string(raw), ok
}

// maxHeadingRunes caps a section heading in a proposal's evidence.
const maxHeadingRunes = 80

// claudeMDProposal is rule 4: the workbench folder's CLAUDE.md of at least
// ctxClaudeMDMinBytes with a section of at least ctxClaudeMDSectionMinBytes.
// The session Accept starts does the move; the row carries the sizes, no
// text (before and after "": the file is in the repository).
func claudeMDProposal(env ContextEnv, wb *db.Workbench, measured int) (db.CoachProposal, bool) {
	text, ok := readContextFile(env, "CLAUDE.md", filepath.Join(wb.FolderPath, "CLAUDE.md"))
	if !ok || len(text) < ctxClaudeMDMinBytes {
		return db.CoachProposal{}, false
	}
	var big []mdSection
	for _, s := range mdSections(text) {
		if s.bytes >= ctxClaudeMDSectionMinBytes {
			big = append(big, s)
		}
	}
	if len(big) == 0 {
		return db.CoachProposal{}, false
	}
	slices.SortStableFunc(big, func(a, b mdSection) int { return cmp.Compare(b.bytes, a.bytes) })
	ev := []db.CoachEvidence{{Kind: "file", Ref: fmt.Sprintf("CLAUDE.md · %.1f KB", kb(len(text)))}}
	for _, s := range big {
		if len(ev) == maxEvidence {
			break
		}
		h := s.heading
		if utf8.RuneCountInString(h) > maxHeadingRunes {
			h = string([]rune(h)[:maxHeadingRunes]) + "…"
		}
		ev = append(ev, db.CoachEvidence{Kind: "section", Ref: fmt.Sprintf("%s · %.1f KB", h, kb(s.bytes))})
	}
	key := keyOf(DestRepoClaudeMD, wb.ID, "", "", "")
	return db.CoachProposal{
		Fingerprint: contextFingerprint(key, fmt.Sprintf("size:%d", len(text)/ctxClaudeMDMinBytes), ""),
		Kind:        "restructure", Destination: DestRepoClaudeMD, WorkbenchID: wb.ID, Origin: "context",
		Title:    ctxText(env.Lang, "ctx.claudemd.title"),
		Why:      ctxText(env.Lang, "ctx.claudemd.why", kb(len(text)), len(big), ctxClaudeMDSectionMinBytes/1024),
		Metric:   "start_tokens",
		Evidence: ev, Sources: measured,
	}, true
}

// memoryIndexPath is the auto-memory index of the workbench folder's project:
// <home>/.claude/projects/<slug of the folder>/memory/MEMORY.md.
func memoryIndexPath(home, folder string) string {
	return filepath.Join(home, ".claude", "projects", agentfiles.Slug(folder), "memory", "MEMORY.md")
}

// memoryIndexProposal is rule 5: the memory index of at least
// ctxMemoryIndexMinBytes. The row holds no index text: Accept reads it then.
func memoryIndexProposal(env ContextEnv, wb *db.Workbench, measured int) (db.CoachProposal, bool) {
	if env.Home == "" {
		return db.CoachProposal{}, false
	}
	text, ok := readContextFile(env, "MEMORY.md", memoryIndexPath(env.Home, wb.FolderPath))
	if !ok || len(text) < ctxMemoryIndexMinBytes {
		return db.CoachProposal{}, false
	}
	key := keyOf(DestMemoryIndex, wb.ID, "", "", "memory")
	return db.CoachProposal{
		Fingerprint: contextFingerprint(key, fmt.Sprintf("size:%d", len(text)/ctxMemoryIndexMinBytes), ""),
		Kind:        "restructure", Destination: DestMemoryIndex, WorkbenchID: wb.ID, SourceKey: "memory",
		Origin: "context",
		Title:  ctxText(env.Lang, "ctx.memory.title"),
		Why:    ctxText(env.Lang, "ctx.memory.why", kb(len(text))),
		Metric: "start_tokens",
		Evidence: []db.CoachEvidence{{Kind: "file", Ref: fmt.Sprintf("MEMORY.md · %.1f KB · %d lines",
			kb(len(text)), len(nonEmptyLines(text)))}},
		Sources: measured,
	}, true
}
