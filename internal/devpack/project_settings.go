package devpack

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"slices"
	"strings"
)

// ErrMalformedSettings means .claude/settings.local.json exists but is not
// a JSON object whose hooks / hooks.SessionStart have the documented types.
// The file is then never written (PROJ-04): the owner fixes it, not us.
var ErrMalformedSettings = errors.New("malformed .claude/settings.local.json")

// sessionStartHookTimeoutSec bounds the brief so a stuck DB can never stall
// a Claude Code session start (`project brief` itself always exits 0).
const sessionStartHookTimeoutSec = 10

func settingsLocalPath(dir string) string {
	return filepath.Join(dir, ".claude", "settings.local.json")
}

// InstallSessionStartHook adds one SessionStart command hook running command
// to dir's .claude/settings.local.json. Our entry is recognised by its exact
// command string anywhere under hooks.SessionStart, so a second install is a
// no-op. Every other key, event and hook is preserved; the group omits a
// matcher so it fires on startup, resume, clear and compact alike.
func InstallSessionStartHook(dir, command string) (bool, error) {
	file := settingsLocalPath(dir)
	settings, mode, _, err := readSettings(file)
	if err != nil {
		return false, err
	}
	hooks, groups, err := sessionStartOf(settings, file)
	if err != nil {
		return false, err
	}
	if hasCommand(groups, command) {
		return false, nil
	}
	ours := map[string]any{"hooks": []any{map[string]any{
		"type":    "command",
		"command": command,
		"timeout": sessionStartHookTimeoutSec,
	}}}
	hooks["SessionStart"] = append(groups, ours)
	settings["hooks"] = hooks
	return true, writeSettings(file, settings, mode)
}

// RemoveSessionStartHook removes every hook object running exactly command.
// A group left with no hooks is dropped, then an empty SessionStart, an
// empty hooks object, and — when nothing at all is left — the file itself.
// Anything else in the file stays.
func RemoveSessionStartHook(dir, command string) (bool, error) {
	file := settingsLocalPath(dir)
	settings, mode, existed, err := readSettings(file)
	if err != nil || !existed {
		return false, err
	}
	hooks, groups, err := sessionStartOf(settings, file)
	if err != nil {
		return false, err
	}
	kept, changed := withoutCommand(groups, command)
	if !changed {
		return false, nil
	}
	pruneEmpty(settings, hooks, kept)
	if len(settings) == 0 {
		if err := os.Remove(file); err != nil {
			return false, fmt.Errorf("removing %s: %w", file, err)
		}
		return true, nil
	}
	return true, writeSettings(file, settings, mode)
}

// HasSessionStartHook reports whether a hook running exactly command is
// installed in dir's .claude/settings.local.json.
func HasSessionStartHook(dir, command string) (bool, error) {
	file := settingsLocalPath(dir)
	settings, _, existed, err := readSettings(file)
	if err != nil || !existed {
		return false, err
	}
	_, groups, err := sessionStartOf(settings, file)
	if err != nil {
		return false, err
	}
	return hasCommand(groups, command), nil
}

// readSettings decodes file as one JSON object. A missing or whitespace-only
// file is an empty object; numbers stay json.Number so the owner's literals
// ("1.50") are written back as they were.
func readSettings(file string) (map[string]any, os.FileMode, bool, error) {
	b, err := os.ReadFile(file)
	if errors.Is(err, os.ErrNotExist) {
		return map[string]any{}, 0o644, false, nil
	}
	if err != nil {
		return nil, 0, false, fmt.Errorf("reading %s: %w", file, err)
	}
	info, err := os.Stat(file)
	if err != nil {
		return nil, 0, false, fmt.Errorf("inspecting %s: %w", file, err)
	}
	if len(bytes.TrimSpace(b)) == 0 {
		return map[string]any{}, info.Mode().Perm(), true, nil
	}
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.UseNumber()
	var v any
	if err := dec.Decode(&v); err != nil {
		return nil, 0, false, fmt.Errorf("%w: %s: %v", ErrMalformedSettings, file, err)
	}
	if _, err := dec.Token(); !errors.Is(err, io.EOF) {
		return nil, 0, false, fmt.Errorf("%w: %s: trailing data after the top-level object", ErrMalformedSettings, file)
	}
	obj, ok := v.(map[string]any)
	if !ok {
		return nil, 0, false, fmt.Errorf("%w: %s: the top level is not an object", ErrMalformedSettings, file)
	}
	return obj, info.Mode().Perm(), true, nil
}

