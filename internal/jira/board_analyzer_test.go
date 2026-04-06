package jira

import (
	"testing"

	"watchtower/internal/db"

	"github.com/stretchr/testify/assert"
)

func TestBuildFallbackProfile(t *testing.T) {
	rawData := &BoardRawData{
		BoardName:  "Sprint Board",
		ProjectKey: "PROJ",
		BoardType:  "scrum",
		Config: BoardConfig{
			Columns: []BoardColumn{
				{Name: "To Do", Statuses: []BoardColumnStatus{{Name: "Open"}}},
				{Name: "In Progress", Statuses: []BoardColumnStatus{{Name: "In Progress"}}},
				{Name: "Code Review", Statuses: []BoardColumnStatus{{Name: "In Review"}}},
				{Name: "Done", Statuses: []BoardColumnStatus{{Name: "Done"}, {Name: "Closed"}}},
			},
			Estimation: &EstimationField{FieldID: "story_points", DisplayName: "Story Points"},
		},
		Sprints: []SprintSummary{
			{Name: "Sprint 1", State: "active"},
		},
	}

	profile := BuildFallbackProfile(rawData)

	assert.Len(t, profile.WorkflowStages, 4)
	assert.Equal(t, "backlog", profile.WorkflowStages[0].Phase)
	assert.Equal(t, "active_work", profile.WorkflowStages[1].Phase)
	assert.Equal(t, "active_work", profile.WorkflowStages[2].Phase)
	assert.Equal(t, "done", profile.WorkflowStages[3].Phase)
	assert.True(t, profile.WorkflowStages[3].IsTerminal)

	assert.Equal(t, "story_points", profile.EstimationApproach.Type)
	assert.True(t, profile.IterationInfo.HasIterations)

	assert.Contains(t, profile.WorkflowSummary, "scrum")
	assert.Greater(t, len(profile.StaleThresholds), 0)
}

func TestBuildFallbackProfile_NoEstimation(t *testing.T) {
	rawData := &BoardRawData{
		BoardType: "kanban",
		Config:    BoardConfig{},
	}

	profile := BuildFallbackProfile(rawData)
	assert.Equal(t, "none", profile.EstimationApproach.Type)
	assert.False(t, profile.IterationInfo.HasIterations)
}

func TestComputeConfigHash(t *testing.T) {
	rawData1 := &BoardRawData{
		Config: BoardConfig{
			Columns: []BoardColumn{
				{Name: "A", Statuses: []BoardColumnStatus{{Name: "Open"}}},
			},
		},
	}
	rawData2 := &BoardRawData{
		Config: BoardConfig{
			Columns: []BoardColumn{
				{Name: "B", Statuses: []BoardColumnStatus{{Name: "Open"}}},
			},
		},
	}

	hash1 := ComputeConfigHash(rawData1)
	hash2 := ComputeConfigHash(rawData2)
	assert.NotEqual(t, hash1, hash2, "different configs should have different hashes")

	// Same config should produce same hash.
	hash1b := ComputeConfigHash(rawData1)
	assert.Equal(t, hash1, hash1b, "same config should have same hash")
}

func TestGetEffectiveStaleThresholds(t *testing.T) {
	tests := []struct {
		name      string
		profile   string
		overrides string
		expected  map[string]int
	}{
		{
			name:     "profile only",
			profile:  `{"stale_thresholds":{"Review":3,"QA":5}}`,
			expected: map[string]int{"Review": 3, "QA": 5},
		},
		{
			name:      "with override",
			profile:   `{"stale_thresholds":{"Review":3,"QA":5}}`,
			overrides: `{"stale_thresholds":{"Review":1}}`,
			expected:  map[string]int{"Review": 1, "QA": 5},
		},
		{
			name:     "empty profile",
			expected: map[string]int{},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			board := db.JiraBoard{
				LLMProfileJSON:    tt.profile,
				UserOverridesJSON: tt.overrides,
			}
			result, err := GetEffectiveStaleThresholds(board)
			assert.NoError(t, err)
			assert.Equal(t, tt.expected, result)
		})
	}
}

func TestExtractJSON(t *testing.T) {
	tests := []struct {
		input    string
		expected string
	}{
		{`{"key":"value"}`, `{"key":"value"}`},
		{"```json\n{\"key\":\"value\"}\n```", `{"key":"value"}`},
		{"```\n{\"key\":\"value\"}\n```", `{"key":"value"}`},
		{"  {\"key\":\"value\"}  ", `{"key":"value"}`},
	}

	for _, tt := range tests {
		result := extractJSON(tt.input)
		assert.Equal(t, tt.expected, result)
	}
}
