package devpack

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"slices"
	"strings"

	"github.com/pelletier/go-toml/v2"

	"watchtower/internal/codex"
	"watchtower/internal/config"
)

// codexExcludeLines are the folder-relative paths the codex install makes
// git-invisible: the skill copies, nothing else.
var codexExcludeLines = []string{".agents/skills/" + WorkbenchSkillName + "/", codexFlowExcludeLine}

// ErrCodexHooksNotEditable means a folder's .codex/config.toml holds our
// imported hooks in a shape the installer does not rewrite in place (an
// inline array, say). The file is left byte-identical; the owner removes
// the entries by hand.
var ErrCodexHooksNotEditable = errors.New("cannot remove the imported workbench hooks from .codex/config.toml in place")

// ErrCodexUnresolved means it is unknown which codex binary to use (the
// config naming codex_path did not load): unlike ErrCodexNotFound it is an
// error, and Found reads false.
var ErrCodexUnresolved = errors.New("could not resolve the codex binary")

// CodexStatus is the codex part of a workbench folder. Found: a codex binary
// was resolved. Skill: the skill copy in .agents/skills is in, current or
// not (an owner-edited copy counts: it is theirs, PROJ-04; an outdated one
// reads SkillState "updated" in a status). HooksTrusted: every
// hook of the codex hook set is trusted, nil when codex could not be asked.
// ImportedDuplicates: codex's import left our hook commands in the folder's
// .codex/hooks.json or .codex/config.toml. SkillState and DuplicatesRemoved
// say what an install or removal did. TrustError is why a status could not
// confirm the trust ("" when it could): codex could not be asked, did not
// list every hook, or could not be resolved.
type CodexStatus struct {
	Found, Skill       bool
	HooksTrusted       *bool
	ImportedDuplicates bool
	TrustError         string

	SkillState State
	// GroupPrompt: the skill copy knows the group first prompt
	// (skillKnowsGroupPrompt); set by a status only.
	GroupPrompt bool
	// FlowState and SingleFileLayout are the preset's outcome beside the
	// skill copy, as WorkbenchInstallReport's Flow and SingleFileLayout.
	FlowState         State
	SingleFileLayout  bool
	DuplicatesRemoved bool
}

// StartCodexAppServer is codex.StartAppServer's shape, a seam for tests.
type StartCodexAppServer func(ctx context.Context, bin string, extraArgs, env []string) (codex.AppServer, error)

// CodexAppServer returns the app-server factory the codex install and status
// use: it resolves the codex binary (cfg's codex_path, else find; none is
// ErrCodexNotFound) and starts it with codexAppServerArgs(bin), with the
// binary's directory in front of PATH so a node shim finds node.
func CodexAppServer(ctx context.Context, cfg *config.Config, bin string, find func() (string, error), start StartCodexAppServer) func() (codex.AppServer, error) {
	return func() (codex.AppServer, error) {
		codexBin, err := resolveCodexBinary(cfg, find)
		if err != nil {
			return nil, err
		}
		return start(ctx, codexBin, codexAppServerArgs(bin), envWithPathPrepend(os.Environ(), filepath.Dir(codexBin)))
	}
}

// CodexFound reports whether a codex binary resolves: cfg's codex_path,
// else find's answer.
func CodexFound(cfg *config.Config, find func() (string, error)) bool {
	_, err := resolveCodexBinary(cfg, find)
	return err == nil
}

// CodexSkillInstalled reports whether folder holds the workbench skill's
// codex copy, in any state (a resync then refreshes it even without codex).
func CodexSkillInstalled(folder string) bool {
	return exists(filepath.Join(folder, ".agents", "skills", WorkbenchSkillName, "SKILL.md"))
}

// codexAppServerArgs are the flags the trust step starts the app-server
// with: the update check off and the hook overrides, built from the same
// CodexHookSet as the launch flags, so the hashed strings are the launched
// ones (spec I5).
func codexAppServerArgs(bin string) []string {
	return append([]string{"-c", codexNoUpdateCheck}, CodexHookOverrides(CodexHookSet(bin))...)
}

