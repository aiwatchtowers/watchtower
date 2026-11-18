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

// SetConfigPath points Current at config.yaml and drops the cache; it
// returns the previous path. With no path set, Current reads paused (fail
// closed).
func SetConfigPath(path string) (prev string) {
	cur.mu.Lock()
	defer cur.mu.Unlock()
	prev = cur.path
	cur.path, cur.info, cur.answer = path, nil, AnswerNone
	return prev
}

// SetCurrentOverrideForTest is for tests only: while r is non-nil, Current
// returns r() instead of reading the config. Production code never calls it
// (TestOverrideHookOnlyInTests); test packages use aiconsenttest. It
// returns the previous override.
func SetCurrentOverrideForTest(r Reader) (prev Reader) {
	cur.mu.Lock()
	defer cur.mu.Unlock()
	prev = cur.override
	cur.override = r
	return prev
}

// Current resolves the owner's answer in config.yaml with the forced policy.
// It stats the file on every call and re-parses only when the file changed.
// No config path, or a file that exists but cannot be read or parsed, reads
// paused whatever the profile says (fail closed). A missing file is "not
// answered"; an unknown value reads as not answered (logged once).
func Current() State {
	cur.mu.Lock()
	if r := cur.override; r != nil {
		cur.mu.Unlock()
		return r()
	}
	answer, known := readAnswerLocked()
	cur.mu.Unlock()

	allow := policy.Current().Keys.AllowBackgroundAI
	s := Resolve(answer, allow)
	if !known && s.Allowed() {
		// The owner's answer cannot be known, so even a permissive profile
		// (which stands in only for an owner who has not answered) reads
		// paused.
		s = Resolve(AnswerNone, nil)
		s.Policy = allow
	}
	return s
}

// readAnswerLocked returns the owner's answer; known = false when it cannot
// be known (no path, or a file that cannot be read or parsed). A clean read
// is cached and re-parsed only when the file's identity, mode, mtime or size
// changed; a failed read is never cached, so the next call retries. Holds
// cur.mu.
func readAnswerLocked() (answer Answer, known bool) {
	if cur.path == "" {
		return AnswerNone, false
	}
	st, err := os.Stat(cur.path)
	if err != nil {
		cur.info, cur.answer = nil, AnswerNone
		if errors.Is(err, fs.ErrNotExist) {
			// Not written yet: the owner has not answered. Not a failure.
			cur.lastFail = ""
			return AnswerNone, true
		}
		noteFailureLocked(fmt.Sprintf("aiconsent: cannot read %s (%v); background AI reads as paused", cur.path, err))
		return AnswerNone, false
	}
	if prev := cur.info; prev != nil && os.SameFile(prev, st) && prev.Mode() == st.Mode() &&
		prev.ModTime().Equal(st.ModTime()) && prev.Size() == st.Size() {
		return cur.answer, true
	}
	parseHook()
	answer, msg, failed := parseAnswer(cur.path)
	if failed {
		cur.info, cur.answer = nil, AnswerNone
		noteFailureLocked(msg)
		return AnswerNone, false
	}
	cur.info, cur.answer = st, answer
	if msg != "" {
		noteFailureLocked(msg)
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
// regard to case, as viper reads them. failed = the file could not be read or
// parsed, or a key is set more than once in different case; msg is the line to log ("" for a clean read, an absent key
// included; set for an unknown value, which reads as not answered).
func parseAnswer(path string) (a Answer, msg string, failed bool) {
	data, err := os.ReadFile(path)
	if err != nil {
		return AnswerNone, fmt.Sprintf("aiconsent: cannot read %s (%v); background AI reads as paused", path, err), true
	}
	var root map[string]any
	if err := yaml.Unmarshal(data, &root); err != nil {
		return AnswerNone, fmt.Sprintf("aiconsent: cannot parse %s (%v); background AI reads as paused", path, err), true
	}
	ai, ok := lookupFold(root, "ai")
	if !ok {
		return AnswerNone, ambiguousMsg("ai", path), true
	}
	aiMap, _ := ai.(map[string]any)
	raw, ok := lookupFold(aiMap, "background_runs")
	if !ok {
		return AnswerNone, ambiguousMsg("ai.background_runs", path), true
	}
	if raw == nil {
		return AnswerNone, "", false
	}
	if s, ok := raw.(string); ok {
		if a, known := ParseAnswer(s); known {
			return a, "", false
		}
	}
	return AnswerNone, fmt.Sprintf(`aiconsent: ai.background_runs = %v in %s is not "allowed" or "paused"; background AI reads as not answered`, raw, path), false
}

// lookupFold finds key without regard to case, as viper reads keys. More than
// one key that matches (`AI` and `Ai`, or `ai` and `AI`) is ambiguous: viper
// and the Desktop could pick different ones, so it is an error and the answer
// reads as paused (fail closed). The Desktop's ConfigService.foldKey is the
// twin. ok = false when ambiguous.
func lookupFold(m map[string]any, key string) (v any, ok bool) {
	var (
		found any
		n     int
	)
	for k, v := range m {
		if strings.EqualFold(k, key) {
			found = v
			n++
		}
	}
	if n > 1 {
		return nil, false
	}
	return found, true
}

// ErrAmbiguousConfig refuses a config.yaml write while the file holds the
// background AI answer's section or key more than once in different case:
// viper would fold them into one and could persist an answer the owner never
// gave (fail closed, #1886).
var ErrAmbiguousConfig = errors.New("config.yaml sets ai or ai.background_runs more than once in different case")

// CheckUnambiguous reports ErrAmbiguousConfig (wrapped with the key) when
// data, a config.yaml's bytes, holds `ai` or `ai.background_runs` more than
// once without regard to case. Bytes that do not parse are not its concern
// (the reader reports them): nil.
func CheckUnambiguous(data []byte) error {
	var root map[string]any
	if err := yaml.Unmarshal(data, &root); err != nil {
		return nil
	}
	ai, ok := lookupFold(root, "ai")
	if !ok {
		return fmt.Errorf("%w: fix the duplicate ai section first", ErrAmbiguousConfig)
	}
	aiMap, _ := ai.(map[string]any)
	if _, ok := lookupFold(aiMap, "background_runs"); !ok {
		return fmt.Errorf("%w: fix the duplicate ai.background_runs key first", ErrAmbiguousConfig)
	}
	return nil
}

func ambiguousMsg(key, path string) string {
	return fmt.Sprintf("aiconsent: %s appears more than once in %s (keys differing only in case); background AI reads as paused", key, path)
}
