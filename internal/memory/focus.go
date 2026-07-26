package memory

import (
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"watchtower/internal/db"
)

// focusFileName is the vault-root file the owner edits to steer memory
// importance. Like map.md/index.md it lives outside vaultSubdirs, but unlike
// them it is owner-authored and read-only from the pipeline's side — nothing
// in this package ever writes it.
const focusFileName = "focus.md"

// focusDirectives is the parsed contents of focus.md: the bulleted node
// references under "## Now" and "## Cooled", trimmed, in document order.
type focusDirectives struct {
	Now    []string
	Cooled []string
}

// parseFocus parses focus.md's fixed two-heading grammar. A line that is,
// after TrimSpace, case-insensitively equal to "## Now" or "## Cooled" opens
// that section; any other line starting with "#" (an unrecognized heading)
// closes whatever section is open. Inside an open section, lines starting
// with "- " are bullets (trimmed of the marker and surrounding space);
// anything else (prose) is ignored. parseFocus is pure — no vault/DB access
// — and an empty/missing raw string yields the zero value.
func parseFocus(raw string) focusDirectives {
	var fd focusDirectives
	section := "" // "" | "now" | "cooled"
	for _, line := range strings.Split(raw, "\n") {
		trimmed := strings.TrimSpace(line)
		switch strings.ToLower(trimmed) {
		case "## now":
			section = "now"
			continue
		case "## cooled":
			section = "cooled"
			continue
		}
		if strings.HasPrefix(trimmed, "#") {
			section = ""
			continue
		}
		if !strings.HasPrefix(trimmed, "- ") {
			continue
		}
		bullet := strings.TrimSpace(strings.TrimPrefix(trimmed, "- "))
		if bullet == "" {
			continue
		}
		switch section {
		case "now":
			fd.Now = append(fd.Now, bullet)
		case "cooled":
			fd.Cooled = append(fd.Cooled, bullet)
		}
	}
	return fd
}

// matchFingerprint hashes the RESOLVED match set — sha256 hex over the
// sorted node ids tagged by section ("now:"/"cooled:") that matchFocus
// produced — rather than the raw focus.md text (final-review Fix 2:
// fingerprinting directive TEXT left a bullet naming a not-yet-existing node
// permanently inert, since nothing about the text ever changes once the file
// is stable, and a brand-new node about an already-focused topic could never
// get matched either). Fingerprinting the resolved set instead means every
// gated run re-resolves the directives (matchFocus always runs; see
// runFocus) and the hash changes whenever the SET of matched ids changes —
// whether that's because the owner edited focus.md or because a new node
// showed up that a standing bullet now resolves to. Sorting makes match
// order within a section a no-op; the section tag makes a node moving
// between Now and Cooled change the hash. The empty match set (no bullets,
// or every bullet unresolved) hashes to whatever sha256("") happens to be —
// stable and unremarkable, no special-cased sentinel.
func matchFingerprint(now, cooled []string) string {
	tagged := make([]string, 0, len(now)+len(cooled))
	for _, id := range now {
		tagged = append(tagged, "now:"+id)
	}
	for _, id := range cooled {
		tagged = append(tagged, "cooled:"+id)
	}
	sort.Strings(tagged)
	sum := sha256.Sum256([]byte(strings.Join(tagged, "\n")))
	return hex.EncodeToString(sum[:])
}

// readFocusFile reads the vault-root focus.md file. It is owner-authored and
// this package never writes it (mirroring how map.md/index.md are vault-root
// files, but reversed direction). A missing file is a clean miss, not an
// error, so callers can treat "no focus.md yet" the same as "no directives".
func (p *Pipeline) readFocusFile() (string, bool, error) {
	raw, err := os.ReadFile(filepath.Join(p.vault.path, focusFileName))
	if err != nil {
		if os.IsNotExist(err) {
			return "", false, nil
		}
		return "", false, fmt.Errorf("memory: read focus.md: %w", err)
	}
	return string(raw), true, nil
}