func envWithPathPrepend(env []string, dir string) []string {
	out := make([]string, 0, len(env)+1)
	path := dir
	for _, kv := range env {
		if v, ok := strings.CutPrefix(kv, "PATH="); ok {
			if v != "" {
				path = dir + string(os.PathListSeparator) + v
			}
			continue
		}
		out = append(out, kv)
	}
	return append(out, "PATH="+path)
}

// codexHookRefs names every hook of bin's codex hook set for the trust step.
func codexHookRefs(bin string) []codex.HookRef {
	set := CodexHookSet(bin)
	refs := make([]codex.HookRef, 0, len(set))
	for _, h := range set {
		refs = append(refs, codex.HookRef{Event: h.Event, Command: h.Command})
	}
	return refs
}

// InstallCodex makes the folder ready for codex: the exclude line, the
// skill copy in .agents/skills (the same embedded bytes as the Claude copy,
// I7), our hook commands codex's import copied into .codex taken out, and
// the hook set trusted through the app-server srv starts. No codex binary
// (srv answers ErrCodexNotFound) is no error: Found is false and the trust
// step is skipped. It never writes projects.* or any key but our own
// hooks.state entries (I4). Every step runs; the failures come back joined.
func InstallCodex(ctx context.Context, o WorkbenchInstallOptions, srv func() (codex.AppServer, error)) (CodexStatus, error) {
	if err := o.validateCodex(); err != nil {
		return CodexStatus{}, err
	}
	if !isDir(o.Folder) {
		return CodexStatus{}, codexFolderGone(o)
	}
	var st CodexStatus
	var errs []error
	if _, err := EnsureGitExclude(o.Folder, codexExcludeLines); err != nil {
		errs = append(errs, err)
	}
	var sk SkillStatus
	if err := skillDirsInside(o.Folder, o.codexSkillsDir(), workbenchSkill(), flowSkill()); err != nil {
		errs = append(errs, err)
	} else {
		var flow SkillStatus
		var pairErrs []error
		sk, flow, st.SingleFileLayout, pairErrs = installSkillPair(o.codexSkillsDir(), o.PresetNone)
		st.FlowState = flow.State
		errs = append(errs, pairErrs...)
	}
	st.SkillState, st.Skill = sk.State, sk.Path != "" // the core copy went in, whatever became of the preset
	var err error
	st.DuplicatesRemoved, err = dedupeImportedHooks(o.Folder, o.WorkbenchID)
	if err != nil {
		errs = append(errs, err)
		st.ImportedDuplicates = hasImportedDuplicates(o.Folder, o.WorkbenchID)
	}
	st.HooksTrusted, st.Found, err = trustCodexHooks(ctx, o, srv, true)
	if err != nil {
		errs = append(errs, err)
	}
	return st, errors.Join(errs...)
}

// RemoveCodex undoes InstallCodex in the folder (PROJ-02): our un-edited
// skill copy, .agents/skills and .agents once empty, our hook commands in
// .codex, and the exclude line of a path that is gone. It never touches the
// hook trust in ~/.codex/config.toml: one launch-flag trust key serves every
// folder (C4), so another workbench may still need it.
func RemoveCodex(_ context.Context, o WorkbenchInstallOptions) (SkillStatus, error) {
	if err := o.validateCodex(); err != nil {
		return SkillStatus{}, err
	}
	if !isDir(o.Folder) {
		return SkillStatus{}, codexFolderGone(o)
	}
	var errs []error
	var sk SkillStatus
	err := skillDirsInside(o.Folder, o.codexSkillsDir(), workbenchSkill(), flowSkill())
	if err == nil {
		if sk, err = removeSkill(o.codexSkillsDir(), workbenchSkill()); err != nil {
			errs = append(errs, err)
		}
		if _, err := removeSkill(o.codexSkillsDir(), flowSkill()); err != nil {
			errs = append(errs, err)
		}
		removeIfEmpty(o.codexSkillsDir())
		removeIfEmpty(filepath.Join(o.Folder, ".agents"))
	} else {
		errs = append(errs, err)
	}
	if _, err := dedupeImportedHooks(o.Folder, o.WorkbenchID); err != nil {
		errs = append(errs, err)
	}
	if err := RemoveGitExclude(o.Folder, goneExcludeLines(o.Folder, codexExcludeLines)); err != nil {
		errs = append(errs, err)
	}
	return sk, errors.Join(errs...)
}

