package memory

import (
	"fmt"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/prompts"
)

func extractTestWindow(runningSummary string) channelWindow {
	return channelWindow{
		ChannelID:      "C1GEN",
		ChannelName:    "general",
		RunningSummary: runningSummary,
		Messages: []extractMsg{
			{TS: "1752570000.000100", Author: "alice", Text: "the deploy to prod failed"},
			{TS: "1752570060.000200", Author: "bob", Text: "rolling back now"},
		},
	}
}

func TestBuildExtractPromptContents(t *testing.T) {
	tmpl := prompts.Defaults[prompts.MemoryExtractEpisodes]
	require.NotEmpty(t, tmpl, "memory.extract_episodes registered in prompt defaults")
	system, user := buildExtractPrompt(tmpl, "English", extractTestWindow(""), 5)

	assert.Contains(t, user, "[1752570000.000100] alice: the deploy to prod failed")
	assert.Contains(t, user, "[1752570060.000200] bob: rolling back now")
	assert.Contains(t, user, "general")
	assert.Contains(t, user, "C1GEN")
	assert.Contains(t, system, "copy ts values EXACTLY from the input, never invent or adjust them")
	assert.Contains(t, system, "at most 5 episodes")
	assert.Contains(t, system, "[]", "instructs returning an empty array for routine chatter")
	assert.NotContains(t, system, "%!", "no unconsumed or mismatched fmt verbs in the rendered template")
}

func TestBuildExtractPromptLanguageDirective(t *testing.T) {
	tmpl := prompts.Defaults[prompts.MemoryExtractEpisodes]

	system, _ := buildExtractPrompt(tmpl, "Ukrainian", extractTestWindow(""), 5)
	assert.True(t, prompts.HasDirective(system), "system prompt carries the language directive")
	assert.Contains(t, system, "Respond ONLY in Ukrainian")

	// Empty language falls back to the default, never to a directive-less prompt.
	system, _ = buildExtractPrompt(tmpl, "", extractTestWindow(""), 5)
	assert.True(t, prompts.HasDirective(system))
	assert.Contains(t, system, prompts.DefaultLanguage)
}

func TestBuildExtractPromptRunningSummary(t *testing.T) {
	tmpl := prompts.Defaults[prompts.MemoryExtractEpisodes]
	_, withSummary := buildExtractPrompt(tmpl, "English", extractTestWindow("Migration to the new billing stack in progress."), 5)
	assert.Contains(t, withSummary, "Running summary: Migration to the new billing stack in progress.")

	_, withoutSummary := buildExtractPrompt(tmpl, "English", extractTestWindow(""), 5)
	assert.NotContains(t, withoutSummary, "Running summary:")
}

const extractFixtureJSON = `[
  {
    "title": "Prod deploy failed",
    "story": "The deploy failed and was rolled back.",
    "outcome": "rolled back",
    "participants": ["U1ALICE", "U2BOB"],
    "refs": [{"channel_id": "C1GEN", "ts": "1752570000.000100"}],
    "entity_hints": ["C1GEN"]
  }
]`

func TestParseExtractBareJSON(t *testing.T) {
	eps, err := parseExtract(extractFixtureJSON)
	require.NoError(t, err)
	require.Len(t, eps, 1)
	assert.Equal(t, "Prod deploy failed", eps[0].Title)
	require.NotNil(t, eps[0].Outcome)
	assert.Equal(t, "rolled back", *eps[0].Outcome)
	assert.Equal(t, []string{"U1ALICE", "U2BOB"}, eps[0].Participants)
	require.Len(t, eps[0].Refs, 1)
	assert.Equal(t, "C1GEN", eps[0].Refs[0].ChannelID)
	assert.Equal(t, "1752570000.000100", eps[0].Refs[0].TS)
	assert.Equal(t, []string{"C1GEN"}, eps[0].EntityHints)
}

func TestParseExtractFencedJSON(t *testing.T) {
	eps, err := parseExtract("```json\n" + extractFixtureJSON + "\n```")
	require.NoError(t, err)
	require.Len(t, eps, 1)
	assert.Equal(t, "Prod deploy failed", eps[0].Title)
}

func TestParseExtractEmptyArray(t *testing.T) {
	for _, raw := range []string{"[]", "```json\n[]\n```", "  []  "} {
		eps, err := parseExtract(raw)
		require.NoError(t, err, "raw %q", raw)
		assert.Empty(t, eps, "raw %q", raw)
	}
}

func TestParseExtractGarbage(t *testing.T) {
	for _, raw := range []string{"", "not json at all", "{\"title\": \"an object, not an array\"}", "[{broken"} {
		_, err := parseExtract(raw)
		assert.Error(t, err, "raw %q", raw)
	}
}

