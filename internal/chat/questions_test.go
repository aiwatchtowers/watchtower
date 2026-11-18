package chat

import (
	"encoding/json"
	"os"
	"testing"

	"github.com/stretchr/testify/require"
)

type questionCase struct {
	Name     string        `json:"name"`
	Text     string        `json:"text"`
	Final    bool          `json:"final"`
	Rest     string        `json:"rest"`
	Card     *QuestionCard `json:"card"`
	Readable string        `json:"readable"`
}

// One fixture, read by the Swift twin (QuestionParseFixtureTests) too.
func TestQuestionParse_SharedCases(t *testing.T) {
	raw, err := os.ReadFile("testdata/question_parse_cases.json")
	require.NoError(t, err)
	var cases []questionCase
	require.NoError(t, json.Unmarshal(raw, &cases))
	require.GreaterOrEqual(t, len(cases), 20)
	for _, tc := range cases {
		t.Run(tc.Name, func(t *testing.T) {
			rest, card := ParseQuestionCard(tc.Text, tc.Final)
			require.Equal(t, tc.Rest, rest)
			require.Equal(t, tc.Card, card)
			require.Equal(t, tc.Readable, QuestionReadableText(tc.Text))
		})
	}
}
