# Digest-Compare Span Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Select compare-window episodes by story span (min–max ref ts) instead of refs-in-window, and make the coverage metric span-based, so the compare report stops under-reporting memory coverage (spec: `docs/superpowers/specs/2026-07-20-digest-compare-span-fix-design.md`).

**Architecture:** One SQL change in `ListEpisodesForChannelWindow` (GROUP BY node + HAVING span-overlap), one plumbing change in `digest_compare.go` (spans out of `loadRenderEpisodes`, interval-based `splitCoverage`), one report tweak (span-semantics Coverage column + `Windows with episodes` aggregate). Instrument-only: no schema change, no prompt change, legacy tables untouched.

**Tech Stack:** Go 1.25, `modernc.org/sqlite` via `database/sql`, plain `go test`.

## Global Constraints

- Branch: `feature/memory-phase5` (current checkout — no worktree needed; verify with `git branch --show-current` before committing).
- `docs/inventory/memory.md` governs this area: MEM-01 render clause (ref validation) and MEM-05 (compare is a pure reader of `digests`/`digest_topics`) must not weaken; guard tests `TestMemory13_*`, `TestDigestCompare_LegacyTablesByteIdentical` must pass UNMODIFIED.
- Window bounds everywhere are exclusive-low / inclusive-high: `(from, to]`.
- Every commit message ends with:
  ```
  Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01Xo7jXEcJB3kQjpqR7Q4PvH
  ```

---

### Task 1: Span-overlap episode selection in `ListEpisodesForChannelWindow`

**Files:**
- Modify: `internal/db/memory.go:170-200` (`ListEpisodesForChannelWindow` — doc comment + query)
- Test: `internal/db/memory_test.go` (extend `TestListEpisodesForChannelWindow`, ~line 701)

**Interfaces:**
- Consumes: existing `memory_provenance` rows (`ProvenanceRow{NodeID, Scheme, ChannelID, TSRaw, TSUnix}`) and `memory_nodes.status`.
- Produces: `ListEpisodesForChannelWindow(channelID string, fromUnix, toUnix float64) ([]string, error)` — SAME signature, new semantics: node ids whose per-channel span `[MIN(ts_unix), MAX(ts_unix)]` overlaps `(from, to]`, sorted by node id. Task 2 relies on this returning span-overlapping episodes.

- [ ] **Step 1: Extend the failing test**

In `internal/db/memory_test.go`, inside `TestListEpisodesForChannelWindow` after the existing `mk(...)` fixtures, add span fixtures (multi-ref episodes whose individual refs miss the `(100,200]` window but whose span overlaps — and one whose span misses):

```go
	// Span fixtures: refs OUTSIDE (100,200] but story span overlapping it —
	// the 2026-07-20 instrument fix (episodes cite sparse key messages, so a
	// window falling between two cited refs must still select the episode).
	mk("ep_span", ProvenanceRow{NodeID: "ep_span", ChannelID: "C0AAA", TSRaw: "50", TSUnix: 50},
		ProvenanceRow{NodeID: "ep_span", ChannelID: "C0AAA", TSRaw: "250", TSUnix: 250})
	// Span entirely before the window (max == from is still OUT: bounds are (from,to]).
	mk("ep_span_before", ProvenanceRow{NodeID: "ep_span_before", ChannelID: "C0AAA", TSRaw: "40", TSUnix: 40},
		ProvenanceRow{NodeID: "ep_span_before", ChannelID: "C0AAA", TSRaw: "100", TSUnix: 100})
	// Span starting exactly at to (min == to is IN: inclusive-high).
	mk("ep_span_at_to", ProvenanceRow{NodeID: "ep_span_at_to", ChannelID: "C0AAA", TSRaw: "200", TSUnix: 200},
		ProvenanceRow{NodeID: "ep_span_at_to", ChannelID: "C0AAA", TSRaw: "300", TSUnix: 300})
	// Span crossing the window but in ANOTHER channel — per-channel spans only.
	mk("ep_span_other", ProvenanceRow{NodeID: "ep_span_other", ChannelID: "C0BBB", TSRaw: "50", TSUnix: 50},
		ProvenanceRow{NodeID: "ep_span_other", ChannelID: "C0BBB", TSRaw: "250", TSUnix: 250})
```