// matchFocus resolves a parsed focusDirectives' bullets to memory node ids.
// For each bullet it tries, on the whole trimmed bullet AND on each
// comma-separated fragment: (1) LookupMemoryAlias, (2) a case-insensitive
// substring match against every non-tombstone node's title. The title
// candidates are fetched ONCE per call via ListMemoryNodeTitles — final-
// review Fix 3: matching used to run one ListMemoryNodeIDsByTitleMatch SQL
// query per candidate, relying on SQLite's lower(), which folds ASCII only
// and silently misses non-Latin titles (the owner works in Russian); folding
// case in Go with strings.ToLower handles Unicode correctly, and fetching
// the title list once per pass (rather than once per candidate) is also
// cheaper. No bullets at all skips the fetch entirely (kept for
// TestRunFocusSweepErrorFreezesFingerprint's isolation: an empty focus.md
// must never touch memory_nodes, so a dropped-table failure is attributable
// to the sweep alone). Every id found across those probes is unioned into
// the bullet's section set. A bullet that resolves nothing logs once and
// contributes nothing (not an error — an owner typo shouldn't freeze the
// whole focus step). A node id that lands in both sections is kept in Now
// only (logged once) — Now always wins the tie. A DB error from either probe
// propagates immediately so the caller can freeze the step.
func (p *Pipeline) matchFocus(fd focusDirectives) (now, cooled []string, err error) {
	if len(fd.Now) == 0 && len(fd.Cooled) == 0 {
		return nil, nil, nil
	}

	titles, err := p.db.ListMemoryNodeTitles()
	if err != nil {
		return nil, nil, fmt.Errorf("memory: focus: list node titles: %w", err)
	}

	nowIDs := map[string]bool{}
	if err := p.resolveBulletsInto(fd.Now, titles, nowIDs); err != nil {
		return nil, nil, err
	}
	cooledIDs := map[string]bool{}
	if err := p.resolveBulletsInto(fd.Cooled, titles, cooledIDs); err != nil {
		return nil, nil, err
	}

	for id := range cooledIDs {
		if nowIDs[id] {
			p.logf("memory: focus: node %s matched in both Now and Cooled, keeping Now", id)
			delete(cooledIDs, id)
		}
	}

	return sortedSet(nowIDs), sortedSet(cooledIDs), nil
}

// resolveBulletsInto resolves each bullet to node ids (via matchBullet,
// matched against the shared titles snapshot) and unions the hits into dst,
// logging a no-match line per unresolved bullet.
func (p *Pipeline) resolveBulletsInto(bullets []string, titles []db.MemoryNodeTitle, dst map[string]bool) error {
	for _, bullet := range bullets {
		ids, err := p.matchBullet(bullet, titles)
		if err != nil {
			return err
		}
		if len(ids) == 0 {
			p.logf("memory: focus: bullet %q matched nothing", bullet)
			continue
		}
		for id := range ids {
			dst[id] = true
		}
	}
	return nil
}

// matchBullet resolves one bullet (the whole trimmed text plus each
// comma-separated fragment) to a set of node ids via alias lookup and a
// Unicode-case-folded substring match against titles (matchFocus's one
// fetch-per-pass snapshot).
func (p *Pipeline) matchBullet(bullet string, titles []db.MemoryNodeTitle) (map[string]bool, error) {
	candidates := []string{bullet}
	for _, frag := range strings.Split(bullet, ",") {
		frag = strings.TrimSpace(frag)
		if frag != "" && frag != bullet {
			candidates = append(candidates, frag)
		}
	}

	ids := map[string]bool{}
	for _, c := range candidates {
		if id, err := p.db.LookupMemoryAlias(c); err == nil {
			ids[id] = true
		} else if !errors.Is(err, sql.ErrNoRows) {
			return nil, fmt.Errorf("memory: focus: alias lookup %q: %w", c, err)
		}

		needle := strings.ToLower(c)
		for _, t := range titles {
			if strings.Contains(strings.ToLower(t.Title), needle) {
				ids[t.ID] = true
			}
		}
	}
	return ids, nil
}

