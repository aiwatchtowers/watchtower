package reviewai

import "time"

// CallBudget is the time one batch call gets for lines shown diff lines:
// 90 s + 60 s per started thousand lines (tech spec §3.2).
func CallBudget(lines int) time.Duration {
	return 90*time.Second + time.Duration((max(lines, 0)+999)/1000)*time.Minute
}

// Parallel is how many batch calls run at once.
func Parallel(batches int) int { return max(min(batches, maxParallel), 0) }

// RunCeiling is the most a run over batches may take: its waves times the
// slowest batch's budget, plus the summary, capped at MaxRunBudget.
func RunCeiling(batches []Batch) time.Duration {
	var slowest time.Duration
	for _, b := range batches {
		slowest = max(slowest, CallBudget(b.Lines))
	}
	waves := 0
	if p := Parallel(len(batches)); p > 0 {
		waves = (len(batches) + p - 1) / p
	}
	return min(time.Duration(waves)*slowest+SummaryBudget, MaxRunBudget)
}