// StatusCodex reports the codex part, writing nothing. An app-server that
// cannot be asked leaves HooksTrusted nil; every trust failure is reported
// in TrustError; a malformed .codex hook file reads as ImportedDuplicates
// when it names our commands. A folder without the skill copy (never set up
// for codex) is not asked about trust — the answer is unused — so Found
// comes from resolve alone and no app-server starts. Only a bad option or a
// gone folder is an error.
func StatusCodex(ctx context.Context, o WorkbenchInstallOptions, resolve func() error, srv func() (codex.AppServer, error)) (CodexStatus, error) {
	if err := o.validateCodex(); err != nil {
		return CodexStatus{}, err
	}
	if !isDir(o.Folder) {
		return CodexStatus{}, codexFolderGone(o)
	}
	var st CodexStatus
	sk, err := statusSkill(o.codexSkillsDir(), workbenchSkill())
	if err != nil {
		return CodexStatus{}, err
	}
	st.SkillState = sk.State
	st.GroupPrompt = skillKnowsGroupPrompt(sk.Path)
	// An outdated copy (StateUpdated: a previously shipped version) is set
	// up and needs a Repair, not "never set up"; SkillState says which.
	st.Skill = sk.State != StateMissing
	st.ImportedDuplicates = hasImportedDuplicates(o.Folder, o.WorkbenchID)
	// Status reports, it does not fail: the trust failure goes on the wire.
	var trustErr error
	if sk.State == StateMissing {
		st.Found, trustErr = codexResolved(resolve)
	} else {
		st.HooksTrusted, st.Found, trustErr = trustCodexHooks(ctx, o, srv, false)
	}
	if trustErr != nil {
		st.TrustError = trustErr.Error()
	}
	return st, nil
}

// codexResolved is resolve's answer as trustCodexHooks gives it: no codex
// (ErrCodexNotFound) is no error.
func codexResolved(resolve func() error) (found bool, err error) {
	switch err := resolve(); {
	case err == nil:
		return true, nil
	case errors.Is(err, ErrCodexNotFound):
		return false, nil
	default:
		return false, err
	}
}

// ResolveCodex is StatusCodex's resolve: nil when a codex binary resolves
// (cfg's codex_path, else find), else why not.
func ResolveCodex(cfg *config.Config, find func() (string, error)) error {
	_, err := resolveCodexBinary(cfg, find)
	return err
}

// trustCodexHooks asks the app-server srv starts which of our hooks are
// trusted and, with write, trusts the rest. trusted is nil when codex could
// not be asked; found is false only when no codex binary was resolved
// (ErrCodexNotFound is no error, ErrCodexUnresolved is).
func trustCodexHooks(ctx context.Context, o WorkbenchInstallOptions, srv func() (codex.AppServer, error), write bool) (trusted *bool, found bool, err error) {
	s, err := srv()
	switch {
	case errors.Is(err, ErrCodexNotFound):
		return nil, false, nil
	case errors.Is(err, ErrCodexUnresolved):
		return nil, false, err
	}
	if err != nil {
		return nil, true, err
	}
	trusted, err = askCodexTrust(ctx, o, s, write)
	if cerr := s.Close(); cerr != nil && err == nil {
		return nil, true, cerr
	}
	return trusted, true, err
}

