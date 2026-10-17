package daemon

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/instructions"
)

// stubMiner replaces the miner run and counts calls.
func stubMiner(t *testing.T, n int, err error) *int {
	t.Helper()
	calls := 0
	old := runInstructionMiner
	runInstructionMiner = func(context.Context, *instructions.Miner) (int, *digest.Usage, error) {
		calls++
		return n, &digest.Usage{InputTokens: 10, OutputTokens: 2}, err
	}
	t.Cleanup(func() { runInstructionMiner = old })
	return &calls
}

func TestPhaseInstructionSuggestions_OncePerDay(t *testing.T) {
	d, database, _ := newBackfillDaemon(t)
	calls := stubMiner(t, 2, nil)

	d.phaseInstructionSuggestions(context.Background())
	d.phaseInstructionSuggestions(context.Background())
	assert.Equal(t, 1, *calls, "second call the same day is skipped")
	assert.Equal(t, []string{"instruction-suggestions"}, pipelineRunNames(t, database))
	assert.FileExists(t, d.lastInstructionSuggestionsPath())

	// A restart restores the stamp.
	d2 := New(d.config)
	d2.SetDB(database)
	d2.loadLastInstructionSuggestions()
	d2.phaseInstructionSuggestions(context.Background())
	assert.Equal(t, 1, *calls)

	// Yesterday's stamp runs again.
	d.lastInstructionSuggestions = time.Now().AddDate(0, 0, -1)
	d.phaseInstructionSuggestions(context.Background())
	assert.Equal(t, 2, *calls)
}

func TestPhaseInstructionSuggestions_SkipsNearLimit(t *testing.T) {
	d, database, buf := newBackfillDaemon(t)
	calls := stubMiner(t, 0, nil)
	now := time.Now()
	require.NoError(t, database.UpsertPlanUsageStatus(db.PlanUsageStatus{
		State: "ok", Plan: "max", FetchedAt: &now, UpdatedAt: now, BreakdownJSON: "[]",
		LimitsJSON: `[{"key":"session","projection":{"state":"will_hit"}}]`,
	}))

	d.phaseInstructionSuggestions(context.Background())
	assert.Zero(t, *calls)
	assert.Contains(t, buf.String(), "plan limit near")
	assert.NoFileExists(t, d.lastInstructionSuggestionsPath())
}

func TestPhaseInstructionSuggestions_ErrorDoesNotStamp(t *testing.T) {
	d, _, _ := newBackfillDaemon(t)
	calls := stubMiner(t, 0, errors.New("boom"))

	d.phaseInstructionSuggestions(context.Background())
	assert.True(t, d.lastInstructionSuggestions.IsZero())
	assert.NoFileExists(t, d.lastInstructionSuggestionsPath())

	d.phaseInstructionSuggestions(context.Background())
	assert.Equal(t, 2, *calls, "a failed run retries")
}

// The owner's text must reach the model on stdin only: a fake claude records
// its argv and stdin, and the secret must be absent from the former.
func TestPhaseInstructionSuggestions_GeneratorIsStdinOnly(t *testing.T) {
	dir := t.TempDir()
	argvFile, stdinFile := filepath.Join(dir, "argv"), filepath.Join(dir, "stdin")
	script := filepath.Join(dir, "claude")
	body := "#!/bin/sh\nprintf '%s\\n' \"$@\" > '" + argvFile + "'\ncat > '" + stdinFile + "'\necho '{}'\n"
	require.NoError(t, os.WriteFile(script, []byte(body), 0o700))

	cfg := &config.Config{ClaudePath: script}
	gen := instructionGeneratorFactory(cfg)
	const secret = "OWNER-SECRET-DIRECTION"
	_, _, _, _ = gen.Generate(context.Background(), "system prompt", secret, "") // output shape is irrelevant

	argv, err := os.ReadFile(argvFile)
	require.NoError(t, err)
	stdin, err := os.ReadFile(stdinFile)
	require.NoError(t, err)
	assert.NotContains(t, string(argv), secret, "owner text must never be on argv")
	assert.True(t, strings.Contains(string(stdin), secret), "owner text goes on stdin")
}
