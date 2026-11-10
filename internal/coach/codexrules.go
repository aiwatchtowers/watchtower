package coach

import (
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
)

// The Codex rules destination: <codexHome>/rules/default.rules, the file Codex
// itself appends an approved command's prefix_rule to. The coach only appends
// lines from codexSafeAllowPatterns, the Codex form of safeAllowVerbs; Rollback
// removes only the lines its proposal added.
//
// Format (checked 2026-11-10 against openai/codex): the rules are Starlark,
// loaded from <CODEX_HOME>/rules/*.rules (codex-rs/core/src/exec_policy.rs:
// RULES_DIR_NAME "rules", DEFAULT_POLICY_FILE "default.rules"); Codex's own
// "always allow" writes one line per rule, format!(r#"prefix_rule(pattern={pattern},
// decision="allow")"#) with pattern = "[" + JSON-quoted tokens joined by ", " + "]",
// newline-terminated (codex-rs/execpolicy/src/amend.rs,
// blocking_append_allow_prefix_rule). CodexRuleLine writes the same bytes, so
// a rule Codex already appended is seen as present. A prefix_rule matches any
// command that starts with the pattern's tokens, like Bash(<verb>:*).

var errCodexRulesMissing = errors.New("the Codex rules file does not exist")

// codexSafeAllowPatterns is safeAllowVerbs in Codex form; a test keeps the two
// equal.
var codexSafeAllowPatterns = [][]string{{"cat"}, {"ls"}, {"grep"}, {"head"}, {"tail"},
	{"go", "test"}, {"go", "build"}, {"go", "vet"}, {"swift", "test"}, {"swift", "build"},
	{"cargo", "test"}, {"npm", "test"}, {"pytest"}}

// codexSafeAllowLines is the set of CodexRuleLine of every table entry.
var codexSafeAllowLines = func() map[string]bool {
	m := map[string]bool{}
	for _, p := range codexSafeAllowPatterns {
		m[CodexRuleLine(p)] = true
	}
	return m
}()

// CodexRuleLine is the allow rule for pattern as Codex writes it:
// prefix_rule(pattern=["go", "test"], decision="allow").
func CodexRuleLine(pattern []string) string {
	quoted := make([]string, len(pattern))
	for i, tok := range pattern {
		b, _ := json.Marshal(tok) // a string always marshals
		quoted[i] = string(b)
	}
	return fmt.Sprintf(`prefix_rule(pattern=[%s], decision="allow")`, strings.Join(quoted, ", "))
}

// CodexSafeAllowRule is whether line is exactly CodexRuleLine of an entry of
// codexSafeAllowPatterns.
func CodexSafeAllowRule(line string) bool { return codexSafeAllowLines[line] }

// codexRulesPath is <codexHome>/rules/default.rules.
func codexRulesPath(e Env) string { return filepath.Join(e.codexHome(), "rules", "default.rules") }

var codexRulesKind = textFile{label: "default.rules", tmp: ".default.rules.coach-*",
	notRegular: fmt.Errorf("default.rules %w", errUnsafeFile), tooBig: fmt.Errorf("default.rules %w", errUnsafeFile),
	changed: errors.New("default.rules changed while it was being written"), missing: errCodexRulesMissing}

// appendCodexRules is text with the lines of add appended, each
// newline-terminated as Codex appends them.
func appendCodexRules(text, add string) string {
	if text != "" && !strings.HasSuffix(text, "\n") {
		text += "\n"
	}
	return text + add + "\n"
}

// validateCodexRules checks a new text of the rules file: it is the old text
// plus whole lines, each a safe rule the file does not have yet.
func validateCodexRules(before, after string) error {
	added, ok := strings.CutPrefix(after, before)
	if !ok || (before != "" && !strings.HasSuffix(before, "\n") && added != "" && !strings.HasPrefix(added, "\n")) {
		return errors.New("the Codex rules may only grow")
	}
	have := countLines(nonEmptyLines(before))
	lines := nonEmptyLines(added)
	for _, l := range lines {
		if !CodexSafeAllowRule(l) {
			return fmt.Errorf("rule %q is not a safe read, search, build or test command", l)
		}
	}
	for _, l := range lines {
		if have[l] > 0 {
			return errors.New("the Codex rules already have every rule")
		}
		have[l]++
	}
	if len(lines) == 0 {
		return errors.New("the Codex rules already have every rule")
	}
	return nil
}

// removeCodexRules is text without one occurrence (the last) of each line of
// rules; every other byte stays.
func removeCodexRules(text string, rules []string) string {
	lines := strings.SplitAfter(text, "\n")
	for _, r := range rules {
		for i := len(lines) - 1; i >= 0; i-- {
			if strings.TrimSpace(lines[i]) == r {
				lines = append(lines[:i], lines[i+1:]...)
				break
			}
		}
	}
	return strings.Join(lines, "")
}
