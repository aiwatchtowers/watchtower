package customtracks

import (
	"os"
	"regexp"
	"sort"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/prompts"
)

// TestCustomTracksPromptsTakeNoAdditions pins the prompts the custom-tracks
// pipeline loads (straight from the DB, never through prompts.Resolve) to the
// ids prompts.TakesAdditions refuses.
func TestCustomTracksPromptsTakeNoAdditions(t *testing.T) {
	src, err := os.ReadFile("pipeline.go")
	require.NoError(t, err)
	seen := map[string]bool{}
	for _, m := range regexp.MustCompile(`promptFor\(prompts\.(\w+)\)`).FindAllStringSubmatch(string(src), -1) {
		seen[m[1]] = true
	}
	var got []string
	for k := range seen {
		got = append(got, k)
	}
	sort.Strings(got)
	assert.Equal(t, []string{"TrackCompose", "TrackRun", "TrackShortlist"}, got)
	for _, id := range []string{prompts.TrackRun, prompts.TrackShortlist, prompts.TrackCompose} {
		assert.False(t, prompts.TakesAdditions(id), id)
	}
}