func askCodexTrust(ctx context.Context, o WorkbenchInstallOptions, s codex.AppServer, write bool) (*bool, error) {
	entries, err := s.ListHooks(ctx, o.Folder)
	if err != nil {
		return nil, err
	}
	matched, missing := codex.MatchSessionFlagHooks(entries, codexHookRefs(o.Bin))
	untrusted := slices.DeleteFunc(slices.Clone(matched), codex.HookEntry.Trusted)
	if write && len(untrusted) > 0 {
		if err := s.TrustHooks(ctx, untrusted); err != nil {
			return nil, err
		}
		untrusted = nil
	}
	ok := len(missing) == 0 && len(untrusted) == 0
	if len(missing) > 0 {
		return &ok, fmt.Errorf("codex did not list %d of the %d workbench hooks (first: %s %q); this codex version may not support them",
			len(missing), len(missing)+len(matched), missing[0].Event, missing[0].Command)
	}
	return &ok, nil
}

func (o WorkbenchInstallOptions) validateCodex() error {
	switch {
	case o.WorkbenchID <= 0:
		return fmt.Errorf("workbench id must be positive, got %d", o.WorkbenchID)
	case !filepath.IsAbs(o.Folder):
		return fmt.Errorf("workbench folder must be an absolute path, got %q", o.Folder)
	case o.Bin == "":
		return errors.New("the watchtower binary path is empty")
	}
	return nil
}

func (o WorkbenchInstallOptions) codexSkillsDir() string {
	return filepath.Join(o.Folder, ".agents", "skills")
}

func codexFolderGone(o WorkbenchInstallOptions) error {
	return fmt.Errorf("workbench folder %s no longer exists; if it comes back, run 'watchtower integrate codex --workbench %d --remove'",
		o.Folder, o.WorkbenchID)
}

// --- imported duplicates (spec §4.4) ---

func codexHooksJSONPath(folder string) string {
	return filepath.Join(folder, ".codex", "hooks.json")
}

func codexConfigTOMLPath(folder string) string {
	return filepath.Join(folder, ".codex", "config.toml")
}

// malformedFileError is a hook file we refuse to read; it is
// ErrMalformedSettings for errors.Is, named after its own file.
type malformedFileError struct{ file, reason string }

func (e *malformedFileError) Error() string { return "malformed " + e.file + ": " + e.reason }
func (e *malformedFileError) Unwrap() error { return ErrMalformedSettings }

// ourHookSuffixes are the command tails that mark a hook as the workbench's
// own: every Claude hook of workbenchID (current and pre-rename spellings)
// and every codex hook.
func ourHookSuffixes(workbenchID int64) []string {
	var out []string
	for _, spec := range ownedHookSpecs {
		out = append(out, spec.suffix(workbenchID))
		if l := spec.legacySuffix(workbenchID); l != "" {
			out = append(out, l)
		}
	}
	for _, r := range codexHookRows {
		out = append(out, " "+r.suffix)
	}
	return out
}

// isOurImportedHook reports whether hook object h runs one of our commands
// (with any watchtower binary, I2).
func isOurImportedHook(h any, workbenchID int64) bool {
	cmd, ok := hookCommand(h)
	if !ok {
		return false
	}
	return slices.ContainsFunc(ourHookSuffixes(workbenchID), func(s string) bool { return endsInOurCommand(cmd, s) })
}

// dedupeImportedHooks removes our hook commands from the folder's
// .codex/hooks.json and the [hooks] of .codex/config.toml, keeping every
// other entry and key. A file left empty that held only ours is deleted
// (and .codex with it once empty). A malformed file is never written
// (ErrMalformedSettings); config.toml is edited in place, line by line, so
// the owner's comments and layout survive, or not at all
// (ErrCodexHooksNotEditable). A file that is a symlink leaving the folder is
// neither written nor removed (ErrSymlinkOutsideFolder).
func dedupeImportedHooks(folder string, workbenchID int64) (changed bool, err error) {
	jsonChanged, jsonErr := dedupeCodexHooksJSON(folder, codexHooksJSONPath(folder), workbenchID)
	tomlChanged, tomlErr := dedupeCodexConfigTOML(folder, codexConfigTOMLPath(folder), workbenchID)
	if jsonChanged || tomlChanged {
		removeIfEmpty(filepath.Join(folder, ".codex"))
	}
	return jsonChanged || tomlChanged, errors.Join(jsonErr, tomlErr)
}

