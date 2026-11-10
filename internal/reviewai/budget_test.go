package reviewai

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
)

func batchesOf(n, lines int) []Batch {
	out := make([]Batch, n)
	for i := range out {
		out[i].Lines = lines
	}
	return out
}

func TestCallBudget(t *testing.T) {
	assert.Equal(t, 90*time.Second, CallBudget(0))
	assert.Equal(t, 150*time.Second, CallBudget(1))
	assert.Equal(t, 150*time.Second, CallBudget(1000))
	assert.Equal(t, 210*time.Second, CallBudget(1001))
	assert.Equal(t, 270*time.Second, CallBudget(MaxBatchLines))
}

func TestBudgets_Table(t *testing.T) {
	// 1 batch: 1 parallel, 1 wave of 4.5 min + the 2-min summary.
	assert.Equal(t, 1, Parallel(1))
	assert.Equal(t, 270*time.Second+2*time.Minute, RunCeiling(batchesOf(1, MaxBatchLines)))
	// 4 batches: 4 parallel, still 1 wave; the slowest batch counts.
	assert.Equal(t, 4, Parallel(4))
	four := append(batchesOf(3, 100), Batch{Lines: 2100})
	assert.Equal(t, CallBudget(2100)+2*time.Minute, RunCeiling(four))
	// 20 batches: 4 parallel, 5 waves.
	assert.Equal(t, 4, Parallel(20))
	assert.Equal(t, 5*270*time.Second+2*time.Minute, RunCeiling(batchesOf(20, MaxBatchLines)))
	// The cap.
	assert.Equal(t, 45*time.Minute, RunCeiling(batchesOf(40, MaxBatchLines)))
	assert.Equal(t, 0, Parallel(0))
	assert.Equal(t, SummaryBudget, RunCeiling(nil))
}