// sortedSet returns the set's members as a sorted slice — nil (not an empty
// slice) when the set is empty, so callers/tests can assert.Empty either way.
func sortedSet(m map[string]bool) []string {
	if len(m) == 0 {
		return nil
	}
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// runFocus is the focus-salience step (behind memory.focus.enabled): parse
// focus.md, ALWAYS re-resolve its bullets against the live index
// (final-review Fix 2 — matchFocus runs on every gated call, not just when
// the file text changed, so a bullet naming a not-yet-existing node stops
// being permanently inert once that node shows up), and when the RESOLVED
// match set's fingerprint differs from the last APPLIED one, rewrite
// memory_focus_matches wholesale, sweep EVERY indexed node's persisted
// importance_score (a focus edit touches no node file, so the MEM-16
// touched-node refresh would never see it), and only after both succeeded
// store the new fingerprint (freeze-on-error: a failed sweep leaves the old
// fingerprint so the next run retries). Runs after the owner-edit commit +
// Reconcile (the focus edit is committed, the index is fresh) and before
// every consumer of importance. The gate itself is checked by the caller
// (Run), the calendar/mirror/jira precedent — this function always does the
// work when called. Returns the number of pipeline_steps rows recorded (0
// when the resolved set is unchanged — no step row at all, mirroring
// "nothing to do" elsewhere in this package) and an error that is logged by
// the caller but never fails the run (source-isolation precedent).
func (p *Pipeline) runFocus(runID int64, stepOffset int, stats *RunStats) (int, error) {
	step := stepOffset + 1

	raw, _, err := p.readFocusFile()
	if err != nil {
		p.recordSemanticStep(runID, &step, "focus", "error", nil, time.Now())
		return 1, err
	}
	fd := parseFocus(raw)

	now, cooled, err := p.matchFocus(fd)
	if err != nil {
		p.recordSemanticStep(runID, &step, "focus", "error", nil, time.Now())
		return 1, err
	}
	fp := matchFingerprint(now, cooled)

	stored, err := p.db.FocusFingerprint()
	if err != nil {
		p.recordSemanticStep(runID, &step, "focus", "error", nil, time.Now())
		return 1, err
	}
	if fp == stored {
		// Unchanged resolved set (including the never-matched-anything case
		// once it has already been applied) — nothing to rewrite or sweep.
		return 0, nil
	}

	start := time.Now()
	if err := p.db.ReplaceFocusMatches(now, cooled); err != nil {
		p.recordSemanticStep(runID, &step, "focus", "error", nil, start)
		return 1, err
	}
	stats.FocusMatched += len(now) + len(cooled)

	swept, failed, err := p.sweepFocusImportance()
	stats.FocusSwept += swept
	stats.FocusFailed += failed
	if err != nil {
		p.recordSemanticStep(runID, &step, "focus", "error", nil, start)
		return 1, err
	}

	// Only now, with the match rewrite AND the whole-vault sweep both
	// committed, does the applied fingerprint advance — a failure anywhere
	// above leaves it exactly as it was so the next run retries the same work.
	if err := p.db.SetFocusFingerprint(fp); err != nil {
		p.recordSemanticStep(runID, &step, "focus", "error", nil, start)
		return 1, err
	}

	p.recordSemanticStep(runID, &step, "focus", "done", nil, start)
	return 1, nil
}

// sweepFocusImportance recomputes and persists importance_score for EVERY
// indexed node — a focus.md edit changes no node file, so it is invisible to
// the touched-node-only refresh Reconcile/upsertIndexNode already do (MEM-16);
// this is the whole-vault catch-up. One ownerEditedMemo is shared across the
// entire pass (the MEM-16 addendum precedent: every real multi-node caller of
// computeNodeImportance memoizes the owner-touch walk once, not per node). A
// per-node failure (the node's file went missing/corrupt since it was
// indexed, or one of computeNodeImportance's signal reads errors) is logged,
// skipped, and counted in failed — quarantine philosophy, the same
// log-and-keep-prior-value policy index.go's refineLinkedNode already uses.
// Only a failure reading the node LIST itself (ListMemoryNodes) is DB-wide and
// propagates, freezing the whole focus step (the caller never advances the
// fingerprint on that error).
func (p *Pipeline) sweepFocusImportance() (swept, failed int, err error) {
	nodes, err := p.db.ListMemoryNodes()
	if err != nil {
		return 0, 0, fmt.Errorf("memory: focus: sweep: list nodes: %w", err)
	}

	memo := newOwnerEditedMemo(p.vault)
	for _, row := range nodes {
		n, rerr := p.vault.ReadNode(row.ID)
		if rerr != nil {
			p.logf("memory: focus: sweep: read %s: %v", row.ID, rerr)
			failed++
			continue
		}
		importance, cerr := computeNodeImportance(p.db, memo.lookup, n, row.Path)
		if cerr != nil {
			p.logf("memory: focus: sweep: compute importance %s: %v", row.ID, cerr)
			failed++
			continue
		}
		if uerr := p.db.UpdateMemoryNodeImportanceScore(row.ID, importance); uerr != nil {
			p.logf("memory: focus: sweep: update %s: %v", row.ID, uerr)
			failed++
			continue
		}
		swept++
	}
	return swept, failed, nil
}

// runFocusDisable is the gate-OFF counterpart of runFocus (Fix 1,
// final-review wave): a workspace that had focus enabled and accumulated
// memory_focus_matches / boosted importance_scores must not keep that ×2.0/
// ×0.5 skew forever once the owner flips memory.focus.enabled back off. The
// caller (Run) invokes this in the gate's else-branch. It reads the applied
// fingerprint: empty means focus was never enabled (or was already
// neutralized by a prior disabled run) — the fast path, 0 steps, no DB write
// at all, so a never-enabled workspace stays byte-identical
// (TestRunFocusGateOffByteIdentical). A non-empty fingerprint means residual
// state exists: memory_focus_matches is emptied, every indexed node's
// importance_score is swept back to its unboosted value (sweepFocusImportance
// reused verbatim — same computation, focus now reads back as "" for every
// node since the table is already empty), and only once both succeeded does
// the fingerprint clear to "" — the same freeze-on-error discipline as
// runFocus, so a failed sweep leaves the fingerprint non-empty and the next
// run retries the neutralization instead of silently losing residual state.
func (p *Pipeline) runFocusDisable(runID int64, stepOffset int, stats *RunStats) (int, error) {
	step := stepOffset + 1

	fp, err := p.db.FocusFingerprint()
	if err != nil {
		p.recordSemanticStep(runID, &step, "focus-disable", "error", nil, time.Now())
		return 1, err
	}
	if fp == "" {
		return 0, nil
	}

	start := time.Now()
	if err := p.db.ReplaceFocusMatches(nil, nil); err != nil {
		p.recordSemanticStep(runID, &step, "focus-disable", "error", nil, start)
		return 1, err
	}

	swept, failed, err := p.sweepFocusImportance()
	stats.FocusSwept += swept
	stats.FocusFailed += failed
	if err != nil {
		p.recordSemanticStep(runID, &step, "focus-disable", "error", nil, start)
		return 1, err
	}

	if err := p.db.SetFocusFingerprint(""); err != nil {
		p.recordSemanticStep(runID, &step, "focus-disable", "error", nil, start)
		return 1, err
	}

	p.recordSemanticStep(runID, &step, "focus-disable", "done", nil, start)
	return 1, nil
}