// hasImportedDuplicates reports whether either .codex hook file still names
// our commands. A file that cannot be parsed is searched as text.
func hasImportedDuplicates(folder string, workbenchID int64) bool {
	for _, file := range []string{codexHooksJSONPath(folder), codexConfigTOMLPath(folder)} {
		raw, err := os.ReadFile(file)
		if err != nil {
			continue
		}
		hooks, perr := parseCodexHookFile(file, raw)
		if perr != nil {
			if rawNamesOurHook(raw, workbenchID) {
				return true
			}
			continue
		}
		if anyOurImportedHook(hooks, workbenchID) {
			return true
		}
	}
	return false
}

// rawNamesOurHook: one of our command tails followed by a closing quote.
func rawNamesOurHook(raw []byte, workbenchID int64) bool {
	for _, s := range ourHookSuffixes(workbenchID) {
		if bytes.Contains(raw, []byte(s+`"`)) || bytes.Contains(raw, []byte(s+`'`)) {
			return true
		}
	}
	return false
}

func anyOurImportedHook(hooks map[string]any, workbenchID int64) bool {
	for _, v := range hooks {
		groups, ok := v.([]any)
		if ok && anyHook(groups, func(h any) bool { return isOurImportedHook(h, workbenchID) }) {
			return true
		}
	}
	return false
}

// parseCodexHookFile decodes file's hooks table (nil when it has none).
func parseCodexHookFile(file string, raw []byte) (map[string]any, error) {
	var doc map[string]any
	var err error
	if strings.HasSuffix(file, ".toml") {
		doc, err = decodeTOML(file, raw)
	} else {
		doc, err = decodeJSONObject(file, raw)
	}
	if err != nil {
		return nil, err
	}
	return hooksTable(file, doc)
}

func decodeJSONObject(file string, raw []byte) (map[string]any, error) {
	if len(bytes.TrimSpace(raw)) == 0 {
		return map[string]any{}, nil
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var v any
	if err := dec.Decode(&v); err != nil {
		return nil, &malformedFileError{file, err.Error()}
	}
	if _, err := dec.Token(); !errors.Is(err, io.EOF) {
		return nil, &malformedFileError{file, "trailing data after the top-level object"}
	}
	obj, ok := v.(map[string]any)
	if !ok {
		return nil, &malformedFileError{file, "the top level is not an object"}
	}
	return obj, nil
}

func decodeTOML(file string, raw []byte) (map[string]any, error) {
	doc := map[string]any{}
	if err := toml.Unmarshal(raw, &doc); err != nil {
		return nil, &malformedFileError{file, err.Error()}
	}
	return doc, nil
}

func hooksTable(file string, doc map[string]any) (map[string]any, error) {
	raw, ok := doc["hooks"]
	if !ok {
		return nil, nil
	}
	hooks, ok := raw.(map[string]any)
	if !ok {
		return nil, &malformedFileError{file, `"hooks" is not a table`}
	}
	return hooks, nil
}

// withoutOurImportedHooks drops our hooks from every event's groups in
// place; changed reports whether any went. A value that is not an array of
// groups is not a hook event of ours and is kept.
func withoutOurImportedHooks(hooks map[string]any, workbenchID int64) bool {
	changed := false
	for event, v := range hooks {
		groups, ok := v.([]any)
		if !ok {
			continue
		}
		kept, ch := withoutHooks(groups, func(h any) bool { return isOurImportedHook(h, workbenchID) })
		if !ch {
			continue
		}
		changed = true
		if len(kept) == 0 {
			delete(hooks, event)
		} else {
			hooks[event] = kept
		}
	}
	return changed
}

func dedupeCodexHooksJSON(folder, file string, workbenchID int64) (bool, error) {
	raw, err := os.ReadFile(file)
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("reading %s: %w", file, err)
	}
	doc, err := decodeJSONObject(file, raw)
	if err != nil {
		return false, err
	}
	hooks, err := hooksTable(file, doc)
	if err != nil || hooks == nil {
		return false, err
	}
	if !withoutOurImportedHooks(hooks, workbenchID) {
		return false, nil
	}
	if len(hooks) == 0 {
		delete(doc, "hooks")
	}
	target, err := resolveSymlinkInside(file, folder)
	if err != nil {
		return false, err
	}
	if len(doc) == 0 {
		if err := os.Remove(file); err != nil {
			return false, fmt.Errorf("removing %s: %w", file, err)
		}
		return true, nil
	}
	return true, writeSettings(target, doc, filePerm(file, 0o644))
}

