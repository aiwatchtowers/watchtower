package db

import (
	"database/sql"
	"testing"
	"time"
)

func TestIdeas_CreateGetListRoundTrip(t *testing.T) {
	d := openTestDB(t)

	tx, err := d.Begin()
	if err != nil {
		t.Fatalf("Begin: %v", err)
	}
	id, err := d.CreateIdeaTx(tx, Idea{
		Kind:    "idea",
		Title:   "Ship dark mode",
		Essence: "Users keep asking for it",
		Status:  "proposed",
		Source:  "mined",
	})
	if err != nil {
		t.Fatalf("CreateIdeaTx: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("Commit: %v", err)
	}

	got, err := d.GetIdea(id)
	if err != nil {
		t.Fatalf("GetIdea: %v", err)
	}
	if got == nil {
		t.Fatal("GetIdea returned nil for a created idea")
	}
	if got.Title != "Ship dark mode" || got.Kind != "idea" || got.Status != "proposed" || got.Source != "mined" {
		t.Errorf("round-trip mismatch: %+v", got)
	}

	list, err := d.ListIdeas(IdeaFilter{})
	if err != nil {
		t.Fatalf("ListIdeas: %v", err)
	}
	if len(list) != 1 || list[0].ID != id {
		t.Errorf("ListIdeas = %+v, want single idea with id %d", list, id)
	}
}

func TestIdeas_GetIdeaMissingReturnsNilNil(t *testing.T) {
	d := openTestDB(t)

	got, err := d.GetIdea(999999)
	if err != nil {
		t.Fatalf("GetIdea: %v", err)
	}
	if got != nil {
		t.Errorf("GetIdea for missing id = %+v, want nil", got)
	}
}

func TestIdeas_ListIdeasFilters(t *testing.T) {
	d := openTestDB(t)

	mustCreateIdea(t, d, Idea{Kind: "idea", Title: "Migrate to Postgres", Essence: "scale issue", Status: "proposed"})
	mustCreateIdea(t, d, Idea{Kind: "decision", Title: "Use SQLite forever", Essence: "simplicity wins", Status: "active"})

	byKind, err := d.ListIdeas(IdeaFilter{Kind: "decision"})
	if err != nil {
		t.Fatalf("ListIdeas by kind: %v", err)
	}
	if len(byKind) != 1 || byKind[0].Kind != "decision" {
		t.Errorf("ListIdeas(kind=decision) = %+v", byKind)
	}

	byStatus, err := d.ListIdeas(IdeaFilter{Status: "proposed"})
	if err != nil {
		t.Fatalf("ListIdeas by status: %v", err)
	}
	if len(byStatus) != 1 || byStatus[0].Title != "Migrate to Postgres" {
		t.Errorf("ListIdeas(status=proposed) = %+v", byStatus)
	}

	byQuery, err := d.ListIdeas(IdeaFilter{Query: "postgres"})
	if err != nil {
		t.Fatalf("ListIdeas by query: %v", err)
	}
	if len(byQuery) != 1 || byQuery[0].Title != "Migrate to Postgres" {
		t.Errorf("ListIdeas(query=postgres) = %+v", byQuery)
	}
}

func TestIdeas_ListIdeasQueryMatchesMentionQuote(t *testing.T) {
	d := openTestDB(t)

	id := mustCreateIdea(t, d, Idea{Kind: "idea", Title: "Unrelated title", Essence: "unrelated essence", Status: "proposed"})

	tx, err := d.Begin()
	if err != nil {
		t.Fatalf("Begin: %v", err)
	}
	if err := d.InsertIdeaMentionTx(tx, IdeaMention{
		IdeaID: id, Source: "slack", Quote: "we should really try zeroquantumflux", SaidAt: iso(time.Now()),
	}); err != nil {
		t.Fatalf("InsertIdeaMentionTx: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("Commit: %v", err)
	}

	got, err := d.ListIdeas(IdeaFilter{Query: "zeroquantumflux"})
	if err != nil {
		t.Fatalf("ListIdeas by mention quote: %v", err)
	}
	if len(got) != 1 || got[0].ID != id {
		t.Errorf("ListIdeas(query matching mention quote) = %+v, want idea %d", got, id)
	}
}

func TestIdeas_InsertMentionBumpsLastMentionAt(t *testing.T) {
	d := openTestDB(t)

	id := mustCreateIdea(t, d, Idea{Kind: "idea", Title: "Add retries", Essence: "flaky network", Status: "proposed"})

	before, err := d.GetIdea(id)
	if err != nil {
		t.Fatalf("GetIdea: %v", err)
	}

	saidAt := time.Now().Add(time.Hour).UTC().Format(time.RFC3339)
	tx, err := d.Begin()
	if err != nil {
		t.Fatalf("Begin: %v", err)
	}
	if err := d.InsertIdeaMentionTx(tx, IdeaMention{
		IdeaID: id, Source: "slack", Ref: "C1:123.456", Quote: "we need retries", Author: "U1", SaidAt: saidAt,
	}); err != nil {
		t.Fatalf("InsertIdeaMentionTx: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("Commit: %v", err)
	}

	after, err := d.GetIdea(id)
	if err != nil {
		t.Fatalf("GetIdea: %v", err)
	}
	if after.LastMentionAt != saidAt {
		t.Errorf("LastMentionAt = %q, want %q", after.LastMentionAt, saidAt)
	}
	if after.UpdatedAt < before.UpdatedAt {
		t.Errorf("UpdatedAt went backwards after mention insert: before=%q after=%q", before.UpdatedAt, after.UpdatedAt)
	}

	mentions, err := d.ListIdeaMentions(id)
	if err != nil {
		t.Fatalf("ListIdeaMentions: %v", err)
	}
	if len(mentions) != 1 || mentions[0].Quote != "we need retries" {
		t.Errorf("ListIdeaMentions = %+v", mentions)
	}
}

func TestIdeas_ListIdeaMentionsOrderedBySaidAt(t *testing.T) {
	d := openTestDB(t)

	id := mustCreateIdea(t, d, Idea{Kind: "idea", Title: "Order test", Essence: "e", Status: "proposed"})

	tx, err := d.Begin()
	if err != nil {
		t.Fatalf("Begin: %v", err)
	}
	later := time.Now().Add(2 * time.Hour).UTC().Format(time.RFC3339)
	earlier := time.Now().Add(1 * time.Hour).UTC().Format(time.RFC3339)
	if err := d.InsertIdeaMentionTx(tx, IdeaMention{IdeaID: id, Source: "slack", Quote: "second", SaidAt: later}); err != nil {
		t.Fatalf("InsertIdeaMentionTx (later): %v", err)
	}
	if err := d.InsertIdeaMentionTx(tx, IdeaMention{IdeaID: id, Source: "slack", Quote: "first", SaidAt: earlier}); err != nil {
		t.Fatalf("InsertIdeaMentionTx (earlier): %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("Commit: %v", err)
	}

	mentions, err := d.ListIdeaMentions(id)
	if err != nil {
		t.Fatalf("ListIdeaMentions: %v", err)
	}
	if len(mentions) != 2 || mentions[0].Quote != "first" || mentions[1].Quote != "second" {
		t.Errorf("ListIdeaMentions order = %+v, want [first, second]", mentions)
	}
}

func TestIdeas04_SetIdeaNeedsReviewTx(t *testing.T) {
	d := openTestDB(t)

	id := mustCreateIdea(t, d, Idea{Kind: "idea", Title: "Ambiguous idea", Essence: "e", Status: "proposed"})

	tx, err := d.Begin()
	if err != nil {
		t.Fatalf("Begin: %v", err)
	}
	if err := d.SetIdeaNeedsReviewTx(tx, id, "possible duplicate of #7"); err != nil {
		t.Fatalf("SetIdeaNeedsReviewTx: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("Commit: %v", err)
	}

	got, err := d.GetIdea(id)
	if err != nil {
		t.Fatalf("GetIdea: %v", err)
	}
	if !got.NeedsReview || got.ReviewReason != "possible duplicate of #7" {
		t.Errorf("after SetIdeaNeedsReviewTx: %+v", got)
	}
}

func TestIdeas_ListIdeasForPrompt(t *testing.T) {
	d := openTestDB(t)

	// Included: recently updated dropped idea (30 days ago).
	recentDropped := mustCreateIdea(t, d, Idea{Kind: "idea", Title: "Recent dropped", Essence: "e", Status: "dropped"})
	recentTS := time.Now().AddDate(0, 0, -30).UTC().Format(time.RFC3339)
	if _, err := d.Exec(`UPDATE ideas SET updated_at = ? WHERE id = ?`, recentTS, recentDropped); err != nil {
		t.Fatalf("backdating recent dropped idea: %v", err)
	}

	// Excluded: stale dropped idea (90 days ago).
	staleDropped := mustCreateIdea(t, d, Idea{Kind: "idea", Title: "Stale dropped", Essence: "e", Status: "dropped"})
	staleTS := time.Now().AddDate(0, 0, -90).UTC().Format(time.RFC3339)
	if _, err := d.Exec(`UPDATE ideas SET updated_at = ? WHERE id = ?`, staleTS, staleDropped); err != nil {
		t.Fatalf("backdating stale dropped idea: %v", err)
	}

	// Included regardless of age: proposed status.
	proposed := mustCreateIdea(t, d, Idea{Kind: "idea", Title: "Still proposed", Essence: "e", Status: "proposed"})
	if _, err := d.Exec(`UPDATE ideas SET updated_at = ? WHERE id = ?`, staleTS, proposed); err != nil {
		t.Fatalf("backdating proposed idea: %v", err)
	}

	list, err := d.ListIdeasForPrompt()
	if err != nil {
		t.Fatalf("ListIdeasForPrompt: %v", err)
	}

	ids := map[int64]bool{}
	for _, idea := range list {
		ids[idea.ID] = true
	}
	if !ids[recentDropped] {
		t.Errorf("ListIdeasForPrompt missing recently-updated dropped idea %d: %+v", recentDropped, list)
	}
	if ids[staleDropped] {
		t.Errorf("ListIdeasForPrompt included stale dropped idea %d: %+v", staleDropped, list)
	}
	if !ids[proposed] {
		t.Errorf("ListIdeasForPrompt missing proposed idea %d: %+v", proposed, list)
	}
}

func TestIdeas_ListIdeaVerdictExamples(t *testing.T) {
	d := openTestDB(t)

	rated := mustCreateIdea(t, d, Idea{Kind: "idea", Title: "Rated idea", Essence: "e", Status: "active"})
	if _, err := d.Exec(`UPDATE ideas SET owner_rating = 1 WHERE id = ?`, rated); err != nil {
		t.Fatalf("rating idea: %v", err)
	}
	rejected := mustCreateIdea(t, d, Idea{Kind: "idea", Title: "Rejected idea", Essence: "e", Status: "rejected"})
	_ = mustCreateIdea(t, d, Idea{Kind: "idea", Title: "Irrelevant proposed idea", Essence: "e", Status: "proposed"})

	examples, err := d.ListIdeaVerdictExamples(10)
	if err != nil {
		t.Fatalf("ListIdeaVerdictExamples: %v", err)
	}
	ids := map[int64]bool{}
	for _, idea := range examples {
		ids[idea.ID] = true
	}
	if !ids[rated] {
		t.Errorf("ListIdeaVerdictExamples missing rated idea: %+v", examples)
	}
	if !ids[rejected] {
		t.Errorf("ListIdeaVerdictExamples missing rejected idea: %+v", examples)
	}
}

func TestIdeas_FloorsRoundTrip(t *testing.T) {
	d := openTestDB(t)
	mustSeedWorkspace(t, d)

	digest, stream, transcript, err := d.GetIdeasFloors()
	if err != nil {
		t.Fatalf("GetIdeasFloors (default): %v", err)
	}
	if digest != 0 || stream != 0 || transcript != 0 {
		t.Errorf("default floors = (%d,%d,%d), want zeros", digest, stream, transcript)
	}

	tx, err := d.Begin()
	if err != nil {
		t.Fatalf("Begin: %v", err)
	}
	if err := d.SetIdeasFloorsTx(tx, 5, 7, 9); err != nil {
		t.Fatalf("SetIdeasFloorsTx: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("Commit: %v", err)
	}

	digest, stream, transcript, err = d.GetIdeasFloors()
	if err != nil {
		t.Fatalf("GetIdeasFloors (after set): %v", err)
	}
	if digest != 5 || stream != 7 || transcript != 9 {
		t.Errorf("floors after set = (%d,%d,%d), want (5,7,9)", digest, stream, transcript)
	}
}

func TestIdeas_StreamDigestInsertAndListAfter(t *testing.T) {
	d := openTestDB(t)

	id1, err := d.InsertStreamDigest(StreamDigest{
		Source: "gmail", AccountID: 1, Scope: "inbox",
		PeriodFrom: "2026-01-01T00:00:00Z", PeriodTo: "2026-01-02T00:00:00Z", TopicsJSON: "[]",
	})
	if err != nil {
		t.Fatalf("InsertStreamDigest 1: %v", err)
	}
	id2, err := d.InsertStreamDigest(StreamDigest{
		Source: "jira", AccountID: 2, Scope: "PROJ",
		PeriodFrom: "2026-01-02T00:00:00Z", PeriodTo: "2026-01-03T00:00:00Z", TopicsJSON: "[]",
	})
	if err != nil {
		t.Fatalf("InsertStreamDigest 2: %v", err)
	}

	after, err := d.ListStreamDigestsAfter(id1, "")
	if err != nil {
		t.Fatalf("ListStreamDigestsAfter: %v", err)
	}
	if len(after) != 1 || after[0].ID != id2 {
		t.Errorf("ListStreamDigestsAfter(%d) = %+v, want just id %d", id1, after, id2)
	}
}

func TestIdeas_UpsertJiraCommentsIdempotent(t *testing.T) {
	d := openTestDB(t)
	accountID := mustCreateJiraAccount(t, d)

	comments := []JiraComment{
		{AccountID: accountID, IssueKey: "PROJ-1", ID: "c1", Author: "alice", BodyText: "first", CreatedAt: "2026-01-01T00:00:00Z", UpdatedAt: "2026-01-01T00:00:00Z"},
	}
	if err := d.UpsertJiraComments(comments); err != nil {
		t.Fatalf("UpsertJiraComments (insert): %v", err)
	}

	// Idempotent: same id, updated body.
	comments[0].BodyText = "first edited"
	comments[0].UpdatedAt = "2026-01-02T00:00:00Z"
	if err := d.UpsertJiraComments(comments); err != nil {
		t.Fatalf("UpsertJiraComments (update): %v", err)
	}

	got, err := d.ListJiraCommentsSince(accountID, []string{"PROJ-1"}, "2025-01-01T00:00:00Z")
	if err != nil {
		t.Fatalf("ListJiraCommentsSince: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("ListJiraCommentsSince = %+v, want exactly one row (upsert must not duplicate)", got)
	}
	if got[0].BodyText != "first edited" {
		t.Errorf("BodyText = %q, want edited text", got[0].BodyText)
	}
}

func TestIdeas_UpsertJiraCommentsRoundTripsAuthorAccountID(t *testing.T) {
	d := openTestDB(t)
	accountID := mustCreateJiraAccount(t, d)

	comments := []JiraComment{
		{AccountID: accountID, IssueKey: "PROJ-1", ID: "c1", Author: "Alice", AuthorAccountID: "acc-alice",
			BodyText: "hey [~acc-bob]", CreatedAt: "2026-01-01T00:00:00Z", UpdatedAt: "2026-01-01T00:00:00Z"},
	}
	if err := d.UpsertJiraComments(comments); err != nil {
		t.Fatalf("UpsertJiraComments (insert): %v", err)
	}

	got, err := d.ListJiraCommentsSince(accountID, []string{"PROJ-1"}, "2025-01-01T00:00:00Z")
	if err != nil {
		t.Fatalf("ListJiraCommentsSince: %v", err)
	}
	if len(got) != 1 || got[0].AuthorAccountID != "acc-alice" {
		t.Fatalf("ListJiraCommentsSince = %+v, want AuthorAccountID=acc-alice", got)
	}

	// Update path also round-trips the new column.
	comments[0].AuthorAccountID = "acc-alice-2"
	if err := d.UpsertJiraComments(comments); err != nil {
		t.Fatalf("UpsertJiraComments (update): %v", err)
	}
	got, err = d.ListJiraCommentsSince(accountID, []string{"PROJ-1"}, "2025-01-01T00:00:00Z")
	if err != nil {
		t.Fatalf("ListJiraCommentsSince: %v", err)
	}
	if len(got) != 1 || got[0].AuthorAccountID != "acc-alice-2" {
		t.Fatalf("ListJiraCommentsSince after update = %+v, want AuthorAccountID=acc-alice-2", got)
	}
}

func TestIdeas_ListJiraCommentsSinceFiltersIssueAndTime(t *testing.T) {
	d := openTestDB(t)
	accountID := mustCreateJiraAccount(t, d)

	err := d.UpsertJiraComments([]JiraComment{
		{AccountID: accountID, IssueKey: "PROJ-1", ID: "c1", BodyText: "old", CreatedAt: "2020-01-01T00:00:00Z", UpdatedAt: "2020-01-01T00:00:00Z"},
		{AccountID: accountID, IssueKey: "PROJ-1", ID: "c2", BodyText: "new", CreatedAt: "2026-01-01T00:00:00Z", UpdatedAt: "2026-01-01T00:00:00Z"},
		{AccountID: accountID, IssueKey: "PROJ-2", ID: "c3", BodyText: "other issue", CreatedAt: "2026-01-01T00:00:00Z", UpdatedAt: "2026-01-01T00:00:00Z"},
	})
	if err != nil {
		t.Fatalf("UpsertJiraComments: %v", err)
	}

	got, err := d.ListJiraCommentsSince(accountID, []string{"PROJ-1"}, "2025-01-01T00:00:00Z")
	if err != nil {
		t.Fatalf("ListJiraCommentsSince: %v", err)
	}
	if len(got) != 1 || got[0].ID != "c2" {
		t.Errorf("ListJiraCommentsSince = %+v, want just c2", got)
	}
}

func TestIdeas_ListDigestTopicIdeasAfter(t *testing.T) {
	d := openTestDB(t)

	mustCreateChannel(t, d, "C1", "general")

	digestID := mustCreateChannelDigest(t, d, "C1")
	topics := []DigestTopic{
		{Title: "With ideas", Summary: "s", Decisions: "[]", ActionItems: "[]", Situations: "[]", KeyMessages: "[]", Ideas: `[{"title":"x"}]`},
		{Title: "No ideas or decisions", Summary: "s", Decisions: "[]", ActionItems: "[]", Situations: "[]", KeyMessages: "[]", Ideas: "[]"},
		{Title: "Only decisions", Summary: "s", Decisions: `[{"title":"y"}]`, ActionItems: "[]", Situations: "[]", KeyMessages: "[]", Ideas: "[]"},
	}
	if err := d.InsertDigestTopics(int64(digestID), topics); err != nil {
		t.Fatalf("InsertDigestTopics: %v", err)
	}

	got, err := d.ListDigestTopicIdeasAfter(0, 0)
	if err != nil {
		t.Fatalf("ListDigestTopicIdeasAfter: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("ListDigestTopicIdeasAfter = %+v, want 2 rows (ideas-bearing + decisions-bearing)", got)
	}
	for _, row := range got {
		if row.ChannelID != "C1" || row.ChannelName != "general" {
			t.Errorf("row channel mismatch: %+v", row)
		}
	}

	// Floor excludes everything.
	maxID := got[len(got)-1].TopicID
	after, err := d.ListDigestTopicIdeasAfter(maxID, 0)
	if err != nil {
		t.Fatalf("ListDigestTopicIdeasAfter (above floor): %v", err)
	}
	if len(after) != 0 {
		t.Errorf("ListDigestTopicIdeasAfter(%d) = %+v, want empty", maxID, after)
	}
}

// TestIdeas_ListDigestTopicIdeasAfter_LegacyNullExcluded covers the
// pre-PR-78 legacy shape: a topic whose ideas AND decisions both still hold
// the literal string "null" (json.Marshal of a nil slice, instead of "[]")
// must stay excluded — split out from TestIdeas_ListDigestTopicIdeasAfter
// (a single self-contained test, own DB) to keep each scenario's setup and
// assertions independently readable.
func TestIdeas_ListDigestTopicIdeasAfter_LegacyNullExcluded(t *testing.T) {
	d := openTestDB(t)
	mustCreateChannel(t, d, "C1", "general")
	digestID := mustCreateChannelDigest(t, d, "C1")
	if err := d.InsertDigestTopics(int64(digestID), []DigestTopic{
		{Title: "With ideas", Summary: "s", Decisions: "[]", ActionItems: "[]", Situations: "[]", KeyMessages: "[]", Ideas: `[{"title":"x"}]`},
	}); err != nil {
		t.Fatalf("InsertDigestTopics: %v", err)
	}

	if _, err := d.Exec(`INSERT INTO digest_topics (digest_id, idx, title, summary, decisions, action_items, situations, key_messages, ideas)
		VALUES (?, 99, 'Legacy null', 's', 'null', '[]', '[]', '[]', 'null')`, digestID); err != nil {
		t.Fatalf("inserting legacy-null topic: %v", err)
	}

	got, err := d.ListDigestTopicIdeasAfter(0, 0)
	if err != nil {
		t.Fatalf("ListDigestTopicIdeasAfter: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("ListDigestTopicIdeasAfter = %+v, want the legacy-null row excluded (1 row)", got)
	}
}

// TestIdeas_ListDigestTopicIdeasAfter_MixedLegacyNullIncluded pins the
// inclusion direction the legacy-null filter must NOT sweep too broadly: a
// row with ONE field still "null" but a real value in the other must be
// returned, not swept out along with the all-null rows. Covers both mixed
// shapes.
func TestIdeas_ListDigestTopicIdeasAfter_MixedLegacyNullIncluded(t *testing.T) {
	d := openTestDB(t)
	mustCreateChannel(t, d, "C1", "general")
	digestID := mustCreateChannelDigest(t, d, "C1")

	if _, err := d.Exec(`INSERT INTO digest_topics (digest_id, idx, title, summary, decisions, action_items, situations, key_messages, ideas)
		VALUES (?, 100, 'Legacy null ideas, real decisions', 's', '[{"text":"z"}]', '[]', '[]', '[]', 'null')`, digestID); err != nil {
		t.Fatalf("inserting mixed legacy topic (null ideas): %v", err)
	}
	if _, err := d.Exec(`INSERT INTO digest_topics (digest_id, idx, title, summary, decisions, action_items, situations, key_messages, ideas)
		VALUES (?, 101, 'Real ideas, legacy null decisions', 's', 'null', '[]', '[]', '[]', '[{"title":"w"}]')`, digestID); err != nil {
		t.Fatalf("inserting mixed legacy topic (null decisions): %v", err)
	}

	mixed, err := d.ListDigestTopicIdeasAfter(0, 0)
	if err != nil {
		t.Fatalf("ListDigestTopicIdeasAfter: %v", err)
	}
	if len(mixed) != 2 {
		t.Fatalf("ListDigestTopicIdeasAfter = %+v, want the 2 mixed rows present", mixed)
	}
	titles := map[string]bool{}
	for _, row := range mixed {
		titles[row.Decisions] = true
		titles[row.Ideas] = true
	}
	if !titles[`[{"text":"z"}]`] {
		t.Errorf("mixed rows = %+v, want row with real decisions ([{\"text\":\"z\"}]) present despite ideas='null'", mixed)
	}
	if !titles[`[{"title":"w"}]`] {
		t.Errorf("mixed rows = %+v, want row with real ideas ([{\"title\":\"w\"}]) present despite decisions='null'", mixed)
	}
}

func TestIdeas_ListTranscriptsForIdeasAfter_RecapCollision(t *testing.T) {
	d := openTestDB(t)

	// Event-linked transcript with a meeting_recaps row: recap wins.
	eventID := mustCreateCalendarEvent(t, d, "evt-1")
	if _, err := d.Exec(`INSERT INTO meeting_recaps (event_id, source_text, recap_json) VALUES (?, ?, ?)`,
		eventID, "src", `{"summary":"from recap"}`); err != nil {
		t.Fatalf("inserting meeting_recaps: %v", err)
	}
	linkedID := mustCreateTranscript(t, d, &eventID, `{"summary":"from summary_json"}`)

	// Ad-hoc transcript with no event: falls back to summary_json.
	adHocID := mustCreateTranscript(t, d, nil, `{"summary":"ad hoc"}`)

	got, err := d.ListTranscriptsForIdeasAfter(0, "")
	if err != nil {
		t.Fatalf("ListTranscriptsForIdeasAfter: %v", err)
	}
	byID := map[int64]TranscriptForIdeas{}
	for _, row := range got {
		byID[row.ID] = row
	}
	linked, ok := byID[linkedID]
	if !ok {
		t.Fatalf("missing linked transcript %d in %+v", linkedID, got)
	}
	if linked.RecapJSON != `{"summary":"from recap"}` {
		t.Errorf("RecapJSON = %q, want the meeting_recaps row to win over summary_json", linked.RecapJSON)
	}

	adHoc, ok := byID[adHocID]
	if !ok {
		t.Fatalf("missing ad-hoc transcript %d in %+v", adHocID, got)
	}
	if adHoc.RecapJSON != `{"summary":"ad hoc"}` {
		t.Errorf("RecapJSON = %q, want summary_json fallback for an ad-hoc transcript", adHoc.RecapJSON)
	}
}

func TestIdeas_ListTranscriptsForIdeasAfterFloor(t *testing.T) {
	d := openTestDB(t)

	id1 := mustCreateTranscript(t, d, nil, "")
	id2 := mustCreateTranscript(t, d, nil, "")

	got, err := d.ListTranscriptsForIdeasAfter(id1, "")
	if err != nil {
		t.Fatalf("ListTranscriptsForIdeasAfter: %v", err)
	}
	if len(got) != 1 || got[0].ID != id2 {
		t.Errorf("ListTranscriptsForIdeasAfter(%d) = %+v, want just id %d", id1, got, id2)
	}
}

func TestIdeas_CountIdeasForReview(t *testing.T) {
	d := openTestDB(t)

	mustCreateIdea(t, d, Idea{Kind: "idea", Title: "Proposed one", Essence: "e", Status: "proposed"})
	needsReview := mustCreateIdea(t, d, Idea{Kind: "idea", Title: "Needs review one", Essence: "e", Status: "active"})
	tx, err := d.Begin()
	if err != nil {
		t.Fatalf("Begin: %v", err)
	}
	if err := d.SetIdeaNeedsReviewTx(tx, needsReview, "ambiguous"); err != nil {
		t.Fatalf("SetIdeaNeedsReviewTx: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("Commit: %v", err)
	}
	mustCreateIdea(t, d, Idea{Kind: "idea", Title: "Neither", Essence: "e", Status: "active"})

	count, err := d.CountIdeasForReview()
	if err != nil {
		t.Fatalf("CountIdeasForReview: %v", err)
	}
	if count != 2 {
		t.Errorf("CountIdeasForReview = %d, want 2", count)
	}
}

// --- test helpers ---

func mustCreateIdea(t *testing.T, d *DB, idea Idea) int64 {
	t.Helper()
	tx, err := d.Begin()
	if err != nil {
		t.Fatalf("Begin: %v", err)
	}
	id, err := d.CreateIdeaTx(tx, idea)
	if err != nil {
		t.Fatalf("CreateIdeaTx: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("Commit: %v", err)
	}
	return id
}

func mustSeedWorkspace(t *testing.T, d *DB) {
	t.Helper()
	if _, err := d.Exec(`INSERT INTO workspace (id, name) VALUES ('T1', 'Test')`); err != nil {
		t.Fatalf("seeding workspace: %v", err)
	}
}

func mustCreateJiraAccount(t *testing.T, d *DB) int64 {
	t.Helper()
	res, err := d.Exec(`INSERT INTO jira_accounts (cloud_id, site_url, site_name, label) VALUES (?, ?, ?, ?)`,
		"cloud-1", "https://example.atlassian.net", "Example", "Primary")
	if err != nil {
		t.Fatalf("inserting jira_accounts: %v", err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		t.Fatalf("LastInsertId: %v", err)
	}
	return id
}

func mustCreateChannel(t *testing.T, d *DB, id, name string) {
	t.Helper()
	if _, err := d.Exec(`INSERT INTO channels (id, name, type) VALUES (?, ?, 'public')`, id, name); err != nil {
		t.Fatalf("inserting channel: %v", err)
	}
}

func mustCreateChannelDigest(t *testing.T, d *DB, channelID string) int {
	t.Helper()
	res, err := d.Exec(`INSERT INTO digests (channel_id, period_from, period_to, type, summary)
		VALUES (?, 0, 0, 'channel', '')`, channelID)
	if err != nil {
		t.Fatalf("inserting digest: %v", err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		t.Fatalf("LastInsertId: %v", err)
	}
	return int(id)
}

func mustCreateCalendarEvent(t *testing.T, d *DB, id string) string {
	t.Helper()
	if _, err := d.Exec(`INSERT INTO calendar_calendars (id, name) VALUES (?, ?)`, "cal-"+id, "Test Calendar"); err != nil {
		t.Fatalf("inserting calendar_calendars: %v", err)
	}
	if _, err := d.Exec(`INSERT INTO calendar_events (id, calendar_id, title, start_time, end_time) VALUES (?, ?, ?, '2026-01-01T00:00:00Z', '2026-01-01T01:00:00Z')`,
		id, "cal-"+id, "Test Event"); err != nil {
		t.Fatalf("inserting calendar_events: %v", err)
	}
	return id
}

func mustCreateTranscript(t *testing.T, d *DB, eventID *string, summaryJSON string) int64 {
	t.Helper()
	var summary sql.NullString
	if summaryJSON != "" {
		summary = sql.NullString{String: summaryJSON, Valid: true}
	}
	res, err := d.Exec(`INSERT INTO meeting_transcripts (event_id, title, transcript_text, summary_json)
		VALUES (?, ?, '', ?)`, eventID, "Test Transcript", summary)
	if err != nil {
		t.Fatalf("inserting meeting_transcripts: %v", err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		t.Fatalf("LastInsertId: %v", err)
	}
	return id
}

func iso(t time.Time) string {
	return t.UTC().Format(time.RFC3339)
}

// TestIdeas01_JiraWindowBoundaryDrainKeepsSameTimestampIssues covers the
// cap-cuts-inside-a-timestamp case. The ideas Jira pre-digest advances its
// floor to the highest updated_at it saw and reloads with a strict >, so an
// issue sharing that timestamp but left outside the LIMIT would be skipped
// forever. More same-timestamp issues than the cap must therefore still all
// arrive — across at most two runs, with nothing lost in between.
func TestIdeas01_JiraWindowBoundaryDrainKeepsSameTimestampIssues(t *testing.T) {
	d := openTestDB(t)
	acctID := mustCreateJiraAccount(t, d)

	const shared = "2026-08-05T10:00:00.000+0000"
	const later = "2026-08-06T10:00:00.000+0000"
	const limit = 3

	// One issue strictly before the tie group, then a tie group larger than
	// the cap, then one after it.
	mustCreateJiraIssueAt(t, d, acctID, "WT-001", "2026-08-04T10:00:00.000+0000")
	tied := []string{"WT-010", "WT-011", "WT-012", "WT-013", "WT-014"}
	for _, key := range tied {
		mustCreateJiraIssueAt(t, d, acctID, key, shared)
	}
	mustCreateJiraIssueAt(t, d, acctID, "WT-020", later)

	seen := map[string]bool{}
	floor := "2026-08-01T00:00:00.000+0000"
	for run := 0; run < 4; run++ {
		issues, err := d.ListJiraIssuesUpdatedSince(acctID, floor, "", limit)
		if err != nil {
			t.Fatalf("run %d: ListJiraIssuesUpdatedSince: %v", run, err)
		}
		if len(issues) == 0 {
			break
		}
		for _, is := range issues {
			seen[is.Key] = true
			if is.UpdatedAt > floor {
				floor = is.UpdatedAt
			}
		}
	}

	for _, key := range append([]string{"WT-001", "WT-020"}, tied...) {
		if !seen[key] {
			t.Errorf("issue %s was never returned — the boundary cut dropped it permanently", key)
		}
	}
}

// TestIdeas01_JiraWindowIsDeterministicWithinATimestamp pins the tie-breaking
// order the boundary drain relies on: within one updated_at value the rows
// come back ordered by key, so the drain can splice on a stable prefix.
func TestIdeas01_JiraWindowIsDeterministicWithinATimestamp(t *testing.T) {
	d := openTestDB(t)
	acctID := mustCreateJiraAccount(t, d)

	const shared = "2026-08-05T10:00:00.000+0000"
	for _, key := range []string{"WT-030", "WT-010", "WT-020"} {
		mustCreateJiraIssueAt(t, d, acctID, key, shared)
	}

	issues, err := d.ListJiraIssuesUpdatedSince(acctID, "2026-08-01T00:00:00.000+0000", "", 300)
	if err != nil {
		t.Fatalf("ListJiraIssuesUpdatedSince: %v", err)
	}
	var got []string
	for _, is := range issues {
		got = append(got, is.Key)
	}
	want := []string{"WT-010", "WT-020", "WT-030"}
	if len(got) != len(want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("got %v, want %v", got, want)
		}
	}
}

func mustCreateJiraIssueAt(t *testing.T, d *DB, accountID int64, key, updatedAt string) {
	t.Helper()
	if err := d.UpsertJiraIssue(JiraIssue{
		AccountID: accountID, Key: key, ID: key, ProjectKey: "WT",
		Summary: key, Status: "Open", UpdatedAt: updatedAt,
	}); err != nil {
		t.Fatalf("UpsertJiraIssue %s: %v", key, err)
	}
}

// --- Optional upper bounds (Ideas Backfill Task 3) -------------------------

func mustCreateChannelDigestAt(t *testing.T, d *DB, channelID string, periodTo float64) int64 {
	t.Helper()
	res, err := d.Exec(`INSERT INTO digests (channel_id, period_from, period_to, type, summary)
		VALUES (?, 0, ?, 'channel', '')`, channelID, periodTo)
	if err != nil {
		t.Fatalf("inserting digest: %v", err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		t.Fatalf("LastInsertId: %v", err)
	}
	return id
}

// TestIdeas_ListDigestTopicIdeasAfter_UpperBound: a non-zero toUnix excludes
// topics whose parent digest's period_to is after it, and a zero toUnix stays
// unbounded (parity with the pre-bound behavior) — rows straddling the bound
// prove both directions.
func TestIdeas_ListDigestTopicIdeasAfter_UpperBound(t *testing.T) {
	d := openTestDB(t)
	mustCreateChannel(t, d, "C1", "general")

	digestBefore := mustCreateChannelDigestAt(t, d, "C1", 100)
	digestAt := mustCreateChannelDigestAt(t, d, "C1", 200)
	digestAfter := mustCreateChannelDigestAt(t, d, "C1", 300)

	topic := []DigestTopic{{Title: "t", Summary: "s", Decisions: "[]", ActionItems: "[]", Situations: "[]", KeyMessages: "[]", Ideas: `[{"title":"x"}]`}}
	for _, id := range []int64{digestBefore, digestAt, digestAfter} {
		if err := d.InsertDigestTopics(id, topic); err != nil {
			t.Fatalf("InsertDigestTopics %d: %v", id, err)
		}
	}

	bounded, err := d.ListDigestTopicIdeasAfter(0, 200)
	if err != nil {
		t.Fatalf("ListDigestTopicIdeasAfter: %v", err)
	}
	if len(bounded) != 2 {
		t.Fatalf("ListDigestTopicIdeasAfter(0, 200) = %+v, want 2 rows (period_to <= 200)", bounded)
	}

	unbounded, err := d.ListDigestTopicIdeasAfter(0, 0)
	if err != nil {
		t.Fatalf("ListDigestTopicIdeasAfter: %v", err)
	}
	if len(unbounded) != 3 {
		t.Fatalf("ListDigestTopicIdeasAfter(0, 0) = %+v, want all 3 rows (zero bound is unbounded)", unbounded)
	}
}

// TestIdeas_ListStreamDigestsAfter_UpperBound is the stream-digests half of
// the same rule: a non-zero toISO excludes rows created after it.
func TestIdeas_ListStreamDigestsAfter_UpperBound(t *testing.T) {
	d := openTestDB(t)

	mustInsertStreamDigestAt(t, d, "gmail", "2026-01-01T00:00:00Z")
	mustInsertStreamDigestAt(t, d, "gmail", "2026-01-02T00:00:00Z")
	mustInsertStreamDigestAt(t, d, "gmail", "2026-01-03T00:00:00Z")

	bounded, err := d.ListStreamDigestsAfter(0, "2026-01-02T00:00:00Z")
	if err != nil {
		t.Fatalf("ListStreamDigestsAfter: %v", err)
	}
	if len(bounded) != 2 {
		t.Fatalf("ListStreamDigestsAfter(0, bound) = %+v, want 2 rows (created_at <= bound)", bounded)
	}

	unbounded, err := d.ListStreamDigestsAfter(0, "")
	if err != nil {
		t.Fatalf("ListStreamDigestsAfter: %v", err)
	}
	if len(unbounded) != 3 {
		t.Fatalf("ListStreamDigestsAfter(0, \"\") = %+v, want all 3 rows (empty bound is unbounded)", unbounded)
	}
}

func mustInsertStreamDigestAt(t *testing.T, d *DB, source, createdAtISO string) int64 {
	t.Helper()
	res, err := d.Exec(`INSERT INTO stream_digests (source, account_id, scope, period_from, period_to, topics_json, created_at)
		VALUES (?, 1, '', ?, ?, '[]', ?)`, source, createdAtISO, createdAtISO, createdAtISO)
	if err != nil {
		t.Fatalf("inserting stream digest: %v", err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		t.Fatalf("LastInsertId: %v", err)
	}
	return id
}

// TestIdeas_ListTranscriptsForIdeasAfter_UpperBound is the transcripts half
// of the same rule: a non-zero toISO excludes transcripts created after it.
func TestIdeas_ListTranscriptsForIdeasAfter_UpperBound(t *testing.T) {
	d := openTestDB(t)

	mustCreateTranscriptAt(t, d, "2026-01-01T00:00:00Z")
	mustCreateTranscriptAt(t, d, "2026-01-02T00:00:00Z")
	mustCreateTranscriptAt(t, d, "2026-01-03T00:00:00Z")

	bounded, err := d.ListTranscriptsForIdeasAfter(0, "2026-01-02T00:00:00Z")
	if err != nil {
		t.Fatalf("ListTranscriptsForIdeasAfter: %v", err)
	}
	if len(bounded) != 2 {
		t.Fatalf("ListTranscriptsForIdeasAfter(0, bound) = %+v, want 2 rows (created_at <= bound)", bounded)
	}

	unbounded, err := d.ListTranscriptsForIdeasAfter(0, "")
	if err != nil {
		t.Fatalf("ListTranscriptsForIdeasAfter: %v", err)
	}
	if len(unbounded) != 3 {
		t.Fatalf("ListTranscriptsForIdeasAfter(0, \"\") = %+v, want all 3 rows (empty bound is unbounded)", unbounded)
	}
}

func mustCreateTranscriptAt(t *testing.T, d *DB, createdAtISO string) int64 {
	t.Helper()
	res, err := d.Exec(`INSERT INTO meeting_transcripts (title, transcript_text, created_at, updated_at)
		VALUES ('Test Transcript', '', ?, ?)`, createdAtISO, createdAtISO)
	if err != nil {
		t.Fatalf("inserting meeting_transcripts: %v", err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		t.Fatalf("LastInsertId: %v", err)
	}
	return id
}

// TestIdeas_ListJiraIssuesUpdatedSince_UpperBound: a non-zero beforeISO
// excludes issues updated after it, and an empty beforeISO stays unbounded
// (parity with the pre-bound behavior).
func TestIdeas_ListJiraIssuesUpdatedSince_UpperBound(t *testing.T) {
	d := openTestDB(t)
	acctID := mustCreateJiraAccount(t, d)

	mustCreateJiraIssueAt(t, d, acctID, "WT-001", "2026-08-01T00:00:00.000+0000")
	mustCreateJiraIssueAt(t, d, acctID, "WT-002", "2026-08-02T00:00:00.000+0000")
	mustCreateJiraIssueAt(t, d, acctID, "WT-003", "2026-08-03T00:00:00.000+0000")

	bounded, err := d.ListJiraIssuesUpdatedSince(acctID, "2026-07-01T00:00:00.000+0000", "2026-08-02T00:00:00.000+0000", 300)
	if err != nil {
		t.Fatalf("ListJiraIssuesUpdatedSince: %v", err)
	}
	if len(bounded) != 2 {
		t.Fatalf("ListJiraIssuesUpdatedSince(bounded) = %+v, want 2 issues (updated_at <= beforeISO)", bounded)
	}

	unbounded, err := d.ListJiraIssuesUpdatedSince(acctID, "2026-07-01T00:00:00.000+0000", "", 300)
	if err != nil {
		t.Fatalf("ListJiraIssuesUpdatedSince: %v", err)
	}
	if len(unbounded) != 3 {
		t.Fatalf("ListJiraIssuesUpdatedSince(unbounded) = %+v, want all 3 issues (empty bound is unbounded)", unbounded)
	}
}

// TestIdeas_ListJiraIssuesUpdatedSince_BoundaryDrainWithUpperBound combines a
// non-zero upper bound with a limit-cut that lands inside a same-timestamp
// group — the exact combination the backfill engine's drain loop exercises
// on a real historical window (deferred from Task 3's plan into Task 4). The
// boundary-drain extension query must still respect the outer bound: an
// issue sharing the cut-off timestamp is kept, one past the bound is not.
func TestIdeas_ListJiraIssuesUpdatedSince_BoundaryDrainWithUpperBound(t *testing.T) {
	d := openTestDB(t)
	acctID := mustCreateJiraAccount(t, d)

	base := time.Now().Add(-48 * time.Hour)
	floor := FormatJiraTime(base.Add(-2 * time.Hour))
	before := FormatJiraTime(base.Add(-time.Hour))
	shared := FormatJiraTime(base)
	after := FormatJiraTime(base.Add(time.Hour))
	bound := FormatJiraTime(base.Add(30 * time.Minute)) // between shared and after

	mustCreateJiraIssueAt(t, d, acctID, "WT-001", before)
	tied := []string{"WT-010", "WT-011", "WT-012", "WT-013", "WT-014"}
	for _, key := range tied {
		mustCreateJiraIssueAt(t, d, acctID, key, shared)
	}
	mustCreateJiraIssueAt(t, d, acctID, "WT-020", after)

	const limit = 3
	issues, err := d.ListJiraIssuesUpdatedSince(acctID, floor, bound, limit)
	if err != nil {
		t.Fatalf("ListJiraIssuesUpdatedSince: %v", err)
	}

	seen := map[string]bool{}
	for _, is := range issues {
		seen[is.Key] = true
	}
	for _, key := range append([]string{"WT-001"}, tied...) {
		if !seen[key] {
			t.Errorf("issue %s was dropped by the boundary-drain extension under a non-zero upper bound", key)
		}
	}
	if seen["WT-020"] {
		t.Error("issue WT-020 is after the upper bound and must not be returned even via the boundary-drain extension")
	}
}

// TestIdeas_DigestTopicFloorForTime_BoundaryInclusive pins the exact-at-from
// boundary the backfill engine relies on: a topic whose parent digest's
// period_to equals "from" exactly must NOT be folded into the floor (so it
// stays re-mineable), while one strictly before "from" must be.
func TestIdeas_DigestTopicFloorForTime_BoundaryInclusive(t *testing.T) {
	d := openTestDB(t)
	mustCreateChannel(t, d, "C1", "general")

	from := float64(time.Now().Unix())
	beforeID := mustCreateChannelDigestAt(t, d, "C1", from-100)
	atID := mustCreateChannelDigestAt(t, d, "C1", from)
	topic := []DigestTopic{{Title: "t", Summary: "s", Decisions: "[]", ActionItems: "[]", Situations: "[]", KeyMessages: "[]", Ideas: `[{"title":"x"}]`}}
	for _, id := range []int64{beforeID, atID} {
		if err := d.InsertDigestTopics(id, topic); err != nil {
			t.Fatalf("InsertDigestTopics %d: %v", id, err)
		}
	}
	var beforeTopicID, atTopicID int64
	if err := d.QueryRow(`SELECT id FROM digest_topics WHERE digest_id = ?`, beforeID).Scan(&beforeTopicID); err != nil {
		t.Fatalf("reading before topic id: %v", err)
	}
	if err := d.QueryRow(`SELECT id FROM digest_topics WHERE digest_id = ?`, atID).Scan(&atTopicID); err != nil {
		t.Fatalf("reading at topic id: %v", err)
	}

	floor, err := d.DigestTopicFloorForTime(int64(from))
	if err != nil {
		t.Fatalf("DigestTopicFloorForTime: %v", err)
	}
	if floor != beforeTopicID {
		t.Fatalf("DigestTopicFloorForTime(from) = %d, want %d (the strictly-before topic — the at-from topic must stay re-mineable)", floor, beforeTopicID)
	}

	after, err := d.ListDigestTopicIdeasAfter(floor, 0)
	if err != nil {
		t.Fatalf("ListDigestTopicIdeasAfter: %v", err)
	}
	if len(after) != 1 || after[0].TopicID != atTopicID {
		t.Fatalf("ListDigestTopicIdeasAfter(floor, 0) = %+v, want just the at-from topic %d", after, atTopicID)
	}
}

// TestIdeas_TranscriptFloorForTime_BoundaryInclusive is the transcript half
// of the same rule.
func TestIdeas_TranscriptFloorForTime_BoundaryInclusive(t *testing.T) {
	d := openTestDB(t)

	from := time.Now().UTC()
	beforeID := mustCreateTranscriptAt(t, d, from.Add(-time.Hour).Format(time.RFC3339))
	atID := mustCreateTranscriptAt(t, d, from.Format(time.RFC3339))

	fromISO := from.Format(time.RFC3339)
	floor, err := d.TranscriptFloorForTime(fromISO)
	if err != nil {
		t.Fatalf("TranscriptFloorForTime: %v", err)
	}
	if floor != beforeID {
		t.Fatalf("TranscriptFloorForTime(from) = %d, want %d (the strictly-before transcript — the at-from one must stay re-mineable)", floor, beforeID)
	}

	after, err := d.ListTranscriptsForIdeasAfter(floor, "")
	if err != nil {
		t.Fatalf("ListTranscriptsForIdeasAfter: %v", err)
	}
	if len(after) != 1 || after[0].ID != atID {
		t.Fatalf("ListTranscriptsForIdeasAfter(floor, \"\") = %+v, want just the at-from transcript %d", after, atID)
	}
}

// TestIdeas_HasStreamDigestCovering pins the three coverage shapes the
// backfill engine's coverage-skip check relies on: a row whose
// [period_from, period_to] fully contains the window reports covered; a row
// that only partially overlaps does not; no row at all does not.
func TestIdeas_HasStreamDigestCovering(t *testing.T) {
	d := openTestDB(t)

	if _, err := d.InsertStreamDigest(StreamDigest{
		Source: "gmail", AccountID: 1, PeriodFrom: "2026-01-01T00:00:00Z", PeriodTo: "2026-02-01T00:00:00Z", TopicsJSON: "[]",
	}); err != nil {
		t.Fatalf("InsertStreamDigest: %v", err)
	}

	covered, err := d.HasStreamDigestCovering("gmail", 1, "2026-01-05T00:00:00Z", "2026-01-10T00:00:00Z")
	if err != nil {
		t.Fatalf("HasStreamDigestCovering (fully inside): %v", err)
	}
	if !covered {
		t.Error("HasStreamDigestCovering: want true for a window fully inside the existing row")
	}

	partial, err := d.HasStreamDigestCovering("gmail", 1, "2026-01-20T00:00:00Z", "2026-02-15T00:00:00Z")
	if err != nil {
		t.Fatalf("HasStreamDigestCovering (partial overlap): %v", err)
	}
	if partial {
		t.Error("HasStreamDigestCovering: want false for a window only partially covered")
	}

	otherSource, err := d.HasStreamDigestCovering("jira", 1, "2026-01-05T00:00:00Z", "2026-01-10T00:00:00Z")
	if err != nil {
		t.Fatalf("HasStreamDigestCovering (other source): %v", err)
	}
	if otherSource {
		t.Error("HasStreamDigestCovering: want false for a source with no covering row")
	}

	otherAccount, err := d.HasStreamDigestCovering("gmail", 2, "2026-01-05T00:00:00Z", "2026-01-10T00:00:00Z")
	if err != nil {
		t.Fatalf("HasStreamDigestCovering (other account): %v", err)
	}
	if otherAccount {
		t.Error("HasStreamDigestCovering: want false for an account with no covering row")
	}
}

// TestIdeas_SetIdeasFloorsRoundTrip is SetIdeasFloorsTx's non-tx sibling test.
func TestIdeas_SetIdeasFloorsRoundTrip(t *testing.T) {
	d := openTestDB(t)
	mustSeedWorkspace(t, d)

	if err := d.SetIdeasFloors(3, 4, 5); err != nil {
		t.Fatalf("SetIdeasFloors: %v", err)
	}
	digest, stream, transcript, err := d.GetIdeasFloors()
	if err != nil {
		t.Fatalf("GetIdeasFloors: %v", err)
	}
	if digest != 3 || stream != 4 || transcript != 5 {
		t.Errorf("floors after SetIdeasFloors = (%d,%d,%d), want (3,4,5)", digest, stream, transcript)
	}
}

// TestIdeas_SetIdeasFloorsNoWorkspaceRow pins the same "no silent zero-row
// update" contract as SetIdeasFloorsTx: without a workspace row the UPDATE
// matches nothing and must error rather than succeed silently.
func TestIdeas_SetIdeasFloorsNoWorkspaceRow(t *testing.T) {
	d := openTestDB(t) // deliberately no mustSeedWorkspace
	if err := d.SetIdeasFloors(1, 2, 3); err == nil {
		t.Fatal("SetIdeasFloors: want an error with no workspace row, got nil")
	}
}
