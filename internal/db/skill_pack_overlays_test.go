package db

import (
	"errors"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestSkillPackOverlays_EditAndList(t *testing.T) {
	d := openTestDB(t)
	now := time.Date(2026, 11, 10, 9, 0, 0, 0, time.UTC)
	p1, err := d.InsertCoachProposal(coachFixture("o1"), now)
	require.NoError(t, err)

	added, err := d.EditSkillPackOverlays("watchtower-workbench", nil, []SkillPackOverlay{
		{Text: "Be brief.", ProposalID: p1},
		{Text: "Cite ids."},
	}, now)
	require.NoError(t, err)
	require.Len(t, added, 2)
	_, err = d.EditSkillPackOverlays("watchtower-flow", nil, []SkillPackOverlay{{Text: "Plan first."}}, now)
	require.NoError(t, err)

	got, err := d.ListSkillPackOverlays("watchtower-workbench")
	require.NoError(t, err)
	require.Len(t, got, 2)
	assert.Equal(t, "Be brief.", got[0].Text)
	assert.Equal(t, p1, got[0].ProposalID)
	assert.Equal(t, int64(0), got[1].ProposalID)
	assert.True(t, got[0].CreatedAt.Equal(now))

	// Removing a row of another skill is refused and changes nothing.
	_, err = d.EditSkillPackOverlays("watchtower-flow", []int64{added[0]}, []SkillPackOverlay{{Text: "x"}}, now)
	require.True(t, errors.Is(err, ErrCoachStateChanged), "got %v", err)

	_, err = d.EditSkillPackOverlays("watchtower-workbench", []int64{added[0]}, nil, now)
	require.NoError(t, err)

	all, err := d.AllSkillPackOverlays()
	require.NoError(t, err)
	assert.Equal(t, map[string][]string{
		"watchtower-workbench": {"Cite ids."},
		"watchtower-flow":      {"Plan first."},
	}, all)
}

func TestSkillPackOverlays_ProposalDeleteKeepsTheLine(t *testing.T) {
	d := openTestDB(t)
	now := time.Date(2026, 11, 10, 9, 0, 0, 0, time.UTC)
	p1, err := d.InsertCoachProposal(coachFixture("o2"), now)
	require.NoError(t, err)
	_, err = d.EditSkillPackOverlays("watchtower-workbench", nil, []SkillPackOverlay{{Text: "Be brief.", ProposalID: p1}}, now)
	require.NoError(t, err)
	_, err = d.Exec(`DELETE FROM coach_proposals WHERE id = ?`, p1)
	require.NoError(t, err)
	got, err := d.ListSkillPackOverlays("watchtower-workbench")
	require.NoError(t, err)
	require.Len(t, got, 1)
	assert.Equal(t, int64(0), got[0].ProposalID)
}