func dedupeCodexConfigTOML(folder, file string, workbenchID int64) (bool, error) {
	raw, err := os.ReadFile(file)
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("reading %s: %w", file, err)
	}
	doc, err := decodeTOML(file, raw)
	if err != nil {
		return false, err
	}
	hooks, err := hooksTable(file, doc)
	if err != nil || hooks == nil {
		return false, err
	}
	edited, err := editTOMLWithoutOurHooks(string(raw), hooks, workbenchID)
	if err != nil || edited == string(raw) {
		return false, err
	}
	// The line edit must remove exactly our hooks and nothing else.
	expect := cloneTOMLDoc(doc)
	expectHooks, _ := expect["hooks"].(map[string]any)
	withoutOurImportedHooks(expectHooks, workbenchID)
	got, err := decodeTOML(file, []byte(edited))
	if err != nil {
		return false, fmt.Errorf("%w (%s): the edit does not parse: %w", ErrCodexHooksNotEditable, file, err)
	}
	if !reflect.DeepEqual(normalizeHooksDoc(got), normalizeHooksDoc(expect)) {
		return false, fmt.Errorf("%w (%s)", ErrCodexHooksNotEditable, file)
	}
	target, err := resolveSymlinkInside(file, folder)
	if err != nil {
		return false, err
	}
	if onlyEmptyHooksTable(edited) {
		if err := os.Remove(file); err != nil {
			return false, fmt.Errorf("removing %s: %w", file, err)
		}
		return true, nil
	}
	return true, atomicWriteFile(target, []byte(edited), filePerm(file, 0o644))
}

// cloneTOMLDoc deep-copies a decoded document's maps and slices.
func cloneTOMLDoc(doc map[string]any) map[string]any {
	out := make(map[string]any, len(doc))
	for k, v := range doc {
		out[k] = cloneTOMLValue(v)
	}
	return out
}

func cloneTOMLValue(v any) any {
	switch t := v.(type) {
	case map[string]any:
		return cloneTOMLDoc(t)
	case []any:
		out := make([]any, len(t))
		for i, e := range t {
			out[i] = cloneTOMLValue(e)
		}
		return out
	default:
		return v
	}
}

// normalizeHooksDoc drops an empty hooks table: a bare [hooks] header left
// in the text and no hooks key at all mean the same.
func normalizeHooksDoc(doc map[string]any) map[string]any {
	if h, ok := doc["hooks"].(map[string]any); ok && len(h) == 0 {
		delete(doc, "hooks")
	}
	return doc
}

// onlyEmptyHooksTable: nothing is left but blank lines and a bare [hooks]
// header, so the file held only our hooks.
func onlyEmptyHooksTable(text string) bool {
	for _, l := range strings.Split(text, "\n") {
		l = strings.TrimSpace(l)
		if l != "" && l != "[hooks]" {
			return false
		}
	}
	return true
}

// tomlHookHeader matches [[hooks.<Event>]] (a hook group) and
// [[hooks.<Event>.hooks]] (a handler of the last group), with an optional
// trailing comment.
var tomlHookHeader = regexp.MustCompile(`^\[\[\s*hooks\s*\.\s*"?([A-Za-z]+)"?\s*(\.\s*hooks\s*)?\]\]\s*(#.*)?$`)

// tomlSection is one table's lines, [start, end), from its header up to the
// next header.
type tomlSection struct {
	start, end int
	event      string // "" for a table that is not a hook group or handler
	handler    bool
}

