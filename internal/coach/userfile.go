package coach

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"unicode/utf8"

	"watchtower/internal/devpack"
)

// The owner's text files the coach edits besides ~/.claude/CLAUDE.md: the
// Claude Code and Codex user skills and ~/.codex/AGENTS.md (spec §4.3). They
// follow CLAUDE.md's rules — a regular UTF-8 file up to claudeMDMaxBytes, an
// exact-text replace through an atomic write that re-reads the file just
// before the rename — and also refuse a symlink at any folder between the
// home root and the file. Errors name the destination label, never the path
// or the text (FILES-01).

var (
	errUnsafeFile    = errors.New("is a symlink, not a regular file, too large or not text")
	errSkillNotFound = errors.New("skill not found")
	errBadSkillName  = errors.New("not a skill name")
	// errPackSkill refuses a user-skill edit of an installed Watchtower pack
	// copy: the pack overlay is the way to change a pack skill.
	errPackSkill = errors.New("is a Watchtower pack skill; change it through the pack overlay")
)

// validSkillName is a skill folder name: one path component that never holds
// "|" (the fingerprint separator), "/" or a leading dot (so never "..").
var validSkillName = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`)

func checkSkillName(name string) error {
	if !validSkillName.MatchString(name) {
		return errBadSkillName
	}
	return nil
}

// Env is where the coach reads and writes the owner's files: the same seams
// Applier has.
type Env struct {
	Home string
	// CodexHome is Codex's home ($CODEX_HOME); "" = <Home>/.codex.
	CodexHome string
}

// CodexHomeFromEnv is $CODEX_HOME when it is an absolute path, else "" (the
// coach then uses <Home>/.codex, Codex's own default).
func CodexHomeFromEnv() string {
	if dir := os.Getenv("CODEX_HOME"); filepath.IsAbs(dir) {
		return dir
	}
	return ""
}

func (e Env) codexHome() string {
	if e.CodexHome != "" {
		return e.CodexHome
	}
	return filepath.Join(e.Home, ".codex")
}

// ClaudeSkillPath is <Home>/.claude/skills/<name>/SKILL.md.
func ClaudeSkillPath(e Env, name string) string {
	return filepath.Join(e.Home, ".claude", "skills", name, "SKILL.md")
}

// CodexSkillPath is the copy of a user skill Codex reads, when there is
// exactly one: <Home>/.agents/skills/<name>/SKILL.md or
// <codexHome>/skills/<name>/SKILL.md. ok is false when neither exists or both
// do (the coach refuses a skill in both folders: errCodexSkillTwice).
// "Exists" is any kind of entry: the read refuses a symlink or special file.
//
// Source (checked 2026-11-10): Codex loads user skills from both folders —
// codex-rs/ext/skills/src/host_roots.rs lists $HOME/.agents/skills (the
// documented user location, learn.chatgpt.com/docs/build-skills) and
// $CODEX_HOME/skills ("deprecated user skills location, kept for backward
// compatibility"), deduplicating by path only; two skills with one name are
// not merged ("both can appear in skill selectors"), so neither copy wins
// (owner, ask #1202: refuse until one copy is removed).
func CodexSkillPath(e Env, name string) (path string, ok bool) {
	paths := codexSkillCopies(e, name)
	if len(paths) != 1 {
		return "", false
	}
	return paths[0], true
}

// codexSkillCopies is the copies of a Codex user skill that exist, in the
// order ~/.agents/skills, <codexHome>/skills.
func codexSkillCopies(e Env, name string) []string {
	var out []string
	for _, p := range []string{
		filepath.Join(e.Home, ".agents", "skills", name, "SKILL.md"),
		filepath.Join(e.codexHome(), "skills", name, "SKILL.md"),
	} {
		if _, err := os.Lstat(p); err == nil {
			out = append(out, p)
		}
	}
	return out
}

// errCodexSkillTwice is the refusal for a Codex user skill present in both
// folders Codex reads (owner, ask #1202).
var errCodexSkillTwice = errors.New("a codex skill in two folders")

// codexSkillTwiceError carries the owner's exact sentence, naming the real
// Codex home when $CODEX_HOME is set.
type codexSkillTwiceError struct{ codexSkills string }

func (e codexSkillTwiceError) Error() string {
	return "Codex sees this skill in two folders (~/.agents/skills and " + e.codexSkills +
		") — remove one copy first."
}

func (e codexSkillTwiceError) Is(target error) bool { return target == errCodexSkillTwice }

func (e Env) codexSkillsLabel() string {
	if e.CodexHome != "" {
		return filepath.Join(e.CodexHome, "skills")
	}
	return "~/.codex/skills"
}

// resolveTop is the root of a file destination: top (~/.claude, ~/.agents or
// the Codex home) itself, or the real folder it links to — the one component
// allowed to be a symlink (owner, ask #1202: dotfiles). A missing top is kept
// as is (AGENTS.md creates it); anything else that is not a folder is refused.
func (f textFile) resolveTop(top string) (string, error) {
	fi, err := os.Lstat(top)
	if errors.Is(err, fs.ErrNotExist) {
		return top, nil
	}
	if err != nil {
		return "", settingsErr("reading the "+f.label+" folder", err)
	}
	if fi.IsDir() {
		return top, nil
	}
	if fi.Mode()&fs.ModeSymlink == 0 {
		return "", f.notRegular
	}
	resolved, err := filepath.EvalSymlinks(top)
	if err != nil {
		return "", f.notRegular
	}
	if fi, err := os.Stat(resolved); err != nil || !fi.IsDir() {
		return "", f.notRegular
	}
	return resolved, nil
}

// codexAgentsMDPath is <codexHome>/AGENTS.md.
func codexAgentsMDPath(e Env) string { return filepath.Join(e.codexHome(), "AGENTS.md") }

// textFile is one kind of owner text file: its label for errors, its temp-file
// pattern and its errors (missing: the file does not exist and may not be
// created), and whether a copy with the devpack marker is refused.
type textFile struct {
	label, tmp                           string
	notRegular, tooBig, changed, missing error
	packCheck                            bool
}

var (
	skillFileKind = textFile{label: "SKILL.md", tmp: ".SKILL.md.coach-*",
		notRegular: fmt.Errorf("SKILL.md %w", errUnsafeFile), tooBig: fmt.Errorf("SKILL.md %w", errUnsafeFile),
		changed: errors.New("SKILL.md changed while it was being written"), missing: errSkillNotFound, packCheck: true}
	agentsMDKind = textFile{label: "AGENTS.md", tmp: ".AGENTS.md.coach-*",
		notRegular: fmt.Errorf("AGENTS.md %w", errUnsafeFile), tooBig: fmt.Errorf("AGENTS.md %w", errUnsafeFile),
		changed: errors.New("AGENTS.md changed while it was being written")}
)

// atomic is the writeAtomic kind of f for a file below root.
func (f textFile) atomic(root string) atomicKind {
	return atomicKind{label: f.label, tmp: f.tmp, changed: f.changed,
		read: func(path string) ([]byte, fs.FileMode, bool, error) { return f.read(root, path) }}
}

// checkFolders refuses a symlink or non-folder at any component between root
// (not itself checked) and path's folder. missing is true when a folder on the
// way does not exist (so the file does not either).
func (f textFile) checkFolders(root, path string) (missing bool, err error) {
	rel, err := filepath.Rel(root, filepath.Dir(path))
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return false, f.notRegular
	}
	if rel == "." {
		return false, nil
	}
	cur := root
	for _, part := range strings.Split(rel, string(filepath.Separator)) {
		cur = filepath.Join(cur, part)
		fi, err := os.Lstat(cur)
		if errors.Is(err, fs.ErrNotExist) {
			return true, nil
		}
		if err != nil {
			return false, settingsErr("reading the "+f.label+" folder", err)
		}
		if !fi.IsDir() {
			return false, f.notRegular
		}
	}
	return false, nil
}

// read returns the file's bytes and permission bits; exists is false (and err
// nil) when there is no file.
func (f textFile) read(root, path string) (raw []byte, mode fs.FileMode, exists bool, err error) {
	missing, err := f.checkFolders(root, path)
	if err != nil || missing {
		return nil, 0, false, err
	}
	fi, err := os.Lstat(path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, 0, false, nil
	}
	if err != nil {
		return nil, 0, false, settingsErr("reading "+f.label, err)
	}
	if !fi.Mode().IsRegular() {
		return nil, 0, false, f.notRegular
	}
	if fi.Size() > claudeMDMaxBytes {
		return nil, 0, false, f.tooBig
	}
	raw, err = os.ReadFile(path)
	if err != nil {
		return nil, 0, false, settingsErr("reading "+f.label, err)
	}
	if len(raw) > claudeMDMaxBytes || !utf8.Valid(raw) {
		return nil, 0, false, f.tooBig
	}
	return raw, fi.Mode().Perm(), true, nil
}

// replace makes the file hold to, only while it still holds from (an empty
// from also matches a missing file); otherwise f.changed. A missing file is
// f.missing unless create, when it and its folders are created (0600,
// 0700); an existing file keeps its mode. It returns whether the file existed.
func (f textFile) replace(root, path, from, to string, create bool) (existed bool, err error) {
	raw, mode, exists, err := f.read(root, path)
	if err != nil {
		return false, err
	}
	if !exists && !create {
		return false, f.missing
	}
	if string(raw) != from {
		return exists, f.changed
	}
	if !exists {
		mode = 0o600
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			return false, settingsErr("creating the "+f.label+" folder", err)
		}
	}
	return exists, writeAtomic(f.atomic(root), path, []byte(to), mode, raw, exists)
}

// userFile is where a file destination lives: its kind, the root below which
// no folder may be a symlink (the resolved ~/.claude, ~/.agents or Codex
// home), the path, and whether a missing file may be created (only AGENTS.md).
type userFile struct {
	kind   textFile
	root   string
	path   string
	create bool
}

// under is the userFile for rel below top, top resolved by resolveTop.
func under(kind textFile, top, rel string, create bool) (userFile, error) {
	root, err := kind.resolveTop(top)
	if err != nil {
		return userFile{}, err
	}
	return userFile{kind: kind, root: root, path: filepath.Join(root, rel), create: create}, nil
}

// userFileOf resolves a file destination for skill (skill destinations only).
func userFileOf(e Env, dest, skill string) (userFile, error) {
	if e.Home == "" {
		return userFile{}, errors.New("no home folder")
	}
	if skillDestinations[dest] {
		if err := checkSkillName(skill); err != nil {
			return userFile{}, err
		}
	}
	rel := filepath.Join("skills", skill, "SKILL.md")
	switch dest {
	case DestClaudeSkillUser:
		return under(skillFileKind, filepath.Join(e.Home, ".claude"), rel, false)
	case DestCodexSkillUser:
		agents := filepath.Join(e.Home, ".agents")
		copies := codexSkillCopies(e, skill)
		switch {
		case len(copies) == 0:
			return userFile{}, errSkillNotFound
		case len(copies) > 1:
			return userFile{}, codexSkillTwiceError{codexSkills: e.codexSkillsLabel()}
		case copies[0] == filepath.Join(agents, rel):
			return under(skillFileKind, agents, rel, false)
		}
		return under(skillFileKind, e.codexHome(), rel, false)
	case DestCodexAgentsMDUser:
		return under(agentsMDKind, e.codexHome(), "AGENTS.md", true)
	case DestCodexRulesAllow:
		return under(codexRulesKind, e.codexHome(), codexRulesRel, false)
	}
	return userFile{}, errNotSupported
}

// readText reads the destination's text: a missing file is "" when it may be
// created, else the kind's missing error; a skill holding the devpack marker is an
// installed pack copy and refused.
func (u userFile) readText() (string, error) {
	raw, _, exists, err := u.kind.read(u.root, u.path)
	if err != nil {
		return "", err
	}
	if !exists {
		if u.create {
			return "", nil
		}
		return "", u.kind.missing
	}
	if u.kind.packCheck && devpack.HasMarker(string(raw)) {
		return "", errPackSkill
	}
	return string(raw), nil
}

// replaceText is replace over u: the kind's changed error means the file no
// longer holds from (callers map it to ErrStale or ErrChangedSince), and a
// skill that went missing is never created again.
func (u userFile) replaceText(from, to string) error {
	_, err := u.kind.replace(u.root, u.path, from, to, u.create)
	return err
}