// sessionStartOf returns the hooks object (a fresh one when absent, not yet
// attached) and its SessionStart groups, refusing a shape it does not know.
func sessionStartOf(settings map[string]any, file string) (map[string]any, []any, error) {
	hooks := map[string]any{}
	if raw, ok := settings["hooks"]; ok {
		m, isObj := raw.(map[string]any)
		if !isObj {
			return nil, nil, fmt.Errorf("%w: %s: \"hooks\" is not an object", ErrMalformedSettings, file)
		}
		hooks = m
	}
	raw, ok := hooks["SessionStart"]
	if !ok {
		return hooks, nil, nil
	}
	groups, isArr := raw.([]any)
	if !isArr {
		return nil, nil, fmt.Errorf("%w: %s: \"hooks.SessionStart\" is not an array", ErrMalformedSettings, file)
	}
	return hooks, groups, nil
}

// groupHooks unpacks one SessionStart group; ok is false for any group whose
// shape is not {"hooks": [...]} — such a group is never ours and is kept.
func groupHooks(g any) (map[string]any, []any, bool) {
	m, ok := g.(map[string]any)
	if !ok {
		return nil, nil, false
	}
	hs, ok := m["hooks"].([]any)
	return m, hs, ok
}

func isOurHook(h any, command string) bool {
	m, ok := h.(map[string]any)
	return ok && m["command"] == command
}

func hasCommand(groups []any, command string) bool {
	for _, g := range groups {
		_, hs, ok := groupHooks(g)
		if !ok {
			continue
		}
		if slices.ContainsFunc(hs, func(h any) bool { return isOurHook(h, command) }) {
			return true
		}
	}
	return false
}

// withoutCommand filters our hook objects out of every group. A group that
// still holds an owner hook survives (copied, so the input is untouched);
// a group that held only ours is dropped.
func withoutCommand(groups []any, command string) ([]any, bool) {
	kept := make([]any, 0, len(groups))
	changed := false
	for _, g := range groups {
		m, hs, ok := groupHooks(g)
		if !ok {
			kept = append(kept, g)
			continue
		}
		rest := slices.DeleteFunc(slices.Clone(hs), func(h any) bool { return isOurHook(h, command) })
		if len(rest) == len(hs) {
			kept = append(kept, g)
			continue
		}
		changed = true
		if len(rest) == 0 {
			continue
		}
		cp := make(map[string]any, len(m))
		for k, v := range m {
			cp[k] = v
		}
		cp["hooks"] = rest
		kept = append(kept, cp)
	}
	return kept, changed
}

// pruneEmpty writes kept back as hooks.SessionStart, dropping each level
// that became empty.
func pruneEmpty(settings, hooks map[string]any, kept []any) {
	if len(kept) == 0 {
		delete(hooks, "SessionStart")
	} else {
		hooks["SessionStart"] = kept
	}
	if len(hooks) == 0 {
		delete(settings, "hooks")
	} else {
		settings["hooks"] = hooks
	}
}

