package db

import (
	"database/sql"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// policyHygieneMigration is the version of 00195_policy_hygiene.sql.
const policyHygieneMigration = 195

// TestMigration_PeopleSurveillanceCleared replays goose to the version
// before 00195, seeds a card with the dropped fields set, a summary with an
// attention list and one row in each legacy table, applies 00195 and checks
// the fields are back at their defaults and the legacy tables are empty.
// Running the Up's data statements again changes nothing.
func TestMigration_PeopleSurveillanceCleared(t *testing.T) {
	t.Parallel()
	raw, err := sql.Open("sqlite3", ":memory:")
	require.NoError(t, err)
	defer raw.Close()
	raw.SetMaxOpenConns(1)
	require.NoError(t, gooseUpTo(raw, "migrations", policyHygieneMigration-1))
	for _, q := range []string{
		`INSERT INTO people_cards (user_id, period_from, period_to, active_hours_json, volume_change_pct, avg_message_length, red_flags, summary)
			VALUES ('1:UP1', 100, 200, '{"9":3}', -40, 80, '["x"]', 'kept')`,
		`INSERT INTO people_card_summaries (period_from, period_to, summary, attention) VALUES (100, 200, 'kept', '["y"]')`,
		`INSERT INTO user_analyses (user_id, period_from, period_to) VALUES ('1:UP1', 100, 200)`,
		`INSERT INTO user_interactions (user_a, user_b, period_from, period_to) VALUES ('1:UOWN', '1:UP1', 100, 200)`,
		`INSERT INTO feedback (entity_type, entity_id, rating) VALUES ('user_analysis', '1', 1), ('digest', '7', 1)`,
	} {
		_, err := raw.Exec(q)
		require.NoError(t, err, q)
	}

	require.NoError(t, gooseUpTo(raw, "migrations", policyHygieneMigration))

	type state struct {
		hours, flags, summary, attention, summarySummary string
		volume, avgLen                                   float64
		analyses, interactions, analysisFeedback, other  int
	}
	read := func() state {
		var s state
		require.NoError(t, raw.QueryRow(`SELECT active_hours_json, volume_change_pct, avg_message_length, red_flags, summary
			FROM people_cards WHERE user_id = '1:UP1'`).Scan(&s.hours, &s.volume, &s.avgLen, &s.flags, &s.summary))
		require.NoError(t, raw.QueryRow(`SELECT attention, summary FROM people_card_summaries`).Scan(&s.attention, &s.summarySummary))
		require.NoError(t, raw.QueryRow(`SELECT COUNT(*) FROM user_analyses`).Scan(&s.analyses))
		require.NoError(t, raw.QueryRow(`SELECT COUNT(*) FROM user_interactions`).Scan(&s.interactions))
		require.NoError(t, raw.QueryRow(`SELECT COUNT(*) FROM feedback WHERE entity_type = 'user_analysis'`).Scan(&s.analysisFeedback))
		require.NoError(t, raw.QueryRow(`SELECT COUNT(*) FROM feedback WHERE entity_type != 'user_analysis'`).Scan(&s.other))
		return s
	}
	got := read()
	assert.Equal(t, state{hours: "{}", flags: "[]", summary: "kept", attention: "[]", summarySummary: "kept", other: 1}, got)

	var emoji int
	require.NoError(t, raw.QueryRow(`SELECT COUNT(*) FROM pragma_table_info('slack_accounts') WHERE name = 'emoji_scope_missing'`).Scan(&emoji))
	assert.Equal(t, 1, emoji, "slack_accounts.emoji_scope_missing added")

	// The Up's data statements (everything but the one-shot ALTER) again.
	for _, q := range policyHygieneUpStatements(t) {
		if strings.HasPrefix(q, "ALTER TABLE") {
			continue
		}
		_, err := raw.Exec(q)
		require.NoError(t, err, q)
	}
	assert.Equal(t, got, read(), "a second run changes nothing")
}

// policyHygieneUpStatements returns the Up section's statements, comments
// stripped.
func policyHygieneUpStatements(t *testing.T) []string {
	t.Helper()
	body, err := migrationsFS.ReadFile("migrations/00195_policy_hygiene.sql")
	require.NoError(t, err)
	up, _, ok := strings.Cut(string(body), "-- +goose Down")
	require.True(t, ok)
	var lines []string
	for _, l := range strings.Split(up, "\n") {
		if !strings.HasPrefix(strings.TrimSpace(l), "--") {
			lines = append(lines, l)
		}
	}
	var stmts []string
	for _, s := range strings.Split(strings.Join(lines, "\n"), ";") {
		if s = strings.TrimSpace(s); s != "" {
			stmts = append(stmts, s)
		}
	}
	require.GreaterOrEqual(t, len(stmts), 7)
	return stmts
}
