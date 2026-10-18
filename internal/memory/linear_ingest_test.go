package memory

import (
	"errors"
	"fmt"
	"testing"

	"watchtower/internal/db"
)

// seedLinearIssueExtract stores one Linear issue for builder tests (account
// accountID, which must exist).
func seedLinearIssueExtract(t *testing.T, d *db.DB, accountID int64, id, key, team, title, state, cat, completedAt, updatedAt, assigneeSlackID string, prevKeys ...string) {
	t.Helper()
	db.SeedLinearTestIssue(t, d, db.LinearIssue{
		AccountID: accountID, ID: id, Key: key, PreviousKeys: prevKeys, TeamKey: team, Title: title,
		DescriptionText: "Body of " + key, StateName: state, StatusCategory: cat, Priority: 2,
		AssigneeDisplayName: "Alice A", CreatorDisplayName: "Bob B", CompletedAt: completedAt,
		CreatedAt: "2026-07-01T00:00:00.000Z", UpdatedAt: updatedAt,
	}, assigneeSlackID, "")
}

func assertLinearWatermark(t *testing.T, d *db.DB, accountID int64, want float64) {
	t.Helper()
	wm, err := d.MemoryLinearWatermark(accountID)
	if err != nil {
		t.Fatalf("read linear watermark: %v", err)
	}
	if wm != want {
		t.Errorf("linear account %d watermark = %v, want %v", accountID, wm, want)
	}
}

// The first gated run initializes the watermark to the newest issue and builds
// nothing — no backfill, the Jira rule.
func TestRunLinearIngestNoBackfillInit(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	acct := db.SeedLinearTestAccount(t, d)
	seedLinearIssueExtract(t, d, acct, "u1", "ENG-1", "ENG", "old backlog", "Todo", "todo", "", "2026-07-20T10:00:00.000Z", "")
	p := NewPipeline(d, v, noCallGen(t), pipelineTestConfig(), t.Logf)

	var stats RunStats
	steps, err := p.runLinearIngest(1, 0, &stats)
	if err != nil || steps != 1 || stats.LinearEpisodes != 0 {
		t.Fatalf("init = steps %d, episodes %d, err %v; want 1,0,nil", steps, stats.LinearEpisodes, err)
	}
	assertLinearWatermark(t, d, acct, float64(mustParseJiraTime(t, "2026-07-20T10:00:00.000Z")))

	steps, err = p.runLinearIngest(2, 0, &stats)
	if err != nil || steps != 0 || stats.LinearEpisodes != 0 {
		t.Errorf("steady state = steps %d, episodes %d, err %v; want 0,0,nil", steps, stats.LinearEpisodes, err)
	}
}

// An issue above the watermark becomes one episode aliased by the issue's
// UUID, citing linear:<KEY>, back-linked to the team entity and the assignee;
// a done issue is born closed/long and the ref lands in memory_provenance.
func TestRunLinearIngestBuildsEpisode(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	acct := db.SeedLinearTestAccount(t, d)
	if err := d.SetMemoryLinearWatermark(acct, 1); err != nil {
		t.Fatal(err)
	}
	seedLinearIssueExtract(t, d, acct, "u7", "ENG-7", "ENG", "Ship the importer", "Done", "done",
		"2026-07-22T09:00:00.000Z", "2026-07-22T10:00:00.000Z", "U1ALICE")
	writeAndIndex(t, v, d, bareEntity("ent_00000000000000000000000eng", "ENG"))
	writeAndIndex(t, v, d, bareEntity("ent_0000000000000000000000alice", "U1ALICE"))
	p := NewPipeline(d, v, noCallGen(t), pipelineTestConfig(), t.Logf)

	var stats RunStats
	if _, err := p.runLinearIngest(1, 0, &stats); err != nil {
		t.Fatalf("runLinearIngest: %v", err)
	}
	if stats.LinearEpisodes != 1 {
		t.Fatalf("LinearEpisodes = %d, want 1", stats.LinearEpisodes)
	}
	id, err := d.LookupMemoryAlias(linearIssueAlias(acct, "u7"))
	if err != nil {
		t.Fatalf("alias lookup: %v", err)
	}
	n, err := v.ReadNode(id)
	if err != nil {
		t.Fatalf("read node: %v", err)
	}
	if n.Status != "closed" || n.Tier != "long" {
		t.Errorf("done issue: status/tier = %s/%s, want closed/long", n.Status, n.Tier)
	}
	wantUnix := mustParseJiraTime(t, "2026-07-22T10:00:00.000Z")
	assertBodyContains(t, n.Body,
		"# ENG-7: Ship the importer",
		"Status: Done (done).", "Priority: High.", "Assignee: Alice A.", "Creator: Bob B.",
		"Body of ENG-7",
		"Resolved (Done) at 2026-07-22T09:00:00.000Z",
		fmt.Sprintf("- linear:ENG-7 %d", wantUnix),
	)
	assertEntityBackLinks(t, v, []string{"ent_00000000000000000000000eng", "ent_0000000000000000000000alice"}, id)
	assertLinearWatermark(t, d, acct, float64(wantUnix))

	var provCount int
	if err := d.QueryRow(`SELECT COUNT(*) FROM memory_provenance WHERE node_id = ? AND scheme = 'linear' AND channel_id = 'linear:ENG-7'`, id).Scan(&provCount); err != nil {
		t.Fatalf("query memory_provenance: %v", err)
	}
	if provCount != 1 {
		t.Errorf("memory_provenance rows = %d, want 1", provCount)
	}
}