// writeSettings replaces file atomically, keeping its mode. Keys come out
// sorted (encoding/json), HTML characters unescaped, two-space indented.
func writeSettings(file string, settings map[string]any, mode os.FileMode) error {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(settings); err != nil {
		return fmt.Errorf("encoding %s: %w", file, err)
	}
	dir := filepath.Dir(file)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("creating %s: %w", dir, err)
	}
	tmp, err := os.CreateTemp(dir, ".settings.local.json.*")
	if err != nil {
		return fmt.Errorf("creating a temp file in %s: %w", dir, err)
	}
	defer func() { _ = os.Remove(tmp.Name()) }() // no-op once renamed
	if _, err := tmp.Write(buf.Bytes()); err != nil {
		_ = tmp.Close()
		return fmt.Errorf("writing %s: %w", tmp.Name(), err)
	}
	if err := tmp.Chmod(mode); err != nil {
		_ = tmp.Close()
		return fmt.Errorf("setting the mode of %s: %w", tmp.Name(), err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("closing %s: %w", tmp.Name(), err)
	}
	if err := os.Rename(tmp.Name(), file); err != nil {
		return fmt.Errorf("replacing %s: %w", file, err)
	}
	return nil
}

// --- git exclude ---

// Our exclude lines live between these markers so removal can never take a
// line the owner wrote themselves, even an identical one.
const (
	excludeBegin = "# >>> watchtower-project: managed by `watchtower integrate --project`"
	excludeEnd   = "# <<< watchtower-project"
)

// EnsureGitExclude makes lines (relative to dir) ignored through the
// info/exclude git reads for dir's work tree. Outside a work tree it does
// nothing. A pattern already present — ours or the owner's — is skipped.
func EnsureGitExclude(dir string, lines []string) ([]string, error) {
	loc, ok, err := locateGitExclude(dir)
	if err != nil || !ok {
		return nil, err
	}
	doc, err := readExclude(loc.file)
	if err != nil {
		return nil, err
	}
	var added []string
	for _, l := range lines {
		p := loc.anchor(l)
		if doc.has(p) {
			continue
		}
		doc.block = append(doc.block, p)
		added = append(added, p)
	}
	if len(added) == 0 {
		return nil, nil
	}
	return added, writeExclude(loc.file, doc)
}

// RemoveGitExclude removes lines' anchored patterns from our marked block.
// Lines outside the block are the owner's and are never touched.
func RemoveGitExclude(dir string, lines []string) error {
	loc, ok, err := locateGitExclude(dir)
	if err != nil || !ok {
		return err
	}
	doc, err := readExclude(loc.file)
	if err != nil {
		return err
	}
	drop := make(map[string]bool, len(lines))
	for _, l := range lines {
		drop[loc.anchor(l)] = true
	}
	kept := slices.DeleteFunc(slices.Clone(doc.block), func(p string) bool { return drop[p] })
	if len(kept) == len(doc.block) {
		return nil
	}
	doc.block = kept
	return writeExclude(loc.file, doc)
}

// excludeLoc is the info/exclude file git reads for a work tree, plus the
// project folder's path relative to that work tree's top.
type excludeLoc struct {
	file, rel string
}

// anchor turns a dir-relative line into a pattern anchored at the work
// tree's top. Glob characters in the path are escaped, so a folder named
// "acme [beta]" matches literally; a trailing "/" (directory) is kept.
func (l excludeLoc) anchor(line string) string {
	p := path.Join("/", filepath.ToSlash(l.rel), line)
	if strings.HasSuffix(line, "/") {
		p += "/"
	}
	return escapeGitignore(p)
}

func escapeGitignore(p string) string {
	var b strings.Builder
	for _, r := range p {
		if strings.ContainsRune(`\*?[`, r) {
			b.WriteByte('\\')
		}
		b.WriteRune(r)
	}
	return b.String()
}

