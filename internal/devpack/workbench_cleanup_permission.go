package devpack

import (
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
)

// The cleanup permission (spec 2026-10-12-session-cleanup §10, PROJ-04): one
// `permissions.allow` string in .claude/settings.local.json letting the
// session's agent run `watchtower workbench cleanup` in auto mode without a
// prompt. Nothing broader is ever allowed: the rule names exactly the
// absolute binary and the cleanup subcommand.
const (
	cleanupRulePrefix = "Bash("
	cleanupRuleSuffix = " workbench cleanup:*)"
)

// cleanupAllowRule is the allow rule for bin, quoted the way the hook
// commands quote it (shellQuote), so it matches CleanupCommand's text.
func cleanupAllowRule(bin string) string {
	return cleanupRulePrefix + shellQuote(bin) + cleanupRuleSuffix
}

// CleanupCommand is the exact command the session brief names for sessionID
// (`<bin> workbench cleanup --session <id>`): the one cleanupAllowRule
// matches.
func CleanupCommand(bin string, sessionID int64) string {
	return shellQuote(bin) + " workbench cleanup --session " + strconv.FormatInt(sessionID, 10)
}

// isOurCleanupRule reports whether rule is a cleanup allow rule of ours,
// whichever watchtower binary wrote it: `Bash(<bin> workbench cleanup:*)`
// whose bin — optionally single-quoted — is an absolute path with the
// basename "watchtower". A bare or relative form
// (`Bash(watchtower workbench cleanup:*)`) is never one we write, so it is
// the owner's and is never rewritten or removed.
func isOurCleanupRule(rule any) bool {
	s, ok := rule.(string)
	if !ok {
		return false
	}
	rest, ok := strings.CutPrefix(s, cleanupRulePrefix)
	if !ok {
		return false
	}
	quoted, ok := strings.CutSuffix(rest, cleanupRuleSuffix)
	if !ok {
		return false
	}
	bin := unquoteShellSingle(quoted)
	return filepath.IsAbs(bin) && filepath.Base(bin) == "watchtower"
}

// allowRules returns settings' permissions object (a fresh one when absent,
// not yet attached) and its allow list, refusing a shape it does not know:
// the file is then never written (PROJ-04). checkOwnedShapes runs it for
// every hook step too, so a file this step refuses is refused by all.
func allowRules(settings map[string]any, file string) (map[string]any, []any, error) {
	perms := map[string]any{}
	if raw, ok := settings["permissions"]; ok {
		m, isObj := raw.(map[string]any)
		if !isObj {
			return nil, nil, fmt.Errorf("%w: %s: \"permissions\" is not an object", ErrMalformedSettings, file)
		}
		perms = m
	}
	raw, ok := perms["allow"]
	if !ok {
		return perms, nil, nil
	}
	allow, isArr := raw.([]any)
	if !isArr {
		return nil, nil, fmt.Errorf("%w: %s: \"permissions.allow\" is not an array", ErrMalformedSettings, file)
	}
	return perms, allow, nil
}

// beforeCleanupRuleWrite runs between the first read and the re-read that
// the write is based on; a test seam, a no-op otherwise.
var beforeCleanupRuleWrite = func() {}

// editCleanupRules applies edit, a change to our one allow rule, to dir's
// .claude/settings.local.json. Claude Code writes the same file (an
// "always allow" answer adds an allow rule), and nothing locks it, so the
// read-modify-write window is kept short: the first read only decides
// whether anything is to change, then the file is read again and the edit
// applied to that fresh copy right before the atomic write. An entry we did
// not add is never dropped; only a write landing within that last instant
// can still be lost.
func editCleanupRules(dir string, edit func([]any) ([]any, bool), write func(string, map[string]any, os.FileMode) error) (bool, error) {
	file := settingsLocalPath(dir)
	if _, _, changed, err := editedAllow(file, edit); err != nil || !changed {
		return false, err
	}
	beforeCleanupRuleWrite()
	settings, mode, changed, err := editedAllow(file, edit)
	if err != nil || !changed {
		return false, err
	}
	return true, write(file, settings, mode)
}

// editedAllow reads file and returns its settings with edit applied to
// permissions.allow; an allow list and then a permissions object left empty
// are dropped. The whole file's shape is checked first (checkOwnedShapes).
func editedAllow(file string, edit func([]any) ([]any, bool)) (map[string]any, os.FileMode, bool, error) {
	settings, mode, _, err := readSettings(file)
	if err != nil {
		return nil, 0, false, err
	}
	if err := checkOwnedShapes(settings, file); err != nil {
		return nil, 0, false, err
	}
	perms, allow, err := allowRules(settings, file)
	if err != nil {
		return nil, 0, false, err
	}
	updated, changed := edit(allow)
	if !changed {
		return settings, mode, false, nil
	}
	if len(updated) == 0 {
		delete(perms, "allow")
	} else {
		perms["allow"] = updated
	}
	if len(perms) == 0 {
		delete(settings, "permissions")
	} else {
		settings["permissions"] = perms
	}
	return settings, mode, true, nil
}

// InstallCleanupPermission adds the cleanup allow rule for bin to dir's
// .claude/settings.local.json (PROJ-04): appended when no rule of ours is
// there, a stale-bin rule of ours replaced in place, a duplicate of ours
// dropped. The owner's allow and deny entries and every other key are never
// touched or reordered; an exact match is a no-op.
func InstallCleanupPermission(dir, bin string) (bool, error) {
	want := cleanupAllowRule(bin)
	return editCleanupRules(dir, func(allow []any) ([]any, bool) {
		return upsertCleanupRule(allow, want)
	}, writeSettings)
}

// upsertCleanupRule sets the first rule of ours to want and drops any
// further one; absent any, want is appended. changed is false only when
// exactly one rule of ours already read want.
func upsertCleanupRule(allow []any, want string) ([]any, bool) {
	out := make([]any, 0, len(allow)+1)
	found, changed := false, false
	for _, r := range allow {
		switch {
		case !isOurCleanupRule(r):
			out = append(out, r)
		case found:
			changed = true // a duplicate of ours
		default:
			found = true
			changed = changed || r != want
			out = append(out, want)
		}
	}
	if !found {
		out = append(out, want)
		changed = true
	}
	return out, changed
}

// RemoveCleanupPermission removes every cleanup allow rule of ours from
// dir's .claude/settings.local.json (PROJ-02/04), whichever binary wrote it;
// the owner's rules stay. An allow list, a permissions object and finally a
// file left empty are dropped, as RemoveSessionStartHook does. A missing
// file is left missing.
func RemoveCleanupPermission(dir string) (bool, error) {
	return editCleanupRules(dir, withoutCleanupRules, writeOrDropSettings)
}

func withoutCleanupRules(allow []any) ([]any, bool) {
	kept := slices.DeleteFunc(slices.Clone(allow), isOurCleanupRule)
	return kept, len(kept) != len(allow)
}

// HasCleanupPermission reports whether a cleanup allow rule of ours, from
// any watchtower binary, is in dir's .claude/settings.local.json.
func HasCleanupPermission(dir string) (bool, error) {
	file := settingsLocalPath(dir)
	settings, _, existed, err := readSettings(file)
	if err != nil || !existed {
		return false, err
	}
	if err := checkOwnedShapes(settings, file); err != nil {
		return false, err
	}
	_, allow, err := allowRules(settings, file)
	if err != nil {
		return false, err
	}
	return slices.ContainsFunc(allow, isOurCleanupRule), nil
}
