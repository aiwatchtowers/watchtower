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
	// extractBatchAttempts counted failures after which a window is
	// extracted alone, so one bad window stops failing its batch neighbours.
	extractBatchAttempts = 3
	// extractQuarantineAttempts counted failures (the solo ones included)
	// after which the window is quarantined.
	extractQuarantineAttempts = 6
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

// failed counts one failure of w and reports whether its budget is now spent
// (the window is quarantined, and the caller may let the watermark pass it).
func (b *extractBudget) failed(database *db.DB, w runWindow, cause error) (quarantined bool, err error) {
	k := keyOf(w)
	f := b.failing[k]
	f.ChannelID, f.FirstTS = k.channelID, k.firstTS
	last := len(w.Messages) - 1
	f.LastTS, f.LastTSUnix = w.Messages[last].TS, w.tsUnix[last]
	f.Failures++
	f.LastError = cause.Error()
	if f.Failures >= extractQuarantineAttempts {
		f.QuarantinedAt = time.Now().UTC().Format(time.RFC3339)
	}
	if err := database.SetMemoryExtractFailure(f); err != nil {
		return false, err
	}
	b.failing[k] = f
	return f.QuarantinedAt != "", nil
}

// countsTowardBudget decides whether a batch failure is evidence against the
// batch's own windows: only when a LATER batch of the same run committed,
// proving the provider and the vault worked after the failure. A run that
// stopped committing — an outage, a quota running out mid-run, a broken
// vault, a provider answering garbage — proves nothing about the windows it
// failed on (they head the next run anyway), so a transient failure never
// spends a budget and never lets the watermark pass a window. A failure caused
// by cancellation never counts.
func countsTowardBudget(batch, lastCommitted int, cancelled bool) bool {
	return !cancelled && batch < lastCommitted
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