// tomlSections splits lines into the preamble (start 0, no header) and one
// section per table header. Lines inside a multi-line string never start a
// section.
func tomlSections(lines []string) []tomlSection {
	secs := []tomlSection{{start: 0}}
	inString := ""
	for i, l := range lines {
		t := strings.TrimSpace(l)
		if inString == "" && strings.HasPrefix(t, "[") {
			secs[len(secs)-1].end = i
			sec := tomlSection{start: i}
			if m := tomlHookHeader.FindStringSubmatch(t); m != nil {
				sec.event, sec.handler = m[1], m[2] != ""
			}
			secs = append(secs, sec)
		}
		inString = multilineStringState(l, inString)
	}
	secs[len(secs)-1].end = len(lines)
	return secs
}

// multilineStringState tracks whether a line leaves a multi-line string
// (three double or three single quotes) open: the delimiter still open, or
// "".
func multilineStringState(line, open string) string {
	for {
		if open != "" {
			i := strings.Index(line, open)
			if i < 0 {
				return open
			}
			line, open = line[i+3:], ""
			continue
		}
		dq, sq := strings.Index(line, `"""`), strings.Index(line, `'''`)
		switch {
		case dq < 0 && sq < 0:
			return ""
		case sq < 0 || (dq >= 0 && dq < sq):
			line, open = line[dq+3:], `"""`
		default:
			line, open = line[sq+3:], `'''`
		}
	}
}

// editTOMLWithoutOurHooks removes, as whole line ranges, every handler
// table that is ours and every group table left with no handler. It edits
// only events written as [[hooks.<Event>]] / [[hooks.<Event>.hooks]] tables
// whose count matches the decoded document; anything else holding our hooks
// is ErrCodexHooksNotEditable.
func editTOMLWithoutOurHooks(text string, hooks map[string]any, workbenchID int64) (string, error) {
	lines := strings.SplitAfter(text, "\n")
	secs := tomlSections(lines)
	drop := map[int]bool{} // section index → removed
	for event, v := range hooks {
		groups, ok := v.([]any)
		if !ok || !anyHook(groups, func(h any) bool { return isOurImportedHook(h, workbenchID) }) {
			continue
		}
		if err := markOurHookSections(secs, event, groups, workbenchID, drop); err != nil {
			return "", err
		}
	}
	var b strings.Builder
	for i, s := range secs {
		if !drop[i] {
			b.WriteString(strings.Join(lines[s.start:s.end], ""))
		}
	}
	return b.String(), nil
}

// markOurHookSections marks event's handler sections that are ours, and
// group sections left empty, in drop.
func markOurHookSections(secs []tomlSection, event string, groups []any, workbenchID int64, drop map[int]bool) error {
	byGroup := hookSectionsByGroup(secs, event)
	if len(byGroup) != len(groups) {
		return fmt.Errorf("%w: hooks.%s is not written as [[hooks.%s]] tables", ErrCodexHooksNotEditable, event, event)
	}
	for g, idx := range byGroup {
		_, hs, ok := groupHooks(groups[g])
		if !ok || len(idx)-1 != len(hs) {
			return fmt.Errorf("%w: the handlers of hooks.%s are not written as [[hooks.%s.hooks]] tables", ErrCodexHooksNotEditable, event, event)
		}
		ours := 0
		for j, h := range hs {
			if isOurImportedHook(h, workbenchID) {
				drop[idx[j+1]] = true
				ours++
			}
		}
		if ours == len(hs) {
			drop[idx[0]] = true
		}
	}
	return nil
}

// hookSectionsByGroup lists, per [[hooks.<event>]] group in order, the
// group's section index followed by its handler sections' indexes.
func hookSectionsByGroup(secs []tomlSection, event string) [][]int {
	var out [][]int
	for i, s := range secs {
		switch {
		case s.event != event:
		case !s.handler:
			out = append(out, []int{i})
		case len(out) > 0:
			out[len(out)-1] = append(out[len(out)-1], i)
		}
	}
	return out
}