// locateGitExclude walks up from dir to the first .git (a directory, or a
// linked worktree's "gitdir:" file) and resolves the common dir's
// info/exclude. ok is false when dir is not inside a work tree.
func locateGitExclude(dir string) (excludeLoc, bool, error) {
	abs, err := filepath.Abs(dir)
	if err != nil {
		return excludeLoc{}, false, fmt.Errorf("resolving %s: %w", dir, err)
	}
	for cur := abs; ; cur = filepath.Dir(cur) {
		gitDir, found, err := gitDirAt(cur)
		if err != nil {
			return excludeLoc{}, false, err
		}
		if found {
			common, err := commonGitDir(gitDir)
			if err != nil {
				return excludeLoc{}, false, err
			}
			rel, err := filepath.Rel(cur, abs)
			if err != nil {
				return excludeLoc{}, false, fmt.Errorf("relating %s to %s: %w", abs, cur, err)
			}
			return excludeLoc{file: filepath.Join(common, "info", "exclude"), rel: rel}, true, nil
		}
		if filepath.Dir(cur) == cur {
			return excludeLoc{}, false, nil
		}
	}
}

func gitDirAt(dir string) (string, bool, error) {
	p := filepath.Join(dir, ".git")
	info, err := os.Stat(p)
	if errors.Is(err, os.ErrNotExist) {
		return "", false, nil
	}
	if err != nil {
		return "", false, fmt.Errorf("inspecting %s: %w", p, err)
	}
	if info.IsDir() {
		return p, true, nil
	}
	b, err := os.ReadFile(p)
	if err != nil {
		return "", false, fmt.Errorf("reading %s: %w", p, err)
	}
	target, ok := strings.CutPrefix(strings.TrimSpace(string(b)), "gitdir:")
	if !ok {
		return "", false, fmt.Errorf("%s is neither a git directory nor a gitdir file", p)
	}
	target = strings.TrimSpace(target)
	if !filepath.IsAbs(target) {
		target = filepath.Join(dir, target)
	}
	return target, true, nil
}

// commonGitDir follows a linked worktree's commondir file; a main work
// tree's git dir is its own common dir.
func commonGitDir(gitDir string) (string, error) {
	b, err := os.ReadFile(filepath.Join(gitDir, "commondir"))
	if errors.Is(err, os.ErrNotExist) {
		return gitDir, nil
	}
	if err != nil {
		return "", fmt.Errorf("reading %s/commondir: %w", gitDir, err)
	}
	common := strings.TrimSpace(string(b))
	if !filepath.IsAbs(common) {
		common = filepath.Join(gitDir, common)
	}
	return filepath.Clean(common), nil
}

// excludeDoc is an exclude file split into the owner's lines and ours.
type excludeDoc struct {
	outside, block []string
}

func (d excludeDoc) has(p string) bool {
	return slices.Contains(d.outside, p) || slices.Contains(d.block, p)
}

func readExclude(file string) (excludeDoc, error) {
	b, err := os.ReadFile(file)
	if errors.Is(err, os.ErrNotExist) {
		return excludeDoc{}, nil
	}
	if err != nil {
		return excludeDoc{}, fmt.Errorf("reading %s: %w", file, err)
	}
	var d excludeDoc
	inBlock := false
	for _, l := range splitLines(string(b)) {
		switch {
		case l == excludeBegin:
			inBlock = true
		case l == excludeEnd:
			inBlock = false
		case inBlock:
			d.block = append(d.block, l)
		default:
			d.outside = append(d.outside, l)
		}
	}
	return d, nil
}

// writeExclude writes the owner's lines first, verbatim and in order, then
// our block — or no block at all once it is empty.
func writeExclude(file string, d excludeDoc) error {
	out := slices.Clone(d.outside)
	if len(d.block) > 0 {
		out = append(out, excludeBegin)
		out = append(out, d.block...)
		out = append(out, excludeEnd)
	}
	content := ""
	if len(out) > 0 {
		content = strings.Join(out, "\n") + "\n"
	}
	if err := os.MkdirAll(filepath.Dir(file), 0o755); err != nil {
		return fmt.Errorf("creating %s: %w", filepath.Dir(file), err)
	}
	if err := os.WriteFile(file, []byte(content), 0o644); err != nil {
		return fmt.Errorf("writing %s: %w", file, err)
	}
	return nil
}

func splitLines(s string) []string {
	if s == "" {
		return nil
	}
	return strings.Split(strings.TrimSuffix(s, "\n"), "\n")
}