// A team move (ENG-7 → OPS-3) refreshes the SAME episode under the new key,
// and a ref minted under the old key still resolves (previous_keys).
func TestRunLinearIngestTeamMoveKeepsTheEpisode(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	acct := db.SeedLinearTestAccount(t, d)
	if err := d.SetMemoryLinearWatermark(acct, 1); err != nil {
		t.Fatal(err)
	}
	seedLinearIssueExtract(t, d, acct, "u7", "ENG-7", "ENG", "Ship it", "Todo", "todo", "", "2026-07-22T10:00:00.000Z", "")
	p := NewPipeline(d, v, noCallGen(t), pipelineTestConfig(), t.Logf)
	var stats RunStats
	if _, err := p.runLinearIngest(1, 0, &stats); err != nil {
		t.Fatal(err)
	}
	firstID, err := d.LookupMemoryAlias(linearIssueAlias(acct, "u7"))
	if err != nil {
		t.Fatal(err)
	}

	seedLinearIssueExtract(t, d, acct, "u7", "OPS-3", "OPS", "Ship it", "Todo", "todo", "", "2026-07-22T11:00:00.000Z", "", "ENG-7")
	if _, err := p.runLinearIngest(2, 0, &stats); err != nil {
		t.Fatal(err)
	}
	secondID, err := d.LookupMemoryAlias(linearIssueAlias(acct, "u7"))
	if err != nil {
		t.Fatal(err)
	}
	if secondID != firstID {
		t.Fatalf("team move minted a new node %s, want %s refreshed", secondID, firstID)
	}
	n, err := v.ReadNode(secondID)
	if err != nil {
		t.Fatal(err)
	}
	assertBodyContains(t, n.Body, "# OPS-3: Ship it", "- linear:OPS-3 ")
	for _, key := range []string{"OPS-3", "ENG-7"} {
		if ok, err := d.LinearIssueExists(key); err != nil || !ok {
			t.Errorf("LinearIssueExists(%s) = %v, %v; want true (current or previous key)", key, ok, err)
		}
	}
}

// A commit failure freezes the watermark (MEM-04), like the Jira builder.
func TestRunLinearIngestWatermarkFreezeOnError(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	acct := db.SeedLinearTestAccount(t, d)
	if err := d.SetMemoryLinearWatermark(acct, 1); err != nil {
		t.Fatal(err)
	}
	seedLinearIssueExtract(t, d, acct, "u1", "ENG-1", "ENG", "s", "Todo", "todo", "", "2026-07-22T10:00:00.000Z", "")
	p := NewPipeline(d, v, noCallGen(t), pipelineTestConfig(), t.Logf)
	if _, err := d.Exec(`DROP TABLE memory_aliases`); err != nil {
		t.Fatal(err)
	}
	var stats RunStats
	_, _ = p.runLinearIngest(1, 0, &stats)
	if stats.LinearIssuesFailed == 0 {
		t.Error("failed counter not bumped")
	}
	assertLinearWatermark(t, d, acct, 1)
}

