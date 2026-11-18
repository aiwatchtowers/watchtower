package aiconsent

import (
	"errors"
	"fmt"
	"io/fs"
	"log"
	"os"
	"strings"
	"sync"

	"gopkg.in/yaml.v3"

	"watchtower/internal/policy"
)

// Reader returns the current consent state. Components take one injected for
// tests; a nil Reader means Current, never "ungated".
type Reader func() State

// logf is where read failures go (watchtower.log in the daemon); tests swap it.
var logf = log.Printf

// parseHook runs on every parse of the config file; tests count parses.
var parseHook = func() {}

// cur is the config read: the path, the mtime cache and the last logged
// failure.
var cur struct {
	mu       sync.Mutex
	path     string
	override Reader
	info     fs.FileInfo // stat of the parsed file; nil = no cached parse
	answer   Answer
	lastFail string
}

// SetConfigPath points Current at config.yaml and drops the cache. With no
// path set, Current reads paused (fail closed).
func SetConfigPath(path string) {
	cur.mu.Lock()
	defer cur.mu.Unlock()
	cur.path, cur.info, cur.answer = path, nil, AnswerNone
}

// SetCurrentOverrideForTest is for tests only: while r is non-nil, Current
// returns r() instead of reading the config. Production code never calls it
// (TestOverrideHookOnlyInTests); test packages use aiconsenttest.
func SetCurrentOverrideForTest(r Reader) {
	cur.mu.Lock()
	defer cur.mu.Unlock()
	cur.override = r
}

// Current resolves the owner's answer in config.yaml with the forced policy.
// It stats the file on every call and re-parses only when the file changed.
// An unreadable or unparsable file, an unknown value, or no config path at
// all read as paused.
func Current() State {
	cur.mu.Lock()
	if r := cur.override; r != nil {
		cur.mu.Unlock()
		return r()
	}
	answer, hasPath := readAnswerLocked()
	cur.mu.Unlock()

	allow := policy.Current().Keys.AllowBackgroundAI
	s := Resolve(answer, allow)
	if !hasPath && s.Allowed() {
		// A process that never learned its config path cannot know the
		// owner's answer, so even a permissive profile reads paused.
		s = Resolve(AnswerNone, nil)
		s.Policy = allow
	}
	return s
}

// readAnswerLocked returns the cached answer, re-parsing when the file's
// identity, mtime or size changed. Holds cur.mu.
func readAnswerLocked() (Answer, bool) {
	if cur.path == "" {
		return AnswerNone, false
	}
	st, err := os.Stat(cur.path)
	if err != nil {
		cur.info, cur.answer = nil, AnswerNone
		if errors.Is(err, fs.ErrNotExist) {
			// Not written yet: the owner has not answered. Not a failure.
			cur.lastFail = ""
		} else {
			noteFailureLocked(fmt.Sprintf("aiconsent: cannot read %s (%v); background AI reads as paused", cur.path, err))
		}
		return AnswerNone, true
	}
	if prev := cur.info; prev != nil && os.SameFile(prev, st) &&
		prev.ModTime().Equal(st.ModTime()) && prev.Size() == st.Size() {
		return cur.answer, true
	}
	parseHook()
	answer, fail := parseAnswer(cur.path)
	cur.info, cur.answer = st, answer
	if fail != "" {
		noteFailureLocked(fail)
	} else {
		cur.lastFail = ""
	}
	return answer, true
}

// noteFailureLocked logs msg once per distinct failure. Holds cur.mu.
func noteFailureLocked(msg string) {
	if msg == cur.lastFail {
		return
	}
	cur.lastFail = msg
	logf("%s", msg)
}

// parseAnswer reads ai.background_runs from the file. Keys match without
// regard to case, as viper reads them. fail is the message to log, "" when
// the file read cleanly (an absent key included).
func parseAnswer(path string) (Answer, string) {
	data, err := os.ReadFile(path)
	if err != nil {
		return AnswerNone, fmt.Sprintf("aiconsent: cannot read %s (%v); background AI reads as paused", path, err)
	}
	var root map[string]any
	if err := yaml.Unmarshal(data, &root); err != nil {
		return AnswerNone, fmt.Sprintf("aiconsent: cannot parse %s (%v); background AI reads as paused", path, err)
	}
	aiMap, _ := lookupFold(root, "ai").(map[string]any)
	raw := lookupFold(aiMap, "background_runs")
	if raw == nil {
		return AnswerNone, ""
	}
	if s, ok := raw.(string); ok {
		if a, known := ParseAnswer(s); known {
			return a, ""
		}
	}
	return AnswerNone, fmt.Sprintf(`aiconsent: ai.background_runs = %v in %s is not "allowed" or "paused"; background AI reads as not answered (paused)`, raw, path)
}

func lookupFold(m map[string]any, key string) any {
	if v, ok := m[key]; ok {
		return v
	}
	for k, v := range m {
		if strings.EqualFold(k, key) {
			return v
		}
	}
	return nil
}
