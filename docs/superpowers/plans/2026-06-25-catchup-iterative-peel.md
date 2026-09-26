# Catch-up iterative peel-off — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single aggressive-merge catch-up `outline` AI call with a sequential peel-off loop that extracts one theme per round until the model says only noise remains, removing the artificial 3–8 theme ceiling.

**Architecture:** `gather` (raised caps) → `peel` loop [sequential, light model: one theme per round, claimed items removed from the pool] with per-theme `expand` dispatched concurrently as themes are peeled → leftover (model-judged noise) marked read. The existing `expand`, `Acknowledge`, and feedback/`learn` passes are unchanged.

**Tech Stack:** Go 1.25, `modernc.org/sqlite`, `internal/digest` Generator interface (mocked in tests), goose migrations (none needed here).

## Global Constraints

- Module path: `watchtower`. Go 1.25.
- Every catch-up AI call MUST route through `p.withLanguage(...)` — invariant **CATCHUP-02** (`docs/inventory/catchup.md`). The new peel prompt is included.
- Per-theme expand failures MUST stay isolated (`gen_state='failed'`, run continues) — invariant **CATCHUP-03**.
- `Acknowledge` cascade behaviour (snapshot refs + digest decisions, idempotent) MUST NOT change — invariant **CATCHUP-01**. Leftover mark-read reuses the same primitives but is a separate path.
- Refs returned by the model are validated against the gathered snapshot; ids never in the input are dropped (existing rule, preserved).
- Test naming convention `TestCatchupNN_...` is load-bearing (inventory guard lists); keep it.
- Run `gofmt`, `go vet`, `go build ./...`, and `go test ./internal/catchup/ ./internal/config/ ./internal/digest/ ./internal/codex/` green before each commit.

---

## File Structure

- `internal/digest/models.go` — add `catchup.peel` to light tier. `internal/codex/models.go` — mirror.
- `internal/config/config.go` — raise `catchup.caps.*` defaults.
- `internal/catchup/types.go` — replace `outlineResult`/`outlineTheme`/`parseOutline` with `peelResult`/`peelTheme`/`parsePeel`.
- `internal/catchup/prompt.go` — replace `outlineSystemPrompt`/`buildOutlineUserMessage` with `peelSystemPrompt`/`buildPeelUserMessage`.
- `internal/catchup/pipeline.go` — replace `outline` with the `peel` loop; add leftover mark-read; extract `markAreaRead` helper shared with `Acknowledge`.
- `internal/catchup/pipeline_test.go` — migrate outline-based tests to peel; add new behaviour tests.
- `docs/inventory/catchup.md` — update narrative wording + changelog (contracts unchanged except CATCHUP-02 test extended).

---

## Task 1: Route `catchup.peel` to the light model tier

**Files:**
- Modify: `internal/digest/models.go:12`
- Modify: `internal/codex/models.go:15`
- Test: `internal/digest/models_test.go`, `internal/codex/models_test.go`

**Interfaces:**
- Produces: source tag string `"catchup.peel"` resolves to `ModelHaiku` (digest) / `ModelLightweight` (codex).

- [ ] **Step 1: Write the failing test (digest)**

In `internal/digest/models_test.go`, inside the lightweight-sources test (the loop asserting `ModelHaiku`), add `"catchup.peel"` to the list of sources expected to return `ModelHaiku`. If the test uses an explicit slice, add the entry:

```go
for _, src := range []string{SourceLight, "inbox.prioritize", "digest.period", "digest.channel_batch", "people.batch", "catchup.peel"} {
    if got := ModelForSource(src); got != ModelHaiku {
        t.Errorf("ModelForSource(%q) = %q, want %q", src, got, ModelHaiku)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/digest/ -run TestModelForSource -v`
Expected: FAIL — `ModelForSource("catchup.peel") = "claude-sonnet-4-6", want "claude-haiku-4-5-20251001"`

- [ ] **Step 3: Implement (digest)**

In `internal/digest/models.go`, add `"catchup.peel"` to the `case` line:

```go
	case SourceLight, "inbox.prioritize", "digest.period", "digest.channel_batch", "people.batch", "catchup.peel":
		return ModelHaiku
```

- [ ] **Step 4: Mirror for codex (test + impl)**

In `internal/codex/models_test.go`, add `"catchup.peel"` to the lightweight-sources assertion (mirrors the digest test). In `internal/codex/models.go`, add `"catchup.peel"` to the `case`:

```go
	case digest.SourceLight, "inbox.prioritize", "digest.period", "digest.channel_batch", "people.batch", "catchup.peel":
		return ModelLightweight
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `go test ./internal/digest/ ./internal/codex/ -run TestModelForSource -v`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add internal/digest/models.go internal/digest/models_test.go internal/codex/models.go internal/codex/models_test.go
git commit -m "feat(catchup): route catchup.peel to light model tier"
```