// The Linear builder runs behind memory.sources.jira (the tracker switch) and
// not without it.
func TestRunLinearIngestGatedOnTheTrackerSource(t *testing.T) {
	for _, on := range []bool{false, true} {
		v, d := newTestVault(t), newTestDB(t)
		seedWorkspaceRow(t, d)
		acct := db.SeedLinearTestAccount(t, d)
		if err := d.SetMemoryLinearWatermark(acct, 1); err != nil {
			t.Fatal(err)
		}
		seedLinearIssueExtract(t, d, acct, "u1", "ENG-1", "ENG", "s", "Todo", "todo", "", "2026-07-22T10:00:00.000Z", "")
		cfg := pipelineTestConfig()
		cfg.Sources.Jira = on
		p := NewPipeline(d, v, noCallGen(t), cfg, t.Logf)
		if _, err := p.Run(t.Context()); err != nil {
			t.Fatalf("Run: %v", err)
		}
		_, err := d.LookupMemoryAlias(linearIssueAlias(acct, "u1"))
		if built := err == nil; built != on {
			t.Errorf("memory.sources.jira=%v: episode built = %v", on, built)
		}
	}
}

type fakeLinearChecker struct {
	exists map[string]bool
	err    error
}

func (f fakeLinearChecker) LinearIssueExists(key string) (bool, error) {
	if f.err != nil {
		return false, f.err
	}
	return f.exists[key], nil
}

// MEM-12 extension: the linear scheme dispatches to linearResolver; a missing
// key is a clean non-resolution and a lookup error propagates (registered).
func TestMemory12_LinearSchemeRegisteredAndResolved(t *testing.T) {
	reg := newProvenanceRegistry(linearResolver{db: fakeLinearChecker{exists: map[string]bool{"ENG-7": true}}})
	ok, registered, err := reg.Validate(episodeRef{ChannelID: "linear:ENG-7", TS: "1"})
	if err != nil || !registered || !ok {
		t.Errorf("existing issue = ok %v registered %v err %v; want true,true,nil", ok, registered, err)
	}
	ok, registered, err = reg.Validate(episodeRef{ChannelID: "linear:ENG-404", TS: "1"})
	if err != nil || !registered || ok {
		t.Errorf("missing issue = ok %v registered %v err %v; want false,true,nil", ok, registered, err)
	}
	reg = newProvenanceRegistry(linearResolver{db: fakeLinearChecker{err: errors.New("db down")}})
	if _, registered, err := reg.Validate(episodeRef{ChannelID: "linear:ENG-7", TS: "1"}); err == nil || !registered {
		t.Errorf("lookup error: registered %v err %v; want true, non-nil", registered, err)
	}

	// The belief surface's registry carries it; the Slack extractor's
	// message-only registry does not (scheme scoping).
	d, v := newTestDB(t), newTestVault(t)
	p := NewPipeline(d, v, &fakeGen{}, pipelineTestConfig(), t.Logf)
	if _, registered, _ := p.registry.Validate(episodeRef{ChannelID: "linear:ENG-1", TS: "x"}); !registered {
		t.Error("linear scheme not registered in the pipeline registry")
	}
	if _, registered, _ := newProvenanceRegistry(messageResolver{d}).Validate(episodeRef{ChannelID: "linear:ENG-1", TS: "x"}); registered {
		t.Error("linear scheme must not be accepted by a message-only registry")
	}
}

// Project-key seeds include the Linear team keys, and a key known to both
// trackers seeds one entity.
func TestTrackerProjectKeysIncludeLinearTeams(t *testing.T) {
	d := newTestDB(t)
	seedJiraAccount(t, d)
	seedJiraIssueExtract(t, d, "ABC-1", "ABC", "s", "", "To Do", "todo", "", "2026-07-22T10:00:00.000+0000", "")
	acct := db.SeedLinearTestAccount(t, d)
	if err := d.UpsertLinearTeams(acct, []db.LinearTeam{{ID: "t1", Key: "ENG"}, {ID: "t2", Key: "ABC"}}, nil); err != nil {
		t.Fatal(err)
	}
	keys, err := trackerProjectKeys(d)
	if err != nil {
		t.Fatal(err)
	}
	if fmt.Sprint(keys) != "[ABC ENG]" {
		t.Errorf("keys = %v, want [ABC ENG]", keys)
	}
}
