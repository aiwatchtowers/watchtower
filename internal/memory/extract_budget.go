package memory

import (
	"fmt"
	"time"

	"watchtower/internal/db"
)

// MEM-04 attempt budget (owner-approved 2026-10-01, see
// docs/inventory/memory.md): a window that keeps failing is first pulled out
// of its batch and extracted alone, then quarantined so the watermark can
// pass it — instead of freezing extraction forever and re-extracting (and
// duplicating) every later window on every run.
const (
	// extractBatchAttempts consecutive failures, of any kind, after which a
	// window is extracted alone. Splitting loses nothing, so it needs no
	// proof that the window is at fault — and without it a quiet install
	// whose whole chunk fits one batch could never isolate a bad window.
	extractBatchAttempts = 3
	// extractSoloAttempts proven failures while alone in its batch (split
	// out, or alone by size) after which the window is quarantined — see
	// provenFailure.
	extractSoloAttempts = 3
)

// windowKey identifies an extraction window across runs: its channel and its
// first message's raw Slack ts — never ts_unix, which is whole seconds while a
// window boundary can fall inside one second. Stable while the watermark stays
// below the window, since windows are cut from the first loaded message on.
type windowKey struct {
	channelID string
	firstTS   string
}

func keyOf(w runWindow) windowKey {
	return windowKey{w.ChannelID, w.Messages[0].TS}
}

// extractBudget is one run's view of memory_extract_failures.
type extractBudget struct {
	failing     map[windowKey]db.MemoryExtractFailure
	quarantined []db.MemoryExtractFailure
}

func newExtractBudget(rows []db.MemoryExtractFailure) *extractBudget {
	b := &extractBudget{failing: make(map[windowKey]db.MemoryExtractFailure)}
	for _, r := range rows {
		if r.QuarantinedAt != "" {
			b.quarantined = append(b.quarantined, r)
		} else {
			b.failing[windowKey{r.ChannelID, r.FirstTS}] = r
		}
	}
	return b
}

// dropQuarantined removes the messages of quarantined windows, so no window
// holds them and safeWatermark can pass them. Returns the kept messages and
// how many were dropped.
func (b *extractBudget) dropQuarantined(msgs []db.MemoryExtractMessage) ([]db.MemoryExtractMessage, int) {
	if len(b.quarantined) == 0 {
		return msgs, 0
	}
	kept := msgs[:0:0]
	for _, m := range msgs {
		if !b.isQuarantined(m) {
			kept = append(kept, m)
		}
	}
	return kept, len(msgs) - len(kept)
}

// isQuarantined compares raw Slack ts strings: they share one fixed
// "<10-digit seconds>.<6 digits>" shape, so string order is time order, and a
// channel's windows are contiguous in it (ListMemoryExtractMessages orders a
// channel's messages by ts), so a quarantined range never covers a message of
// another window.
func (b *extractBudget) isQuarantined(m db.MemoryExtractMessage) bool {
	for _, q := range b.quarantined {
		if q.ChannelID == m.ChannelID && m.TS >= q.FirstTS && m.TS <= q.LastTS {
			return true
		}
	}
	return false
}

// solo reports, per window, whether its batch budget is spent so it must be
// extracted alone.
func (b *extractBudget) solo(windows []runWindow) []bool {
	out := make([]bool, len(windows))
	for i, w := range windows {
		out[i] = b.failing[keyOf(w)].Failures >= extractBatchAttempts
	}
	return out
}

// succeeded forgets a window's failures once it committed.
func (b *extractBudget) succeeded(database *db.DB, w runWindow) error {
	k := keyOf(w)
	if _, ok := b.failing[k]; !ok {
		return nil
	}
	delete(b.failing, k)
	return database.DeleteMemoryExtractFailure(k.channelID, k.firstTS)
}