---

## Task 2: Raise gather caps

**Files:**
- Modify: `internal/config/config.go:208-211`
- Test: `internal/config/config_test.go` (add a defaults test if none exists for catchup caps)

**Interfaces:**
- Produces: default `catchup.caps` = digests 150, tracks 80, inbox 120, briefings 20.

- [ ] **Step 1: Write the failing test**

Add to `internal/config/config_test.go` (use the existing Load/Default helper pattern in that file; if the file loads config via `Load("")` or similar, follow it). Minimal version using the same constructor the other config tests use:

```go
func TestCatchupCapsDefaults(t *testing.T) {
	cfg, err := Load("") // match the loader used by neighbouring tests in this file
	if err != nil {
		t.Fatal(err)
	}
	got := cfg.Catchup.Caps
	want := CatchupCaps{Digests: 150, Tracks: 80, Inbox: 120, Briefings: 20}
	if got != want {
		t.Fatalf("catchup caps = %+v, want %+v", got, want)
	}
}
```

> If `Load` has a different signature in this repo, read one neighbouring test in `config_test.go` and copy its setup verbatim; the assertion block stays the same.

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/config/ -run TestCatchupCapsDefaults -v`
Expected: FAIL — caps are the old 40/20/30/5.

- [ ] **Step 3: Implement**

In `internal/config/config.go`, change the four defaults:

```go
	v.SetDefault("catchup.caps.digests", 150)
	v.SetDefault("catchup.caps.tracks", 80)
	v.SetDefault("catchup.caps.inbox", 120)
	v.SetDefault("catchup.caps.briefings", 20)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/config/ -run TestCatchupCapsDefaults -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add internal/config/config.go internal/config/config_test.go
git commit -m "feat(catchup): raise gather caps for peel-off pool"
```

---

## Task 3: Peel result type + prompt + parser

**Files:**
- Modify: `internal/catchup/types.go` (replace outline types with peel types)
- Modify: `internal/catchup/prompt.go` (replace outline prompt/builder with peel)
- Test: `internal/catchup/types_test.go` (create) for `parsePeel`

**Interfaces:**
- Produces:
  - `type peelTheme struct { Title string; Priority string; Refs []db.CatchupRef }`
  - `type peelResult struct { Theme *peelTheme `json:"theme"`; Done bool `json:"done"` }`
  - `func parsePeel(raw string) (peelResult, error)`
  - `const peelSystemPrompt string`
  - `func buildPeelUserMessage(sections []gatheredSection, targetsLine string) string`

- [ ] **Step 1: Write the failing test**

Create `internal/catchup/types_test.go`:

```go
package catchup

import "testing"

func TestParsePeel_Theme(t *testing.T) {
	raw := "```json\n{\"theme\":{\"title\":\"Payments\",\"priority\":\"high\",\"refs\":[{\"area\":\"digests\",\"id\":1,\"label\":\"C1\"}]}}\n```"
	got, err := parsePeel(raw)
	if err != nil {
		t.Fatal(err)
	}
	if got.Done {
		t.Fatal("expected Done=false")
	}
	if got.Theme == nil || got.Theme.Title != "Payments" || got.Theme.Priority != "high" {
		t.Fatalf("theme = %+v", got.Theme)
	}
	if len(got.Theme.Refs) != 1 || got.Theme.Refs[0].Area != "digests" || got.Theme.Refs[0].ID != 1 {
		t.Fatalf("refs = %+v", got.Theme.Refs)
	}
}

