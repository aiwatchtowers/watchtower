package db

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestHasAnyBriefing_EmptyFalse(t *testing.T) {
	database := OpenTestDB(t)

	has, err := database.HasAnyBriefing()
	require.NoError(t, err)
	assert.False(t, has)
}

func TestHasAnyBriefing_OneRowTrue(t *testing.T) {
	database := OpenTestDB(t)
	_, err := database.UpsertBriefing(makeBriefing("U1", time.Now().Format("2006-01-02")))
	require.NoError(t, err)

	has, err := database.HasAnyBriefing()
	require.NoError(t, err)
	assert.True(t, has)
}

func TestHasAnyDayPlan_EmptyFalse(t *testing.T) {
	database := OpenTestDB(t)

	has, err := database.HasAnyDayPlan()
	require.NoError(t, err)
	assert.False(t, has)
}

func TestHasAnyDayPlan_OneRowTrue(t *testing.T) {
	database := OpenTestDB(t)
	_, err := database.CreateDayPlan(&DayPlan{
		UserID: "U1", PlanDate: time.Now().Format("2006-01-02"),
		Status: DayPlanStatusActive, GeneratedAt: time.Now(),
	})
	require.NoError(t, err)

	has, err := database.HasAnyDayPlan()
	require.NoError(t, err)
	assert.True(t, has)
}