// failed counts one failure of w — every failure toward the split, a proven
// one while w was extracted alone toward quarantine — and reports whether its
// budget is now spent (the window is quarantined, and the caller may let the
// watermark pass it).
func (b *extractBudget) failed(database *db.DB, w runWindow, solo, proven bool, cause error) (quarantined bool, err error) {
	k := keyOf(w)
	f := b.failing[k]
	f.ChannelID, f.FirstTS = k.channelID, k.firstTS
	last := len(w.Messages) - 1
	f.LastTS, f.LastTSUnix = w.Messages[last].TS, w.tsUnix[last]
	f.Failures++
	if solo && proven {
		f.SoloFailures++
	}
	f.LastError = cause.Error()
	if f.SoloFailures >= extractSoloAttempts {
		f.QuarantinedAt = time.Now().UTC().Format(time.RFC3339)
	}
	if err := database.SetMemoryExtractFailure(f); err != nil {
		return false, err
	}
	b.failing[k] = f
	return f.QuarantinedAt != "", nil
}

// failedBatch is one batch that failed in a run, as runExtract hands it to
// countFailures.
type failedBatch struct {
	batch     int // index in the run's batches
	idxs      []int
	err       error
	cancelled bool // failed because the run was cancelled (shutdown)
}

// countFailures records a run's failed batches against their windows'
// budgets and returns the windows quarantined by it — they stop holding the
// watermark back. A failure caused by cancellation never counts; an
// unrecordable one is simply not counted (the window stays frozen, MEM-04).
func (p *Pipeline) countFailures(budget *extractBudget, windows []runWindow, failed []failedBatch, lastCommitted int) (quarantined []int) {
	for _, fb := range failed {
		if fb.cancelled {
			continue
		}
		proven := provenFailure(fb.batch, lastCommitted)
		for _, i := range fb.idxs {
			q, err := budget.failed(p.db, windows[i], len(fb.idxs) == 1, proven, fb.err)
			if err != nil {
				p.logf("memory: record extract failure for %s: %v", windows[i].ChannelName, err)
				continue
			}
			if q {
				quarantined = append(quarantined, i)
				p.logf("memory: QUARANTINED extraction window %s after %d failed solo attempts (last: %v) — memory will not read these messages; the record stays in memory_extract_failures",
					windowSpan(windows[i]), extractSoloAttempts, fb.err)
			}
		}
	}
	return quarantined
}

// provenFailure decides whether a batch failure is evidence against the
// batch's own windows — the only kind that counts toward quarantine: a LATER
// batch of the same run committed, proving the provider and the vault worked
// after the failure. A run that stopped committing — an outage, a quota or
// rate limit running out mid-run, a broken vault, a provider answering garbage
// — proves nothing about the windows it failed on (they head the next run
// anyway), so a transient failure never quarantines a window and never lets
// the watermark pass it.
func provenFailure(batch, lastCommitted int) bool {
	return batch < lastCommitted
}

// batchWindowsWithSolo groups windows like groupWindowsIntoBatches, except
// that every window marked solo gets a batch of its own, in place, so batches
// keep the first-ts order the per-batch watermark advance relies on.
func batchWindowsWithSolo(windows []runWindow, solo []bool, maxChannels, maxMessages int) [][]int {
	var batches [][]int
	start := 0
	flush := func(end int) {
		if end <= start {
			return
		}
		for _, b := range groupWindowsIntoBatches(windows[start:end], maxChannels, maxMessages) {
			for j := range b {
				b[j] += start
			}
			batches = append(batches, b)
		}
	}
	for i := range windows {
		if solo[i] {
			flush(i)
			batches = append(batches, []int{i})
			start = i + 1
		}
	}
	flush(len(windows))
	return batches
}

// windowSpan renders a window for the quarantine log line.
func windowSpan(w runWindow) string {
	return fmt.Sprintf("%s (%s), %d messages, ts %.6f..%.6f", w.ChannelName, w.ChannelID,
		len(w.Messages), w.tsUnix[0], w.tsUnix[len(w.tsUnix)-1])
}
