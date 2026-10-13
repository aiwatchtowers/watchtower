package devpack

import (
	"fmt"
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
// with an optionally single-quoted bin whose basename is "watchtower".
func isOurCleanupRule(rule any) bool {
	s, ok := rule.(string)
	if !ok {
		return false
	}
	rest, ok := strings.CutPrefix(s, cleanupRulePrefix)
	if !ok {
		return false
	}
	bin, ok := strings.CutSuffix(rest, cleanupRuleSuffix)
	return ok && bin != "" && filepath.Base(unquoteShellSingle(bin)) == "watchtower"
}

// allowRules returns settings' permissions object (a fresh one when absent,
// not yet attached) and its allow list, refusing a shape it does not know:
// the file is then never written (PROJ-04).
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

// InstallCleanupPermission adds the cleanup allow rule for bin to dir's
// .claude/settings.local.json (PROJ-04): appended when no rule of ours is
// there, a stale-bin rule of ours replaced in place, a duplicate of ours
// dropped. The owner's allow and deny entries and every other key are never
// touched or reordered; an exact match is a no-op.
func InstallCleanupPermission(dir, bin string) (bool, error) {
	file := settingsLocalPath(dir)
	settings, mode, _, err := readSettings(file)
	if err != nil {
		return false, err
	}
	perms, allow, err := allowRules(settings, file)
	if err != nil {
		return false, err
	}
	updated, changed := upsertCleanupRule(allow, cleanupAllowRule(bin))
	if !changed {
		return false, nil
	}
	perms["allow"] = updated
	settings["permissions"] = perms
	return true, writeSettings(file, settings, mode)
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
// file left empty are dropped, as RemoveSessionStartHook does.
func RemoveCleanupPermission(dir string) (bool, error) {
	file := settingsLocalPath(dir)
	settings, mode, existed, err := readSettings(file)
	if err != nil || !existed {
		return false, err
	}
	perms, allow, err := allowRules(settings, file)
	if err != nil {
		return false, err
	}
	kept := slices.DeleteFunc(slices.Clone(allow), isOurCleanupRule)
	if len(kept) == len(allow) {
		return false, nil
	}
	if len(kept) == 0 {
		delete(perms, "allow")
	} else {
		perms["allow"] = kept
	}
	if len(perms) == 0 {
		delete(settings, "permissions")
	} else {
		settings["permissions"] = perms
	}
	return true, writeOrDropSettings(file, settings, mode)
}

// HasCleanupPermission reports whether a cleanup allow rule of ours, from
// any watchtower binary, is in dir's .claude/settings.local.json.
func HasCleanupPermission(dir string) (bool, error) {
	file := settingsLocalPath(dir)
	settings, _, existed, err := readSettings(file)
	if err != nil || !existed {
		return false, err
	}
	_, allow, err := allowRules(settings, file)
	if err != nil {
		return false, err
	}
	return slices.ContainsFunc(allow, isOurCleanupRule), nil
}
