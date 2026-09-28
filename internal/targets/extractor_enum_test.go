package targets

import (
	"context"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// A model-emitted level/priority outside the targets table's case-sensitive
// CHECK constraints is normalized (lower-cased) or replaced by the default,
// and an empty-text item is dropped — so the confirmed batch, one
// transaction, inserts every remaining row instead of rolling back.
func TestParseExtractResponse_NormalizesLevelPriorityAndDropsEmptyText(t *testing.T) {
	raw := `{"extracted": [
		{"text": "Mixed case", "level": "Week", "priority": "High"},
		{"text": "Padded", "level": " month ", "priority": "LOW "},
		{"text": "Unknown values", "level": "sprint", "priority": "urgent"},
		{"text": "Missing values"},
		{"text": "   ", "level": "day", "priority": "high"},
		{"text": ""}
	]}`
	res, err := parseExtractResponse(raw, nil, nil)
	require.NoError(t, err)
	require.Len(t, res.Extracted, 4)

	type lp struct{ text, level, priority string }
	got := make([]lp, 0, len(res.Extracted))
	for _, pt := range res.Extracted {
		got = append(got, lp{pt.Text, pt.Level, pt.Priority})
	}
	assert.Equal(t, []lp{
		{"Mixed case", "week", "high"},
		{"Padded", "month", "low"},
		{"Unknown values", "day", "medium"},
		{"Missing values", "day", "medium"},
	}, got)

	d, err := db.Open(":memory:")
	require.NoError(t, err)
	defer d.Close()
	ids, err := NewStore(d).CreateBatch(context.Background(), res.Extracted, "extract", "")
	require.NoError(t, err, "normalized rows must satisfy the CHECK constraints")
	assert.Len(t, ids, 4)
}

func TestParseExtractResponse_NoItems(t *testing.T) {
	res, err := parseExtractResponse(`{"extracted": []}`, nil, nil)
	require.NoError(t, err)
	assert.Empty(t, res.Extracted)
}
