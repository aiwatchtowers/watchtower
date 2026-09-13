package memory

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// addSlackAccount inserts one slack_accounts row with an explicit id (the
// migration namespaces bare ids with whatever the single connected account's
// id happens to be, so the fixtures pin a non-1 id).
func addSlackAccount(t *testing.T, d *db.DB, id int64, status string, enabled bool) {
	t.Helper()
	_, err := d.Exec(`INSERT INTO slack_accounts (id, team_id, team_name, current_user_id, status, enabled)
		VALUES (?,?,?,?,?,?)`, id, "T00"+status, "team", "7:UOWNER", status, enabled)
	require.NoError(t, err)
}

// addJiraIssue inserts one jira_issues row (with its account) so a project key
// exists in the database.
func addJiraIssue(t *testing.T, d *db.DB, projectKey, key string) {
	t.Helper()
	_, err := d.Exec(`INSERT OR IGNORE INTO jira_accounts (id, cloud_id) VALUES (1, 'cloud')`)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO jira_issues
		(account_id, key, project_key, summary, status, status_category, created_at, updated_at, synced_at)
		VALUES (1,?,?,?,?,?,?,?,?)`,
		key, projectKey, "sum", "Open", "new", "2026-09-01T00:00:00Z", "2026-09-01T00:00:00Z", "2026-09-01T00:00:00Z")
	require.NoError(t, err)
}

// slackIDFixture writes one person entity (bare user-id alias plus an e-mail)
// and one episode whose provenance mixes a bare Slack channel ref with a mail
// ref, then indexes them.
func slackIDFixture(t *testing.T, v *Vault, d *db.DB) (person, episode Node) {
	t.Helper()
	person = vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5SI1", "entity", "Alice")
	person.Aliases = []string{"U0123ABCD", "alice@example.com"}
	episode = vaultTestNode("ep_01ARZ3NDEKTSV4RRFFQ69G5SI2", "episode", "Rollout")
	episode.Body = "# Rollout\n\n## Story\nIt shipped.\n\n## Provenance\n" +
		"- C0123ABCD 1700000000.000100\n- mail:abc123 1700000500\n"
	writeNodes(t, v, person, episode)
	_, err := Reconcile(v, d, t.Logf)
	require.NoError(t, err)
	return person, episode
}

// TestMigrateSlackIDsRewritesAliasesAndProvenance: bare Slack ids on aliases
// and in "" -scheme provenance refs become namespaced; e-mail aliases and
// mail: refs are left alone; the vault gets one commit and the index is
// rebuilt from it.
func TestMigrateSlackIDsRewritesAliasesAndProvenance(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	addSlackAccount(t, d, 7, "ok", true)
	person, episode := slackIDFixture(t, v, d)

	stats, err := MigrateSlackIDs(v, d, false, t.Logf)
	require.NoError(t, err)
	assert.Equal(t, int64(7), stats.AccountID)
	assert.Equal(t, 2, stats.NodesChanged)
	assert.Equal(t, 1, stats.AliasRewrites)
	assert.Equal(t, 1, stats.ProvenanceRewrites)
	assert.Equal(t, map[string]int{"entity": 1, "episode": 1}, stats.ByType)
	assert.True(t, stats.Committed)

	got, err := v.ReadNode(person.ID)
	require.NoError(t, err)
	assert.Equal(t, []string{"7:U0123ABCD", "alice@example.com"}, got.Aliases)

	gotEp, err := v.ReadNode(episode.ID)
	require.NoError(t, err)
	assert.Contains(t, gotEp.Body, "- 7:C0123ABCD 1700000000.000100")
	assert.Contains(t, gotEp.Body, "- mail:abc123 1700000500", "a mail: ref is not a Slack id")

	head := headCommit(t, openTestRepo(t, v.path))
	assert.Contains(t, head.Message, "memory(migrate): slack ids → namespaced (2 nodes)")
	assert.Contains(t, head.Message, "Cause: migrate")

	// The index was rebuilt from the migrated files.
	nodeID, err := d.LookupMemoryAlias("7:U0123ABCD")
	require.NoError(t, err)
	assert.Equal(t, person.ID, nodeID)
	var channel string
	require.NoError(t, d.QueryRow(`SELECT channel_id FROM memory_provenance WHERE scheme = '' AND node_id = ?`,
		episode.ID).Scan(&channel))
	assert.Equal(t, "7:C0123ABCD", channel)
}

// TestMigrateSlackIDsIsIdempotent: a second run finds nothing to do and makes
// no commit.
func TestMigrateSlackIDsIsIdempotent(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	addSlackAccount(t, d, 7, "ok", true)
	slackIDFixture(t, v, d)

	_, err := MigrateSlackIDs(v, d, false, t.Logf)
	require.NoError(t, err)
	afterFirst := headHash(t, v)

	stats, err := MigrateSlackIDs(v, d, false, t.Logf)
	require.NoError(t, err)
	assert.Zero(t, stats.NodesChanged)
	assert.False(t, stats.Committed)
	assert.Equal(t, afterFirst, headHash(t, v), "nothing to migrate — no second commit")
}

// TestMigrateSlackIDsDryRunWritesNothing: the preview counts the work and
// samples it without touching the vault or the index.
func TestMigrateSlackIDsDryRunWritesNothing(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	addSlackAccount(t, d, 7, "ok", true)
	person, _ := slackIDFixture(t, v, d)
	before := headHash(t, v)

	stats, err := MigrateSlackIDs(v, d, true, t.Logf)
	require.NoError(t, err)
	assert.Equal(t, 2, stats.NodesChanged)
	assert.False(t, stats.Committed)
	assert.Equal(t, []string{person.ID + ": U0123ABCD → 7:U0123ABCD"}, stats.AliasSamples,
		"every alias rewrite is listed, not sampled")
	assert.Len(t, stats.ProvenanceSamples, 1)

	assert.Equal(t, before, headHash(t, v))
	got, err := v.ReadNode(person.ID)
	require.NoError(t, err)
	assert.Equal(t, []string{"U0123ABCD", "alice@example.com"}, got.Aliases)
}

// TestMigrateSlackIDsRefusesWithTwoAccounts: which account a bare id belongs
// to is not guessable, so two rows — even a disabled/removed one — refuse the
// whole migration.
func TestMigrateSlackIDsRefusesWithTwoAccounts(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	addSlackAccount(t, d, 7, "ok", true)
	addSlackAccount(t, d, 8, "removed", false)
	person, _ := slackIDFixture(t, v, d)
	before := headHash(t, v)

	_, err := MigrateSlackIDs(v, d, false, t.Logf)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "2 Slack accounts")

	assert.Equal(t, before, headHash(t, v))
	got, err := v.ReadNode(person.ID)
	require.NoError(t, err)
	assert.Equal(t, []string{"U0123ABCD", "alice@example.com"}, got.Aliases)
}

// TestMigrateSlackIDsRefusesWithNoAccount: with nothing connected there is no
// account id to namespace with.
func TestMigrateSlackIDsRefusesWithNoAccount(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	slackIDFixture(t, v, d)

	_, err := MigrateSlackIDs(v, d, true, t.Logf)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "no Slack account")
}

// TestMigrateSlackIDsLeavesJiraProjectKeyAlone: a Jira project key aliased on
// its own entity page (seedJiraProjects writes exactly that) can match the
// bare-Slack-id shape; namespacing it would break the key's only alias.
func TestMigrateSlackIDsLeavesJiraProjectKeyAlone(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	addSlackAccount(t, d, 7, "ok", true)
	addJiraIssue(t, d, "CUSTOMERAPP", "CUSTOMERAPP-1")

	project := vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5SJ1", "entity", "CUSTOMERAPP")
	project.Aliases = []string{"CUSTOMERAPP"}
	writeNodes(t, v, project)
	_, err := Reconcile(v, d, t.Logf)
	require.NoError(t, err)

	stats, err := MigrateSlackIDs(v, d, false, t.Logf)
	require.NoError(t, err)
	assert.Zero(t, stats.NodesChanged)

	got, err := v.ReadNode(project.ID)
	require.NoError(t, err)
	assert.Equal(t, []string{"CUSTOMERAPP"}, got.Aliases)
}

// TestMigrateSlackIDsSkipsAliasOwnedByAnotherNode: when the namespaced form
// already belongs to a different page, rewriting would collide on the UNIQUE
// alias constraint — the bare alias is left alone and counted instead.
func TestMigrateSlackIDsSkipsAliasOwnedByAnotherNode(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	addSlackAccount(t, d, 7, "ok", true)

	legacy := vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5SK1", "entity", "Alice (legacy)")
	legacy.Aliases = []string{"U0123ABCD"}
	current := vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5SK2", "entity", "Alice")
	current.Aliases = []string{"7:U0123ABCD"}
	writeNodes(t, v, legacy, current)
	_, err := Reconcile(v, d, t.Logf)
	require.NoError(t, err)

	stats, err := MigrateSlackIDs(v, d, false, t.Logf)
	require.NoError(t, err)
	assert.Zero(t, stats.NodesChanged)
	assert.Equal(t, 1, stats.Conflicts)

	got, err := v.ReadNode(legacy.ID)
	require.NoError(t, err)
	assert.Equal(t, []string{"U0123ABCD"}, got.Aliases)
}

// TestMigrateSlackIDsMergesDuplicateAliasOnOneNode: a page stitched with both
// spellings of one id (the seeder's identity stitching) keeps only the
// namespaced one — re-adding the same alias twice would break the index write.
func TestMigrateSlackIDsMergesDuplicateAliasOnOneNode(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	addSlackAccount(t, d, 7, "ok", true)

	stitched := vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5SL1", "entity", "Alice")
	stitched.Aliases = []string{"U0123ABCD", "7:U0123ABCD", "alice@example.com"}
	writeNodes(t, v, stitched)
	_, err := Reconcile(v, d, t.Logf)
	require.NoError(t, err)

	stats, err := MigrateSlackIDs(v, d, false, t.Logf)
	require.NoError(t, err)
	assert.Equal(t, 1, stats.NodesChanged)

	got, err := v.ReadNode(stitched.ID)
	require.NoError(t, err)
	assert.Equal(t, []string{"7:U0123ABCD", "alice@example.com"}, got.Aliases)
}

// TestMigrateSlackIDsRewritesOnlyOneOfTwoDuplicatePages: the seeder bug minted
// duplicate pages carrying the same bare alias. Rewriting both would point two
// pages at one namespaced alias, so the first claims it and the second is left
// alone as a conflict (a merge, not this migration's business).
func TestMigrateSlackIDsRewritesOnlyOneOfTwoDuplicatePages(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	addSlackAccount(t, d, 7, "ok", true)

	first := vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5SM1", "entity", "Alice")
	first.Aliases = []string{"U0123ABCD"}
	second := vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5SM2", "entity", "Alice (duplicate)")
	second.Aliases = []string{"U0123ABCD"}
	writeNodes(t, v, first, second)

	stats, err := MigrateSlackIDs(v, d, false, t.Logf)
	require.NoError(t, err)
	assert.Equal(t, 1, stats.NodesChanged)
	assert.Equal(t, 1, stats.Conflicts)

	got, err := v.ReadNode(first.ID)
	require.NoError(t, err)
	assert.Equal(t, []string{"7:U0123ABCD"}, got.Aliases)
	dup, err := v.ReadNode(second.ID)
	require.NoError(t, err)
	assert.Equal(t, []string{"U0123ABCD"}, dup.Aliases)
}