and change the expectation to:

```go
	// (100,200] with span semantics: ep_in (ref inside), ep_at_to (span
	// [200,200], min <= to), ep_span (span [50,250] crosses the window),
	// ep_span_at_to (span [200,300], min == to). Excluded: ep_before (span
	// [100,100], max == from), ep_span_before (max == from), ep_after,
	// ep_span_other/ep_other (other channel), ep_mail (scheme ref),
	// ep_tomb (tombstone).
	want := []string{"ep_at_to", "ep_in", "ep_span", "ep_span_at_to"}
```

Also update the test's doc comment (line ~697) to say: "the window query returns episodes whose per-channel provenance SPAN [min,max] overlaps (from,to]".

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/db/ -run TestListEpisodesForChannelWindow -v`
Expected: FAIL — `window ids = [ep_at_to ep_in], want [ep_at_to ep_in ep_span ep_span_at_to]` (refs-in-window query misses the span fixtures).

- [ ] **Step 3: Replace the query with span-overlap**

In `internal/db/memory.go`, replace the doc comment and query of `ListEpisodesForChannelWindow` (keep the signature and scan loop):

```go
// ListEpisodesForChannelWindow returns the distinct non-tombstone node ids
// whose per-channel provenance SPAN [MIN(ts_unix), MAX(ts_unix)] overlaps the
// window (fromUnix, toUnix] on channelID, sorted by node id. Span overlap —
// not ref-in-window — because episodes cite only sparse key messages while a
// story runs for days: a window falling between two cited refs still belongs
// to the story (the 2026-07-20 compare-instrument fix; see
// docs/superpowers/specs/2026-07-20-digest-compare-span-fix-design.md).
// Because provenance rows keep the raw scheme-prefixed ref in channel_id,
// passing a bare Slack channel_id naturally excludes the prefixed-scheme
// refs. The bound is exclusive-low / inclusive-high so adjacent windows tile
// without double-counting the boundary second: overlap means
// MIN(ts_unix) <= to AND MAX(ts_unix) > from.
func (db *DB) ListEpisodesForChannelWindow(channelID string, fromUnix, toUnix float64) ([]string, error) {
	rows, err := db.Query(`SELECT p.node_id
		FROM memory_provenance p
		JOIN memory_nodes n ON n.id = p.node_id
		WHERE p.channel_id = ? AND n.status != 'tombstone'
		GROUP BY p.node_id
		HAVING MIN(p.ts_unix) <= ? AND MAX(p.ts_unix) > ?
		ORDER BY p.node_id`, channelID, toUnix, fromUnix)
```

CAREFUL with the parameter order: `channelID, toUnix, fromUnix` (to feeds the MIN bound, from feeds the MAX bound). The rest of the function (rows.Close/Scan loop, error wrapping) stays byte-identical.

- [ ] **Step 4: Run tests to verify they pass**

Run: `go test ./internal/db/ -run TestListEpisodesForChannelWindow -v` → PASS.
Then the whole package: `go test ./internal/db/ > /tmp/db.log 2>&1; echo exit=$?` → `exit=0` (never pipe through tail — check the real exit code).

- [ ] **Step 5: Commit**

```bash
git add internal/db/memory.go internal/db/memory_test.go
git commit -m "fix(db): span-overlap episode selection in ListEpisodesForChannelWindow

An episode matches a compare window when its per-channel provenance span
[min ts, max ts] overlaps (from,to], not only when a cited ref lands
inside — episodes cite sparse key messages while stories span days, so
the old query read coverage 0 on windows whose story was fully in the
vault (29/56 windows in the 2026-07-19 live compare).

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Xo7jXEcJB3kQjpqR7Q4PvH"
```

---

### Task 2: Span-based coverage + gap split in the compare runner

**Files:**
- Modify: `internal/memory/digest_compare.go` (`loadRenderEpisodes` ~line 188, `splitCoverage` ~line 216, `shadowRender` ~line 146)
- Test: `internal/memory/digest_compare_test.go`

**Interfaces:**
- Consumes: Task 1's span-selecting `ListEpisodesForChannelWindow`; `db.MemoryExtractMessage{ChannelID, ChannelName, TS string, TSUnix float64, Author, Text}`; `parseProvenance(body) []episodeRef` where `episodeRef.TS` is the raw Slack ts string (parses as float64).
- Produces:
  - `type tsSpan struct { from, to float64 }` (unexported, `digest_compare.go`)
  - `loadRenderEpisodes(channelID string, ids []string) ([]renderEpisode, []tsSpan, error)` — second return changes from `map[string]bool` to `[]tsSpan` (one span per episode with ≥1 parseable channel-scoped ref)
  - `splitCoverage(msgs []db.MemoryExtractMessage, spans []tsSpan) (gap []gapMessage, covered int)` — a message is covered when `span.from <= m.TSUnix && m.TSUnix <= span.to` for any span; everything else is gap
  - `renderEpisode` and `renderChannelDigest` are untouched (MEM-01 render-clause validation still builds its citable set from `renderEpisode.Provenance`).

- [ ] **Step 1: Write the failing unit test for interval splitCoverage**

Append to `internal/memory/digest_compare_test.go`:

```go
// TestSplitCoverageSpans: span-based coverage (2026-07-20 instrument fix) —
// a message inside ANY selected episode's [from,to] span is covered even when
// its exact ts was never cited; messages outside every span are the raw gap
// fed to the render prompt.
func TestSplitCoverageSpans(t *testing.T) {
	msgs := []db.MemoryExtractMessage{
		{TS: "100.000100", TSUnix: 100, Author: "a", Text: "at span start"},
		{TS: "150.000100", TSUnix: 150, Author: "a", Text: "inside span, uncited"},
		{TS: "200.000100", TSUnix: 200, Author: "a", Text: "at span end"},
		{TS: "250.000100", TSUnix: 250, Author: "a", Text: "outside every span"},
	}
	gap, covered := splitCoverage(msgs, []tsSpan{{from: 100, to: 200}})
	if covered != 3 {
		t.Errorf("covered = %d, want 3 (span bounds inclusive both ends)", covered)
	}
	if len(gap) != 1 || gap[0].TS != "250.000100" {
		t.Errorf("gap = %+v, want the single out-of-span message", gap)
	}
	// No spans (no episodes): everything is gap, coverage 0.
	gap, covered = splitCoverage(msgs, nil)
	if covered != 0 || len(gap) != 4 {
		t.Errorf("no-span split = covered %d / gap %d, want 0/4", covered, len(gap))
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/memory/ -run TestSplitCoverageSpans -v`
Expected: FAIL to COMPILE — `undefined: tsSpan` and `splitCoverage` signature mismatch. A compile failure is this step's expected "red".

- [ ] **Step 3: Implement spans in digest_compare.go**

Replace `loadRenderEpisodes` and `splitCoverage` in `internal/memory/digest_compare.go`, and add `tsSpan` + `strconv` import:

```go
// tsSpan is one selected episode's story interval on the compare channel:
// [from, to] over its parseable channel-scoped provenance ts. Coverage and the
// gap split are span-based (2026-07-20 instrument fix): an in-span message is
// represented by the episode narrative even when its exact ts was never cited.
type tsSpan struct{ from, to float64 }

// loadRenderEpisodes reads each episode node's body from the vault and projects
// it into a renderEpisode (title + Story/Outcome + this channel's provenance ts)
// plus the episode's story span on this channel — the coverage/gap intervals.
// An episode with no parseable channel-scoped ref contributes no span (cannot
// happen for extractor-written episodes; defensive skip only). A vault read
// error propagates (the caller isolates the whole channel).
func (p *Pipeline) loadRenderEpisodes(channelID string, ids []string) ([]renderEpisode, []tsSpan, error) {
	var episodes []renderEpisode
	var spans []tsSpan
	for _, id := range ids {
		n, err := p.vault.ReadNode(id)
		if err != nil {
			return nil, nil, fmt.Errorf("read episode %s: %w", id, err)
		}
		var prov []string
		span := tsSpan{}
		hasSpan := false
		for _, r := range parseProvenance(n.Body) {
			if r.ChannelID != channelID {
				continue
			}
			prov = append(prov, r.TS)
			ts, perr := strconv.ParseFloat(r.TS, 64)
			if perr != nil {
				continue
			}
			if !hasSpan {
				span = tsSpan{from: ts, to: ts}
				hasSpan = true
				continue
			}
			if ts < span.from {
				span.from = ts
			}
			if ts > span.to {
				span.to = ts
			}
		}
		if hasSpan {
			spans = append(spans, span)
		}
		episodes = append(episodes, renderEpisode{
			Title:      n.Title,
			Story:      sectionProse(n.Body, "## Story"),
			Outcome:    sectionProse(n.Body, "## Outcome"),
			Provenance: prov,
		})
	}
	return episodes, spans, nil
}

// splitCoverage partitions the window's messages by the selected episodes'
// story spans: covered counts messages inside ANY span (inclusive both ends —
// the episode narrative represents them), and the rest become raw gap messages
// the render may cite to fill what the episodes miss.
func splitCoverage(msgs []db.MemoryExtractMessage, spans []tsSpan) (gap []gapMessage, covered int) {
	for _, m := range msgs {
		inSpan := false
		for _, s := range spans {
			if m.TSUnix >= s.from && m.TSUnix <= s.to {
				inSpan = true
				break
			}
		}
		if inSpan {
			covered++
			continue
		}
		gap = append(gap, gapMessage{TS: m.TS, Author: m.Author, Text: m.Text})
	}
	return gap, covered
}
```

In `shadowRender` (~line 151) change the plumbing line:

```go
	episodes, spans, err := p.loadRenderEpisodes(d.ChannelID, ids)
```

and the split line:

```go
	gapMsgs, covered := splitCoverage(windowMsgs, spans)
```

Add `"strconv"` to the import block.

- [ ] **Step 4: Run the unit test, then the whole package**

Run: `go test ./internal/memory/ -run TestSplitCoverageSpans -v` → PASS.
Run: `go test ./internal/memory/ > /tmp/mem.log 2>&1; echo exit=$?` → expect `exit=0`. If an existing compare test fails ONLY on a coverage number (span semantics legitimately widen coverage), update that expectation with a comment citing the span fix; if `TestMemory13_*` or `TestDigestCompare_LegacyTablesByteIdentical` fails, STOP — that is a contract break, do not adjust those tests.

- [ ] **Step 5: Write the integration test (window between two cited refs)**

Append to `internal/memory/digest_compare_test.go`, using the file's existing helpers (`newTestVault`/`newTestDB`, `seedWorkspaceRow`/`seedUserRow`/`seedChannelRow`/`seedMessageRow`, `seedLegacyChannelDigest`, `indexEpisodeWithProvenance`, `episodeNode`, `fakeGen`, `pipelineTestConfig` — all already defined in this test file/package):

```go
// TestCompareDigestsSpanSelectsBetweenRefs: the live 0%-window artifact (the
// 2026-07-19 compare: 29/56 windows read coverage 0 while their stories were
// in the vault) — a legacy window that falls strictly BETWEEN an episode's two
// cited refs must still select that episode (span overlap), render, and report
// full span coverage.
func TestCompareDigestsSpanSelectsBetweenRefs(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	seedUserRow(t, d, "U1ALICE", "alice")
	seedChannelRow(t, d, "C0AAA", "general")

	base := time.Now().Add(-time.Hour).Unix()
	// The digest window's messages sit strictly between the episode's refs.
	seedMessageRow(t, d, "C0AAA", fmt.Sprintf("%d.000100", base+10), "U1ALICE", "mid-story update")
	seedMessageRow(t, d, "C0AAA", fmt.Sprintf("%d.000200", base+20), "U1ALICE", "another mid-story message")
	digestID := seedLegacyChannelDigest(t, d, "C0AAA", float64(base+5), float64(base+25), []db.DigestTopic{
		{Title: "Mid", Summary: "mid-window", KeyMessages: "[]", Decisions: "[]"},
	})

	// The episode cites only the story's endpoints — both OUTSIDE (base+5, base+25].
	indexEpisodeWithProvenance(t, v, d, episodeNode("ep_00000000000000000000000003", "Long story", "C0AAA",
		"A story spanning the whole hour.", "Resolved.",
		fmt.Sprintf("%d.000050", base), fmt.Sprintf("%d.000300", base+30)))

	reply := func(string) (string, error) {
		return fmt.Sprintf(`{"summary":"rendered","topics":[
			{"title":"Long story","summary":"the mid-window part","decisions":[],"action_items":[],"situations":[],"key_messages":["%d.000050"]}
		]}`, base), nil
	}
	p := NewPipeline(d, v, &fakeGen{reply: reply}, pipelineTestConfig(), t.Logf)

	cs, err := p.CompareDigests(context.Background(), time.Now().Add(-24*time.Hour))
	require.NoError(t, err)
	require.Len(t, cs.Channels, 1)
	cc := cs.Channels[0]
	assert.Equal(t, digestID, cc.LegacyDigestID)
	assert.Equal(t, 1, cc.MemoryTopics, "render RAN — the old refs-in-window query skipped this window entirely")
	assert.InDelta(t, 1.0, cc.Coverage, 0.001, "both window messages inside the [base, base+30] story span")
	assert.Equal(t, 1, cc.MemoryRefs, "the episode-cited endpoint ref survives render validation")
	assert.Equal(t, 0, cc.MemoryRefsRejected)
}
```

Note: `TestCompareDigestsHappyPath` needs NO edits — its two episodes carry single refs, so their spans are points and its Coverage stays 0.5 under span semantics.

- [ ] **Step 6: Run to verify it passes end-to-end**

Run: `go test ./internal/memory/ -run TestCompareDigestsSpanSelectsBetweenRefs -v`
Expected: PASS (Task 1 already carries the selection behavior; this test locks the integration end-to-end: selection → span coverage → render → shadow row). If it fails, fix the fixture/implementation, not the assertions — the assertions ARE the spec's core scenario.

- [ ] **Step 7: Commit**

```bash
git add internal/memory/digest_compare.go internal/memory/digest_compare_test.go
git commit -m "fix(memory): span-based coverage and gap split in the digest compare

Coverage now counts window messages inside any selected episode's story
span (the episode narrative represents them), and only out-of-span
messages feed the render prompt as raw gap — aligned with the span
episode selection. MEM-01 render-clause validation untouched.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Xo7jXEcJB3kQjpqR7Q4PvH"
```

---

### Task 3: Report — span semantics + `Windows with episodes` aggregate

**Files:**
- Modify: `internal/memory/digest_compare.go` (`ChannelCompare` struct ~line 37, `shadowRender` return plumbing, `RenderCompareReport` ~line 407)
- Test: `internal/memory/digest_compare_test.go` (`TestRenderCompareReport` ~line 286)

**Interfaces:**
- Consumes: Task 2's span coverage.
- Produces: `ChannelCompare.Episodes int` (selected-episode count per window); report header notes span semantics; Aggregate gains `Windows with episodes: N/M`.

- [ ] **Step 1: Extend the report test (failing)**

In `TestRenderCompareReport`, extend the fixture `CompareStats` so one channel has `Episodes: 2` and another `Episodes: 0`, and assert the new aggregate line renders:

```go
	if !strings.Contains(report, "Windows with episodes: 1/2") {
		t.Errorf("report missing span aggregate; got:\n%s", report)
	}
	if !strings.Contains(report, "Coverage (episode span)") {
		t.Errorf("report missing span-semantics column header; got:\n%s", report)
	}
```

(Adapt the exact counts to the test's existing two-channel fixture: one channel with episodes, one without.)

- [ ] **Step 2: Run to verify it fails**

Run: `go test ./internal/memory/ -run TestRenderCompareReport -v`
Expected: FAIL to COMPILE on `Episodes` field, then (after adding the field only) FAIL on the missing report lines.

- [ ] **Step 3: Implement**

1. Add to `ChannelCompare` (after `MemoryRefsRejected`):

```go
	Episodes           int     // episodes selected for the window (span overlap; 0 = nothing in memory covers it)
```

2. In `shadowRender`, return the count: change the signature to `(memTopics, memRefs, rejected, memChars, episodes int, coverage float64, err error)`, return `len(ids)` as `episodes` on every path (including the no-episode early return: `return 0, 0, 0, 0, 0, coverage, nil` → `return 0, 0, 0, 0, len(ids), coverage, nil` — `len(ids)` is 0 there), and in `compareOneChannel` assign it:

```go
	if cc.MemoryTopics, cc.MemoryRefs, cc.MemoryRefsRejected, cc.MemoryChars, cc.Episodes, cc.Coverage, err = p.shadowRender(ctx, d); err != nil {
```

3. In `RenderCompareReport`:
   - table header: `| Channel | Legacy topics | Memory topics | Legacy ref-valid | Memory ref-valid | Coverage (episode span) | Length ratio |`
   - explanatory line after the auto-generated blockquote: `b.WriteString("Coverage is span-based (2026-07-20): a window message counts as covered when it falls inside any selected episode's [first ref, last ref] story span.\n\n")`
   - aggregate: count `withEpisodes` in the per-channel loop (`if c.Episodes > 0 { withEpisodes++ }`) and print after the coverage line:

```go
	fmt.Fprintf(&b, "- Windows with episodes: **%d/%d**\n", withEpisodes, len(cs.Channels))
```

- [ ] **Step 4: Run package tests**

Run: `go test ./internal/memory/ > /tmp/mem3.log 2>&1; echo exit=$?` → `exit=0` (fix compile fallout of the `shadowRender` signature in any other test/caller — `compareOneChannel` is the only production caller).

- [ ] **Step 5: Commit**

```bash
git add internal/memory/digest_compare.go internal/memory/digest_compare_test.go
git commit -m "feat(memory): span-semantics coverage column + windows-with-episodes aggregate in the compare report

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Xo7jXEcJB3kQjpqR7Q4PvH"
```

---

### Task 4: Inventory changelog + full sweep

**Files:**
- Modify: `docs/inventory/memory.md` (Changelog section, new top entry)

**Interfaces:** none (docs + verification).

- [ ] **Step 1: Add the changelog entry**

Insert at the top of `## Changelog` in `docs/inventory/memory.md` (right after the heading's blank line, above the 2026-07-20 owner-review entry):

```markdown
- 2026-07-20 (digest-compare instrument fix, owner-approved spec `docs/superpowers/specs/2026-07-20-digest-compare-span-fix-design.md`): `ListEpisodesForChannelWindow` now selects episodes by per-channel story SPAN overlap (`MIN(ts_unix) <= to AND MAX(ts_unix) > from`) instead of refs-in-window, and the compare's `coverage` is span-based (a window message inside any selected episode's [first ref, last ref] interval counts covered; only out-of-span messages feed the render as raw gap). Fixes the 2026-07-19 finding that 29/56 live windows read coverage 0 while their stories were in the vault (episodes cite sparse key messages; legacy windows are ~1.5 h slices). Report gains the `Windows with episodes: N/M` aggregate and a span-semantics note; `memory_digest_shadow.coverage` column reused, no migration. MEM-01 render-clause validation and MEM-05 purity untouched (guards unmodified); the compare stays dark/diagnostic — the switch off legacy still awaits the re-run + owner hand-review.
```

- [ ] **Step 2: Full verification sweep**

```bash
gofmt -l internal/ | tee /tmp/fmt.log            # expect empty
go vet ./... > /tmp/vet.log 2>&1; echo exit=$?    # expect exit=0
go build ./... > /tmp/build.log 2>&1; echo exit=$?
go test ./internal/db/ ./internal/memory/ ./internal/inbox/ ./internal/dayplan/ ./internal/meeting/ ./internal/briefing/ > /tmp/sweep.log 2>&1; echo exit=$?
```
All exit codes 0; on any failure read the log file, fix, re-run.

- [ ] **Step 3: Commit**

```bash
git add docs/inventory/memory.md
git commit -m "docs(memory): changelog — digest-compare span-fix instrument change

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Xo7jXEcJB3kQjpqR7Q4PvH"
```

---

### Post-plan validation (controller, not a subagent task)

Live re-run per the spec's Validation section: `make build && ./watchtower memory digest-compare --since 72h --out <scratchpad>/digest-compare-span.md`, diff aggregates against the 2026-07-19 report (expectation: the 0%-window class collapses to genuinely-uncovered windows; mean coverage becomes a truthful switch input), present to the owner for the go/no-go re-read. Requires the live whitebit workspace and spends haiku-tier AI calls — owner-sanctioned in-session.