func TestParsePeel_Done(t *testing.T) {
	got, err := parsePeel(`{"done": true}`)
	if err != nil {
		t.Fatal(err)
	}
	if !got.Done {
		t.Fatal("expected Done=true")
	}
	if got.Theme != nil {
		t.Fatalf("expected nil theme, got %+v", got.Theme)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/catchup/ -run TestParsePeel -v`
Expected: FAIL — `parsePeel` / `peelResult` undefined.

- [ ] **Step 3: Implement types + parser**

In `internal/catchup/types.go`, **remove** `outlineResult`, `outlineTheme`, and `parseOutline`, and add:

```go
// peelTheme is the single theme the peel pass extracts in one round.
type peelTheme struct {
	Title    string          `json:"title"`
	Priority string          `json:"priority"`
	Refs     []db.CatchupRef `json:"refs"`
}

// peelResult is one peel round's output: either the next theme, or done=true
// when only noise/trivia remains in the pool.
type peelResult struct {
	Theme *peelTheme `json:"theme"`
	Done  bool       `json:"done"`
}

// parsePeel extracts the peel-round object, tolerating markdown fences.
func parsePeel(raw string) (peelResult, error) {
	var out peelResult
	s := trimToJSONObject(raw)
	if err := json.Unmarshal([]byte(s), &out); err != nil {
		return peelResult{}, fmt.Errorf("parsing catchup peel output: %w", err)
	}
	return out, nil
}
```

Update the package doc comment at the top of `types.go` (line ~2-5): replace "A cheap outline pass clusters them into thematic skeletons" with "A sequential peel pass extracts one thematic skeleton per round".

- [ ] **Step 4: Implement prompt + builder**

In `internal/catchup/prompt.go`, **remove** `outlineSystemPrompt` and `buildOutlineUserMessage`, and add:

```go
// peelSystemPrompt drives one round of the sequential peel pass: from the
// remaining unread pool, extract the single most important coherent theme, or
// signal done when only noise is left. The narrative is written later (expand).
const peelSystemPrompt = `You are a chief-of-staff catching the operator up on everything they missed while away.

You receive the operator's CURRENTLY-REMAINING unread items grouped by source (digests, tracks, inbox, briefings). Each item has a stable numeric id within its area. Items you already grouped in earlier rounds are gone from this list.

Your job: identify the SINGLE most important coherent theme still in the pool — one real-world topic that may span multiple sources — and return ONLY that theme. Pull in every remaining item that genuinely belongs to it (across sources); leave everything else for later rounds. Do not force unrelated items together.

If what remains is only noise, chatter, or trivia not worth its own catch-up theme, return {"done": true} instead of a theme.

When you return a theme, produce ONLY a skeleton (the narrative is written later):
- title: short, concrete (e.g. "Payments migration blocked on infra review").
- priority: "high" | "medium" | "low".
- refs: the remaining source items that belong to this theme, each as {area, id, label}. Use ONLY ids that appear in the input above. Never invent ids. label is a short human-readable name for the item.

Respond with ONLY a JSON object, no markdown fences. Either:
{"theme": {"title": "...", "priority": "high", "refs": [{"area": "tracks", "id": 1, "label": "..."}]}}
or:
{"done": true}`

// buildPeelUserMessage renders the remaining unread pool (and optional targets
// context) into one peel round's user message.
func buildPeelUserMessage(sections []gatheredSection, targetsLine string) string {
	var b strings.Builder
	if targetsLine != "" {
		b.WriteString("TARGETS CONTEXT (read-only): ")
		b.WriteString(targetsLine)
		b.WriteString("\n\n")
	}
	for _, s := range sections {
		if len(s.items) == 0 {
			continue
		}
		fmt.Fprintf(&b, "=== %s (%d remaining) ===\n", strings.ToUpper(s.area), len(s.items))
		for _, it := range s.items {
			fmt.Fprintf(&b, "[id=%d] %s — %s\n", it.ID, it.Title, oneLine(it.Snippet))
		}
		b.WriteString("\n")
	}
	return b.String()
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `go test ./internal/catchup/ -run TestParsePeel -v`
Expected: PASS (the package may still fail to BUILD because `pipeline.go` references the removed `outline` symbols — that is fixed in Task 4. To verify just this task, temporarily expect the parse tests to compile within the test binary; if the package does not build yet, proceed to Task 4 and run Step 5 there.)

> Note: Tasks 3 and 4 form one compilable unit (removing outline breaks `pipeline.go`). Commit them together at the end of Task 4 if the package does not build standalone after Task 3.

---

## Task 4: Replace `outline` with the `peel` loop

**Files:**
- Modify: `internal/catchup/pipeline.go` (replace `outline`+`validateRefs`; add `peel`, `markAreaRead`, leftover handling; update `Run`)
- Test: `internal/catchup/pipeline_test.go` (migrate + add)

**Interfaces:**
- Consumes: `parsePeel`, `peelSystemPrompt`, `buildPeelUserMessage` (Task 3); `catchup.peel` source tag (Task 1).
- Produces:
  - `func (p *Pipeline) peel(ctx context.Context, sessionID int64, g gatherResult) (themes []db.CatchupTheme, leftover []refKey, stoppedClean bool, fatal error)`
  - `func (p *Pipeline) markAreaRead(area string, id int) error`
  - `const maxPeelRounds = 25`

- [ ] **Step 1: Migrate existing outline-based tests to peel**

In `internal/catchup/pipeline_test.go`:

(a) Replace the `twoThemeOutline` constant and every `strings.HasPrefix(system, outlineSystemPrompt)` branch. Define a peel helper that returns N themes then done, keyed off the peel system prompt. Add near the top of the test file:

```go
// peelScript returns a mock fn that emits the given theme JSONs one per peel
// round (in order) and then {"done":true}; every non-peel call returns the
// supplied expand JSON. Round counting is safe because the peel loop is
// sequential and expand calls take the else branch.
func peelScript(expand string, themesJSON ...string) func(system, user string) string {
	round := 0
	return func(system, user string) string {
		if strings.HasPrefix(system, peelSystemPrompt) {
			i := round
			round++
			if i < len(themesJSON) {
				return themesJSON[i]
			}
			return `{"done":true}`
		}
		return expand
	}
}

const expandOK = `{"narrative":"x","priority":"low","needs_you":false,"suggested_action":""}`
```

(b) `TestCatchup10_RunCreatesSessionWithSkeletonThemes`: replace the static `out` generator with a peel script returning two themes. Seed a second unread digest so the second theme has a valid ref (the model may only ref remaining ids):

```go
func TestCatchup10_RunCreatesSessionWithSkeletonThemes(t *testing.T) {
	d := db.OpenTestDB(t)
	seedUnreadDigest(t, d) // id=1
	seedUnreadDigest(t, d) // id=2
	gen := &mockGenerator{fn: peelScript(expandOK,
		`{"theme":{"title":"First theme","priority":"high","refs":[{"area":"digests","id":1,"label":"channel digest C1"}]}}`,
		`{"theme":{"title":"Second theme","priority":"low","refs":[{"area":"digests","id":2,"label":"d2"}]}}`,
	)}

	sessionID, err := New(d, newCfg(), gen, testLogger()).Run(context.Background())
	// ...unchanged assertions: gen.called, sessionID!=0, active session, TotalThemes==2,
	// themes[0].Title=="First theme" OrderIdx 0, themes[1].Title=="Second theme" OrderIdx 1,
	// themes[0].Priority=="high", themes[0] refs == digests#1.
}
```

(c) `TestCatchup12_OutlineInjectsLearnedPreferences` → rename references: keep the function name (guard convention is per-module, but this is not in an inventory guard list — safe to keep name or rename to `..._PeelInjects...`; **keep the name** to minimise churn). Change the branch to `strings.HasPrefix(system, peelSystemPrompt)`, capture `peelUser`, return a one-theme peel JSON for round 0 then done. Assertions on `LEARNED PREFERENCES` and the scope key are unchanged.

(d) `TestCatchup13_PromptsCarryLanguageDirective`: change the outline branch to `peelSystemPrompt`; return a one-theme JSON on the first peel call then `{"done":true}`. **Add** an explicit assertion that at least one captured `system` starts with `peelSystemPrompt` AND contains the directive, so the peel prompt is covered (CATCHUP-02). Keep the expand assertion.

(e) `TestCatchup20`, `TestCatchup21`, `TestCatchup22`, `TestCatchup25`: replace the `outlineSystemPrompt` branch with a `peelScript(...)` that yields the same number of themes those tests expect (each seeded ref must be a distinct remaining id — seed extra digests as needed). The expand-side logic (failure injection in 21/25) stays in the non-peel branch.

- [ ] **Step 2: Add new behaviour tests**

Append to `internal/catchup/pipeline_test.go`:

```go
// TestCatchup26_PeelExtractsMoreThanEightThemes proves the old 3–8 ceiling is
// gone: ten unread digests, each its own theme, all ten survive.
func TestCatchup26_PeelExtractsMoreThanEightThemes(t *testing.T) {
	d := db.OpenTestDB(t)
	for i := 0; i < 10; i++ {
		seedUnreadDigest(t, d) // ids 1..10
	}
	themesJSON := make([]string, 10)
	for i := 0; i < 10; i++ {
		themesJSON[i] = `{"theme":{"title":"T` + strconv.Itoa(i+1) +
			`","priority":"medium","refs":[{"area":"digests","id":` + strconv.Itoa(i+1) + `}]}}`
	}
	gen := &mockGenerator{fn: peelScript(expandOK, themesJSON...)}

	sessionID, err := New(d, newCfg(), gen, testLogger()).Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	themes, err := d.ListCatchupThemes(sessionID)
	if err != nil {
		t.Fatal(err)
	}
	if len(themes) != 10 {
		t.Fatalf("got %d themes, want 10", len(themes))
	}
}

// TestCatchup27_DoneMarksLeftoverRead — when the model signals done with items
// still in the pool, those leftover items are marked read (noise auto-clear).
func TestCatchup27_DoneMarksLeftoverRead(t *testing.T) {
	d := db.OpenTestDB(t)
	seedUnreadDigest(t, d) // id=1 -> themed
	seedUnreadDigest(t, d) // id=2 -> leftover noise
	gen := &mockGenerator{fn: peelScript(expandOK,
		`{"theme":{"title":"Only one","priority":"high","refs":[{"area":"digests","id":1}]}}`,
	)}

	if _, err := New(d, newCfg(), gen, testLogger()).Run(context.Background()); err != nil {
		t.Fatal(err)
	}
	// digest id=2 was never themed; done => it must be marked read.
	_, total, err := d.GetUnreadDigests(40, 0)
	if err != nil {
		t.Fatal(err)
	}
	if total != 0 {
		t.Fatalf("unread digests after done = %d, want 0 (leftover should be read)", total)
	}
}

// TestCatchup28_SafetyCapLeavesLeftoverUnread — if the loop never sees done and
// hits the round cap, leftover stays unread (unprocessed, not noise).
func TestCatchup28_SafetyCapLeavesLeftoverUnread(t *testing.T) {
	d := db.OpenTestDB(t)
	// Seed maxPeelRounds+5 digests; script returns a fresh theme every round and
	// never says done, so the cap stops it with items still unclaimed.
	n := maxPeelRounds + 5
	for i := 0; i < n; i++ {
		seedUnreadDigest(t, d)
	}
	gen := &mockGenerator{fn: func(system, user string) string {
		if strings.HasPrefix(system, peelSystemPrompt) {
			// Always claim the lowest remaining id by scanning the user msg.
			id := firstID(user)
			return `{"theme":{"title":"t","priority":"low","refs":[{"area":"digests","id":` + strconv.Itoa(id) + `}]}}`
		}
		return expandOK
	}}

	if _, err := New(d, newCfg(), gen, testLogger()).Run(context.Background()); err != nil {
		t.Fatal(err)
	}
	_, total, err := d.GetUnreadDigests(200, 0)
	if err != nil {
		t.Fatal(err)
	}
	if total == 0 {
		t.Fatal("expected leftover digests to remain unread after hitting safety cap")
	}
}

// firstID returns the first [id=N] in a peel user message.
func firstID(user string) int {
	const marker = "[id="
	i := strings.Index(user, marker)
	if i < 0 {
		return 0
	}
	rest := user[i+len(marker):]
	j := strings.IndexByte(rest, ']')
	if j < 0 {
		return 0
	}
	n, _ := strconv.Atoi(rest[:j])
	return n
}

// TestCatchup29_MidLoopPeelErrorKeepsEarlierThemes — a parse failure on round 2
// keeps round 1's theme and leaves the session usable (not failed).
func TestCatchup29_MidLoopPeelErrorKeepsEarlierThemes(t *testing.T) {
	d := db.OpenTestDB(t)
	seedUnreadDigest(t, d) // id=1
	seedUnreadDigest(t, d) // id=2
	round := 0
	gen := &mockGenerator{fn: func(system, user string) string {
		if strings.HasPrefix(system, peelSystemPrompt) {
			round++
			if round == 1 {
				return `{"theme":{"title":"Kept","priority":"high","refs":[{"area":"digests","id":1}]}}`
			}
			return `not json at all` // round 2 fails -> stop, keep theme 1
		}
		return expandOK
	}}

	sessionID, err := New(d, newCfg(), gen, testLogger()).Run(context.Background())
	if err != nil {
		t.Fatalf("partial peel must not fail Run: %v", err)
	}
	sess, err := d.GetActiveCatchupSession()
	if err != nil {
		t.Fatal(err)
	}
	if sess == nil || sess.ID != sessionID {
		t.Fatalf("expected an active session, got %+v", sess)
	}
	themes, err := d.ListCatchupThemes(sessionID)
	if err != nil {
		t.Fatal(err)
	}
	if len(themes) != 1 || themes[0].Title != "Kept" {
		t.Fatalf("themes = %+v, want one 'Kept'", themes)
	}
	// leftover NOT marked read (error exit, not done).
	_, total, err := d.GetUnreadDigests(40, 0)
	if err != nil {
		t.Fatal(err)
	}
	if total == 0 {
		t.Fatal("leftover should remain unread on error exit")
	}
}

// TestCatchup33_ZeroThemesWithErrorFailsSession — first peel round errors before
// any theme is found => session is marked failed.
func TestCatchup33_ZeroThemesWithErrorFailsSession(t *testing.T) {
	d := db.OpenTestDB(t)
	seedUnreadDigest(t, d)
	gen := &mockGenerator{fn: func(system, user string) string {
		if strings.HasPrefix(system, peelSystemPrompt) {
			return `totally broken` // round 1 unparseable, zero themes so far
		}
		return expandOK
	}}

	sessionID, err := New(d, newCfg(), gen, testLogger()).Run(context.Background())
	if err == nil {
		t.Fatal("expected error when the first peel round fails with zero themes")
	}
	sess, err2 := d.GetCatchupSession(sessionID)
	if err2 != nil {
		t.Fatal(err2)
	}
	if sess.Status != "failed" {
		t.Fatalf("session status = %q, want failed", sess.Status)
	}
}
```

> Before using `d.GetCatchupSession(sessionID)` in `TestCatchup33`, confirm a single-session getter exists in `internal/db`; if the getter is named differently (e.g. `GetCatchupSessionByID`), use that. Otherwise assert via the absence of an *active* session (`GetActiveCatchupSession` returns nil for a failed session).

- [ ] **Step 3: Run the tests to verify they fail**

Run: `go test ./internal/catchup/ -run 'TestParsePeel|TestCatchup' -v`
Expected: FAIL/BUILD ERROR — `peel`, `markAreaRead`, `maxPeelRounds` undefined; `outline` symbols removed.

- [ ] **Step 4: Implement the peel loop in `pipeline.go`**

In `internal/catchup/pipeline.go`:

(a) Update the `Pipeline` doc comment (lines ~16-18): replace "gather → outline (skeletons) → expand" with "gather → peel (one theme per round) → expand".

(b) **Replace** the `outline` func and `validateRefs` func with the following. Add `maxPeelRounds`. Keep `gather`, `expand`, `expandOne`, `failTheme`, `resolveExpandSources`, `Acknowledge`, etc.

```go
// maxPeelRounds bounds the sequential peel loop. It is a runaway guard, not a
// theme ceiling: the loop normally stops when the model returns {"done":true}.
const maxPeelRounds = 25

// peel runs the sequential peel-off loop. Each round sends the remaining unread
// pool to the light model, which returns the single most important theme or
// {"done":true}. A returned theme's refs are validated against the pool,
// persisted as a skeleton, and its expand is dispatched concurrently; the
// claimed items are removed from the pool. The loop stops on done, an empty
// pool, the safety cap, or a round error.
//
// Returns the persisted themes (in discovery order), the leftover pool keys, and
// stoppedClean=true only when the loop ended via done or empty pool (so the
// caller may mark leftover read). fatal is non-nil ONLY when a round errored
// before any theme was found, so the caller can fail the session.
func (p *Pipeline) peel(ctx context.Context, sessionID int64, g gatherResult) (themes []db.CatchupTheme, leftover []refKey, stoppedClean bool, fatal error) {
	prefs := p.catchupPrefs()
	targets := p.targetsLine()

	claimed := make(map[refKey]bool)

	workers := p.cfg.AI.Workers
	if workers <= 0 {
		workers = config.DefaultAIWorkers
	}
	sem := make(chan struct{}, workers)
	var wg sync.WaitGroup
	defer wg.Wait() // ensure all dispatched expands finish before returning

	orderIdx := 0
	for round := 0; round < maxPeelRounds; round++ {
		sections := unclaimedSections(g.sections, claimed)
		if sectionsEmpty(sections) {
			stoppedClean = true
			break
		}

		user := buildPeelUserMessage(sections, targets)
		if prefs != "" {
			user = prefs + "\n" + user
		}
		raw, _, _, err := p.gen.Generate(digest.WithSource(ctx, "catchup.peel"), p.withLanguage(peelSystemPrompt), user, "")
		if err != nil {
			p.logf("catchup: peel round %d AI error: %v", round, err)
			if len(themes) == 0 {
				fatal = fmt.Errorf("catchup peel: %w", err)
			}
			return themes, unclaimedKeys(g, claimed), false, fatal
		}
		parsed, err := parsePeel(raw)
		if err != nil {
			p.logf("catchup: peel round %d parse error: %v", round, err)
			if len(themes) == 0 {
				fatal = err
			}
			return themes, unclaimedKeys(g, claimed), false, fatal
		}
		if parsed.Done || parsed.Theme == nil {
			stoppedClean = true
			break
		}

		refs := p.validatePeelRefs(parsed.Theme.Refs, g, claimed)
		if len(refs) == 0 {
			// No valid new refs: the loop would not make progress. Treat the
			// remaining pool as noise and stop cleanly.
			p.logf("catchup: peel round %d produced no valid new refs; stopping", round)
			stoppedClean = true
			break
		}

		refsJSON, err := json.Marshal(refs)
		if err != nil {
			return themes, unclaimedKeys(g, claimed), false, fmt.Errorf("encoding theme refs: %w", err)
		}
		t := db.CatchupTheme{
			SessionID: sessionID,
			OrderIdx:  orderIdx,
			Title:     parsed.Theme.Title,
			Priority:  normalizePriority(parsed.Theme.Priority, "medium"),
			RefsJSON:  string(refsJSON),
			GenState:  "skeleton",
		}
		id, err := p.db.InsertCatchupTheme(t)
		if err != nil {
			return themes, unclaimedKeys(g, claimed), false, fmt.Errorf("inserting peel theme: %w", err)
		}
		t.ID = id
		themes = append(themes, t)
		orderIdx++
		for _, r := range refs {
			claimed[refKey{area: r.Area, id: r.ID}] = true
		}

		// Dispatch expand concurrently so the narrative is written while the next
		// peel round runs. Per-theme failure is isolated by expandOne (CATCHUP-03).
		wg.Add(1)
		go func(theme db.CatchupTheme) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			_ = p.expandOne(ctx, theme, "", prefs)
		}(t)
	}

	return themes, unclaimedKeys(g, claimed), stoppedClean, nil
}

// validatePeelRefs keeps only refs that are in the gathered snapshot and not
// already claimed by an earlier round, filling a fallback label when omitted.
func (p *Pipeline) validatePeelRefs(refs []db.CatchupRef, g gatherResult, claimed map[refKey]bool) []db.CatchupRef {
	out := make([]db.CatchupRef, 0, len(refs))
	for _, r := range refs {
		k := refKey{area: r.Area, id: r.ID}
		item, ok := g.byRef[k]
		if !ok {
			p.logf("catchup: dropping peel ref to unknown item %s#%d", r.Area, r.ID)
			continue
		}
		if claimed[k] {
			p.logf("catchup: dropping peel ref to already-claimed item %s#%d", r.Area, r.ID)
			continue
		}
		if r.Label == "" {
			r.Label = refLabel(r.Area, item)
		}
		out = append(out, r)
	}
	return out
}

// unclaimedSections rebuilds per-area sections from the gathered snapshot minus
// the claimed items, preserving the original area and item order.
func unclaimedSections(src []gatheredSection, claimed map[refKey]bool) []gatheredSection {
	out := make([]gatheredSection, 0, len(src))
	for _, s := range src {
		var items []db.UnreadItem
		for _, it := range s.items {
			if !claimed[refKey{area: s.area, id: it.ID}] {
				items = append(items, it)
			}
		}
		out = append(out, gatheredSection{area: s.area, items: items, total: len(items)})
	}
	return out
}

func sectionsEmpty(sections []gatheredSection) bool {
	for _, s := range sections {
		if len(s.items) > 0 {
			return false
		}
	}
	return true
}

// unclaimedKeys returns every gathered (area,id) not yet claimed by a theme.
func unclaimedKeys(g gatherResult, claimed map[refKey]bool) []refKey {
	out := make([]refKey, 0)
	for k := range g.byRef {
		if !claimed[k] {
			out = append(out, k)
		}
	}
	return out
}
```

(c) **Update `Run`** to call `peel` and handle leftover. Replace the body between session creation and `SetCatchupSessionStatus(active)`:

```go
	themes, leftover, stoppedClean, err := p.peel(ctx, sessionID, g)
	if err != nil {
		if serr := p.db.SetCatchupSessionStatus(sessionID, "failed"); serr != nil {
			p.logf("catchup: marking session %d failed: %v", sessionID, serr)
		}
		return sessionID, err
	}
	if err := p.db.SetCatchupSessionTotals(sessionID, len(themes)); err != nil {
		return sessionID, err
	}
	// peel already dispatched + waited on every expand (its deferred wg.Wait).
	if stoppedClean {
		p.markLeftoverRead(leftover)
	}
	if err := p.db.SetCatchupSessionStatus(sessionID, "active"); err != nil {
		return sessionID, err
	}
	return sessionID, nil
```

Remove the old `outline` call, the `SetCatchupSessionTotals`-after-outline block, and the standalone `p.expand(ctx, themes)` call from `Run` (expand is now dispatched inside `peel`). **Delete** the now-unused `expand` method (the batch fan-out) — its body moved into the peel loop. Keep `expandOne`, `failTheme`.

> If any other caller uses `Pipeline.expand`, keep it; grep first: `grep -rn "\.expand(" internal/`. Per current code only `Run` calls it, so it is safe to delete.

(d) Add `markLeftoverRead` + extract `markAreaRead` (shared with `Acknowledge`):

```go
// markAreaRead marks a single source item read in its own surface. Digests
// cascade their decisions read (CATCHUP-01). Shared by Acknowledge and the
// peel leftover-noise sweep.
func (p *Pipeline) markAreaRead(area string, id int) error {
	switch area {
	case "digests":
		return p.db.MarkDigestRead(id)
	case "tracks":
		return p.db.MarkTrackRead(id)
	case "inbox":
		return p.db.MarkInboxRead(id)
	case "briefings":
		return p.db.MarkBriefingRead(id)
	default:
		return fmt.Errorf("unknown area %q", area)
	}
}

// markLeftoverRead marks the pool items the model judged noise (loop ended via
// done/empty) read, so catch-up actually clears the backlog. Best-effort: a
// per-item error is logged and skipped.
func (p *Pipeline) markLeftoverRead(leftover []refKey) {
	for _, k := range leftover {
		if err := p.markAreaRead(k.area, k.id); err != nil {
			p.logf("catchup: leftover mark-read %s#%d: %v", k.area, k.id, err)
		}
	}
}
```

(e) Refactor `Acknowledge`'s inline area switch to call `markAreaRead` (behaviour identical, keeps CATCHUP-01 green):

```go
	for _, r := range refs {
		if err := p.markAreaRead(r.Area, r.ID); err != nil {
			p.logf("catchup: theme %d ack mark-read %s#%d: %v", themeID, r.Area, r.ID, err)
		}
	}
```

- [ ] **Step 5: Run the full catchup suite to verify it passes**

Run: `go test ./internal/catchup/ -v`
Expected: PASS — all migrated `TestCatchup10..25`, `TestCatchup30..32`, new `26..29,33`, and `TestParsePeel*`.

- [ ] **Step 6: Build + vet the whole module**

Run: `gofmt -l internal/catchup/ && go vet ./internal/catchup/ && go build ./...`
Expected: no gofmt output, no vet errors, build OK.

- [ ] **Step 7: Commit (Tasks 3 + 4 together)**

```bash
git add internal/catchup/
git commit -m "feat(catchup): replace outline with sequential peel-off loop

One theme extracted per round until the model signals done; claimed items
removed from the pool, expand dispatched concurrently. Removes the 3-8 theme
ceiling. Leftover noise marked read on clean exit; left unread on error/cap.
Preserves CATCHUP-01/02/03."
```

---

## Task 5: Update inventory + project docs

**Files:**
- Modify: `docs/inventory/catchup.md`
- Test: none (docs) — run the catchup suite once more as a guard.

- [ ] **Step 1: Update the inventory narrative + changelog**

In `docs/inventory/catchup.md`:
- In **What it is** (line ~16), replace "clusters them into a small set of non-overlapping cross-source **themes** (cheap outline pass)" with "extracts cross-source **themes** one per round in a sequential peel-off pass (light model), removing the old 3–8 ceiling".
- Under **CATCHUP-02** test guards, note the guard now also asserts the **peel** prompt carries the directive.
- Add a changelog entry:

```markdown
- 2026-06-25: outline pass replaced by a sequential peel-off loop (one theme per
  round until the model returns {"done":true}); removed the 3–8 theme ceiling and
  raised gather caps. CATCHUP-02 guard extended to cover the new `peelSystemPrompt`.
  New behaviour: pool items the model judges noise (clean/done exit) are marked
  read; on error/safety-cap exit leftover stays unread. Contracts CATCHUP-01/03
  unchanged.
```

- [ ] **Step 2: Guard run**

Run: `go test ./internal/catchup/ -run 'TestCatchup1[34]|TestCatchup2[14]' -v`
Expected: PASS (the inventory-guarded tests).

- [ ] **Step 3: Commit**

```bash
git add docs/inventory/catchup.md
git commit -m "docs(catchup): record peel-off replacing outline in inventory"
```

---

## Self-Review

**Spec coverage:**
- Raised caps → Task 2. ✓
- peel loop (sequential, one theme/round, done signal, safety cap) → Task 3 (prompt/parse) + Task 4 (loop). ✓
- expand reused + dispatched concurrently → Task 4 (peel dispatches; old `expand` removed). ✓
- Leftover: done→mark read, cap/error→leave → Task 4 (`markLeftoverRead`, `stoppedClean`). ✓
- Error handling: mid-loop partial, zero-theme→failed → Tasks 4 tests 29 & 33. ✓
- Model routing `catchup.peel`→light, both providers → Task 1. ✓
- CATCHUP-02 peel prompt carries directive → Task 4 test 13. ✓
- CATCHUP-01 unchanged + helper extraction → Task 4 (e). ✓
- Inventory/doc update → Task 5. ✓
- Desktop out of scope → no task. ✓

**Placeholder scan:** the only deferred items are two "confirm the getter/loader signature in this repo" notes (config `Load`, `GetCatchupSession`) with explicit fallbacks — resolve by reading one neighbouring call site, not by guessing.

**Type consistency:** `peelResult{Theme *peelTheme, Done bool}`, `parsePeel`, `peelSystemPrompt`, `buildPeelUserMessage`, `peel(...) (themes, leftover, stoppedClean, fatal)`, `markAreaRead`, `markLeftoverRead`, `maxPeelRounds=25`, `unclaimedSections`/`sectionsEmpty`/`unclaimedKeys`, `validatePeelRefs` — names used consistently across Tasks 3–5.