// TestMemory01_HallucinatedRefsDropped guards MEM-01: no message ref reaches
// the vault unless it resolves against the messages table at write time. A
// year-shifted (hallucinated) ts is dropped; an episode whose refs all fail
// is discarded entirely.
func TestMemory01_HallucinatedRefsDropped(t *testing.T) {
	d := newTestDB(t)
	_, err := d.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('C1GEN', '1752570000.000100', 'U1ALICE', 'the deploy to prod failed')`)
	require.NoError(t, err)

	outcome := "rolled back"
	eps := []extractedEpisode{
		{
			Title:   "Prod deploy failed",
			Story:   "The deploy failed and was rolled back.",
			Outcome: &outcome,
			Refs: []episodeRef{
				{ChannelID: "C1GEN", TS: "1752570000.000100"}, // resolves
				{ChannelID: "C1GEN", TS: "1721034000.000100"}, // year-shifted: hallucinated
			},
		},
		{
			Title: "Entirely hallucinated",
			Story: "No ref survives validation.",
			Refs: []episodeRef{
				{ChannelID: "C9NOPE", TS: "1752570000.000100"}, // wrong channel
			},
		},
	}

	kept, dropped, err := validateRefs(d, eps)
	require.NoError(t, err)
	require.Len(t, kept, 1, "episode with zero surviving refs is discarded")
	assert.Equal(t, "Prod deploy failed", kept[0].Title)
	require.Len(t, kept[0].Refs, 1)
	assert.Equal(t, "1752570000.000100", kept[0].Refs[0].TS)
	assert.Equal(t, 2, dropped, "dropped counts refs: one hallucinated ts + the discarded episode's one ref")
}

func TestValidateRefsAllGood(t *testing.T) {
	d := newTestDB(t)
	_, err := d.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('C1GEN', '1752570000.000100', 'U1ALICE', 'hello')`)
	require.NoError(t, err)

	eps := []extractedEpisode{{Title: "T", Story: "S", Refs: []episodeRef{{ChannelID: "C1GEN", TS: "1752570000.000100"}}}}
	kept, dropped, err := validateRefs(d, eps)
	require.NoError(t, err)
	assert.Len(t, kept, 1)
	assert.Zero(t, dropped)
}

// errCheckerAfter delegates to a real DB but fails with a lookup ERROR on a
// specific ref — simulating a transient DB failure mid-validation.
type errCheckerAfter struct {
	db     messageChecker
	failTS string
}

func (c errCheckerAfter) MessageExists(channelID, ts string) (bool, error) {
	if ts == c.failTS {
		return false, fmt.Errorf("disk I/O error")
	}
	return c.db.MessageExists(channelID, ts)
}

// TestMemory01_LookupErrorIsNotAnInvalidRef extends the MEM-01 guard family:
// a lookup ERROR must surface as an error from validateRefs — never be
// conflated with a positively-invalid ref and silently counted as dropped.
func TestMemory01_LookupErrorIsNotAnInvalidRef(t *testing.T) {
	d := newTestDB(t)
	_, err := d.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('C1GEN', '1752570000.000100', 'U1ALICE', 'hello')`)
	require.NoError(t, err)

	eps := []extractedEpisode{{Title: "T", Story: "S", Refs: []episodeRef{
		{ChannelID: "C1GEN", TS: "1752570000.000100"},
		{ChannelID: "C1GEN", TS: "1752570060.000200"},
	}}}
	checker := errCheckerAfter{db: d, failTS: "1752570060.000200"}

	kept, dropped, err := validateRefs(checker, eps)
	require.Error(t, err, "a lookup error must propagate, not count as dropped")
	assert.Contains(t, err.Error(), "disk I/O error")
	assert.Empty(t, kept)
	assert.Zero(t, dropped)
}

// TestSplitMalformedZeroRefEpisodes: an episode that parsed but carries zero
// refs (misnamed key, wrong nesting) is shape-degenerate — split out and
// counted, never treated as a valid episode or as routine chatter.
func TestSplitMalformedZeroRefEpisodes(t *testing.T) {
	eps, err := parseExtract(`[
		{"title": "Prod deploy failed", "story": "It broke.", "references": [{"channel_id": "C1GEN", "ts": "1752570000.000100"}]},
		{"title": "Kept", "story": "Fine.", "refs": [{"channel_id": "C1GEN", "ts": "1752570000.000100"}]}
	]`)
	require.NoError(t, err)
	require.Len(t, eps, 2)

	valid, malformed := splitMalformed(eps)
	assert.Equal(t, 1, malformed, "misnamed refs key unmarshals to zero refs → malformed")
	require.Len(t, valid, 1)
	assert.Equal(t, "Kept", valid[0].Title)

	valid, malformed = splitMalformed(nil)
	assert.Zero(t, malformed, "empty array stays a clean no-episode window")
	assert.Empty(t, valid)
}
