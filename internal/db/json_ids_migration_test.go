package db

import (
	"database/sql"
	"testing"

	"github.com/pressly/goose/v3"
	_ "modernc.org/sqlite"
)

// TestMigration00054_TracksChannelIDs replays goose up to 00053 on a raw
// connection, seeds three pre-00054 tracks.channel_ids shapes in the SAME
// table (a fully-bare pair, an already-namespaced single-element array, and
// a mixed array), then applies 00054 and asserts each is rewritten
// correctly — including that the already-namespaced row comes back
// byte-identical (the migration's WHERE...EXISTS clause must skip a row
// with nothing left to rewrite, not just re-serialize it to an equal
// value).
func TestMigration00054_TracksChannelIDs(t *testing.T) {
	raw, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer raw.Close()
	raw.SetMaxOpenConns(1)
	if _, err := raw.Exec("PRAGMA foreign_keys=ON"); err != nil {
		t.Fatal(err)
	}
	if err := goose.UpTo(raw, "migrations", 53); err != nil {
		t.Fatalf("migrate to v53: %v", err)
	}

	if _, err := raw.Exec(`INSERT INTO tracks (id, text, channel_ids) VALUES
		(1, 'bare pair', '["C0473A5GC6N","C03GB81BHUJ"]'),
		(2, 'already namespaced', '["1:C0473A5GC6N"]'),
		(3, 'mixed', '["C1","1:C2"]')`); err != nil {
		t.Fatalf("seed tracks: %v", err)
	}

	if err := goose.UpTo(raw, "migrations", 54); err != nil {
		t.Fatalf("apply 00054: %v", err)
	}

	var bare, namespaced, mixed string
	if err := raw.QueryRow(`SELECT channel_ids FROM tracks WHERE id = 1`).Scan(&bare); err != nil {
		t.Fatalf("read bare pair: %v", err)
	}
	if bare != `["1:C0473A5GC6N","1:C03GB81BHUJ"]` {
		t.Errorf("bare pair channel_ids = %q, want both elements 1:-prefixed", bare)
	}

	if err := raw.QueryRow(`SELECT channel_ids FROM tracks WHERE id = 2`).Scan(&namespaced); err != nil {
		t.Fatalf("read already-namespaced: %v", err)
	}
	if namespaced != `["1:C0473A5GC6N"]` {
		t.Errorf("already-namespaced channel_ids = %q, want byte-identical (no double prefix)", namespaced)
	}

	if err := raw.QueryRow(`SELECT channel_ids FROM tracks WHERE id = 3`).Scan(&mixed); err != nil {
		t.Fatalf("read mixed array: %v", err)
	}
	if mixed != `["1:C1","1:C2"]` {
		t.Errorf("mixed array channel_ids = %q, want [\"1:C1\",\"1:C2\"]", mixed)
	}
}

// TestMigration00054_TracksParticipants covers the object-array shape:
// only $.user_id is rewritten, every other field of the object (name,
// stance) survives untouched, and the rebuilt element is still a genuine
// JSON object rather than a double-encoded string — the specific failure
// mode json_group_array(json_set(...)) could produce if this modernc build
// did not preserve the JSON subtype through the aggregate.
func TestMigration00054_TracksParticipants(t *testing.T) {
	raw, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer raw.Close()
	raw.SetMaxOpenConns(1)
	if _, err := raw.Exec("PRAGMA foreign_keys=ON"); err != nil {
		t.Fatal(err)
	}
	if err := goose.UpTo(raw, "migrations", 53); err != nil {
		t.Fatalf("migrate to v53: %v", err)
	}

	const seed = `[{"name":"@A","user_id":"U010F2S53JM","stance":"инициатор"},{"name":"@B","user_id":"1:U0975M7FJR5","stance":"x"}]`
	if _, err := raw.Exec(`INSERT INTO tracks (id, text, participants) VALUES (1, 'participants track', ?)`, seed); err != nil {
		t.Fatalf("seed tracks.participants: %v", err)
	}

	if err := goose.UpTo(raw, "migrations", 54); err != nil {
		t.Fatalf("apply 00054: %v", err)
	}

	var userID0, userID1, name0, stance0, name1, stance1, elemType string
	if err := raw.QueryRow(`SELECT json_extract(participants, '$[0].user_id') FROM tracks WHERE id = 1`).Scan(&userID0); err != nil {
		t.Fatalf("read participants[0].user_id: %v", err)
	}
	if userID0 != "1:U010F2S53JM" {
		t.Errorf("participants[0].user_id = %q, want 1:U010F2S53JM", userID0)
	}
	if err := raw.QueryRow(`SELECT json_extract(participants, '$[1].user_id') FROM tracks WHERE id = 1`).Scan(&userID1); err != nil {
		t.Fatalf("read participants[1].user_id: %v", err)
	}
	if userID1 != "1:U0975M7FJR5" {
		t.Errorf("participants[1].user_id = %q, want 1:U0975M7FJR5 (already namespaced, untouched)", userID1)
	}

	if err := raw.QueryRow(`SELECT json_extract(participants, '$[0].name'), json_extract(participants, '$[0].stance') FROM tracks WHERE id = 1`).
		Scan(&name0, &stance0); err != nil {
		t.Fatalf("read participants[0] name/stance: %v", err)
	}
	if name0 != "@A" || stance0 != "инициатор" {
		t.Errorf("participants[0] name/stance = %q/%q, want @A/инициатор (preserved exactly)", name0, stance0)
	}
	if err := raw.QueryRow(`SELECT json_extract(participants, '$[1].name'), json_extract(participants, '$[1].stance') FROM tracks WHERE id = 1`).
		Scan(&name1, &stance1); err != nil {
		t.Fatalf("read participants[1] name/stance: %v", err)
	}
	if name1 != "@B" || stance1 != "x" {
		t.Errorf("participants[1] name/stance = %q/%q, want @B/x (preserved exactly)", name1, stance1)
	}

	if err := raw.QueryRow(`SELECT json_type(participants, '$[0]') FROM tracks WHERE id = 1`).Scan(&elemType); err != nil {
		t.Fatalf("read participants[0] json_type: %v", err)
	}
	if elemType != "object" {
		t.Fatalf("json_type(participants,'$[0]') = %q, want 'object' — json_group_array double-encoded the rewritten element as a string", elemType)
	}
}

// TestMigration00054_ParticipantsDangerousShapes covers participant shapes
// that unvalidated model JSON can actually produce — tracks.participants
// is json.RawMessage from the AI model, checked only for json.Valid before
// being stored (internal/tracks/pipeline.go, jsonOrEmpty), so nothing
// guarantees every element is an object with a string user_id:
//
//   - a user_id that is itself a JSON object or array must be left alone,
//     never stringified-and-prefixed (addressing the decoded je.value
//     instead of the outer document by path does exactly that: json_extract
//     returns TEXT for both an object and a string, so a naive
//     typeof(json_extract(...))='text' check cannot tell them apart);
//   - an array element that is a bare string rather than an object must not
//     abort the whole migration (json_extract(je.value, path) on a decoded,
//     dequoted string throws "malformed JSON" — see
//     TestMigration00054_EdgeCasesUntouched's doc comment for why).
func TestMigration00054_ParticipantsDangerousShapes(t *testing.T) {
	raw, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer raw.Close()
	raw.SetMaxOpenConns(1)
	if _, err := raw.Exec("PRAGMA foreign_keys=ON"); err != nil {
		t.Fatal(err)
	}
	if err := goose.UpTo(raw, "migrations", 53); err != nil {
		t.Fatalf("migrate to v53: %v", err)
	}

	if _, err := raw.Exec(`INSERT INTO tracks (id, text, participants) VALUES
		(1, 'object user_id', '[{"name":"@A","user_id":{"a":1},"stance":"s"}]'),
		(2, 'array user_id', '[{"name":"@B","user_id":["x","y"],"stance":"s"}]'),
		(3, 'bare string element', '["U1",{"name":"@C","user_id":"U2","stance":"s"}]'),
		(4, 'missing user_id', '[{"name":"@F","stance":"s"}]')`); err != nil {
		t.Fatalf("seed tracks: %v", err)
	}

	if err := goose.UpTo(raw, "migrations", 54); err != nil {
		t.Fatalf("apply 00054: %v", err)
	}

	var objType string
	if err := raw.QueryRow(`SELECT json_type(participants, '$[0].user_id') FROM tracks WHERE id = 1`).Scan(&objType); err != nil {
		t.Fatalf("read row 1 user_id type: %v", err)
	}
	if objType != "object" {
		t.Errorf("row 1 (object user_id) json_type = %q, want 'object' (must not be stringified)", objType)
	}

	var arrType string
	if err := raw.QueryRow(`SELECT json_type(participants, '$[0].user_id') FROM tracks WHERE id = 2`).Scan(&arrType); err != nil {
		t.Fatalf("read row 2 user_id type: %v", err)
	}
	if arrType != "array" {
		t.Errorf("row 2 (array user_id) json_type = %q, want 'array' (must not be stringified)", arrType)
	}

	var elem0, elem1UserID string
	if err := raw.QueryRow(`SELECT json_extract(participants, '$[0]'), json_extract(participants, '$[1].user_id') FROM tracks WHERE id = 3`).
		Scan(&elem0, &elem1UserID); err != nil {
		t.Fatalf("read row 3 (bare string element): %v", err)
	}
	if elem0 != "U1" {
		t.Errorf("row 3 elem[0] = %q, want U1 (untouched)", elem0)
	}
	if elem1UserID != "1:U2" {
		t.Errorf("row 3 elem[1].user_id = %q, want 1:U2 (the object element must still get rewritten)", elem1UserID)
	}

	var missingKeyName string
	if err := raw.QueryRow(`SELECT json_extract(participants, '$[0].name') FROM tracks WHERE id = 4`).Scan(&missingKeyName); err != nil {
		t.Fatalf("read row 4 (missing user_id): %v", err)
	}
	if missingKeyName != "@F" {
		t.Errorf("row 4 name = %q, want @F (untouched, no crash on a missing key)", missingKeyName)
	}
}

// TestMigration00054_FlatArrayNonTextElement pins a subtype guarantee that
// otherwise rests on nothing: a flat array containing a non-text (object)
// element alongside a real id string must have the string rewritten and
// the object left alone — not crashed on, not stringified.
func TestMigration00054_FlatArrayNonTextElement(t *testing.T) {
	raw, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer raw.Close()
	raw.SetMaxOpenConns(1)
	if _, err := raw.Exec("PRAGMA foreign_keys=ON"); err != nil {
		t.Fatal(err)
	}
	if err := goose.UpTo(raw, "migrations", 53); err != nil {
		t.Fatalf("migrate to v53: %v", err)
	}

	if _, err := raw.Exec(`INSERT INTO tracks (id, text, channel_ids) VALUES (1, 'non-text element', '["C1",{"a":1}]')`); err != nil {
		t.Fatalf("seed tracks: %v", err)
	}

	if err := goose.UpTo(raw, "migrations", 54); err != nil {
		t.Fatalf("apply 00054: %v", err)
	}

	var elem0, elem1Type string
	if err := raw.QueryRow(`SELECT json_extract(channel_ids, '$[0]'), json_type(channel_ids, '$[1]') FROM tracks WHERE id = 1`).
		Scan(&elem0, &elem1Type); err != nil {
		t.Fatalf("read: %v", err)
	}
	if elem0 != "1:C1" {
		t.Errorf("elem[0] = %q, want 1:C1", elem0)
	}
	if elem1Type != "object" {
		t.Errorf("elem[1] json_type = %q, want 'object' (must not be stringified)", elem1Type)
	}
}

// TestMigration00054_UserProfileListColumns covers the four flat-array
// user_profile columns in one row, since they share the exact same shape
// and rewrite logic as tracks.channel_ids.
func TestMigration00054_UserProfileListColumns(t *testing.T) {
	raw, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer raw.Close()
	raw.SetMaxOpenConns(1)
	if _, err := raw.Exec("PRAGMA foreign_keys=ON"); err != nil {
		t.Fatal(err)
	}
	if err := goose.UpTo(raw, "migrations", 53); err != nil {
		t.Fatalf("migrate to v53: %v", err)
	}

	if _, err := raw.Exec(`INSERT INTO user_profile (id, slack_user_id, reports, peers, starred_channels, starred_people) VALUES
		(1, '1:U0000', '["U0001"]', '["U0002"]', '["C0001"]', '["U0003"]')`); err != nil {
		t.Fatalf("seed user_profile: %v", err)
	}

	if err := goose.UpTo(raw, "migrations", 54); err != nil {
		t.Fatalf("apply 00054: %v", err)
	}

	var reports, peers, starredChannels, starredPeople string
	if err := raw.QueryRow(`SELECT reports, peers, starred_channels, starred_people FROM user_profile WHERE id = 1`).
		Scan(&reports, &peers, &starredChannels, &starredPeople); err != nil {
		t.Fatalf("read user_profile list columns: %v", err)
	}
	if reports != `["1:U0001"]` {
		t.Errorf("reports = %q, want [\"1:U0001\"]", reports)
	}
	if peers != `["1:U0002"]` {
		t.Errorf("peers = %q, want [\"1:U0002\"]", peers)
	}
	if starredChannels != `["1:C0001"]` {
		t.Errorf("starred_channels = %q, want [\"1:C0001\"]", starredChannels)
	}
	if starredPeople != `["1:U0003"]` {
		t.Errorf("starred_people = %q, want [\"1:U0003\"]", starredPeople)
	}
}

// TestMigration00054_EdgeCasesUntouched seeds an empty array, an empty
// string and a malformed value into tracks.channel_ids ALONGSIDE a row
// that genuinely needs rewriting, all in the same table scan, and asserts
// the three edge cases come back byte-identical.
//
// The control row sharing the scan with the edge cases matters because
// json_each.value is a DECODED SQL value, not JSON source text: for a
// string element it is the dequoted string, which is no longer valid JSON
// on its own. Feeding it back into json_type()/json_extract() as if it
// were JSON text throws "malformed JSON" — not because of anything about
// row count or empty arrays, but because e.g. json_type('C1') fails on its
// own, standalone, for the same reason. je.type (the column json_each
// already provides) reports the decoded type directly, with no re-parse.
func TestMigration00054_EdgeCasesUntouched(t *testing.T) {
	raw, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer raw.Close()
	raw.SetMaxOpenConns(1)
	if _, err := raw.Exec("PRAGMA foreign_keys=ON"); err != nil {
		t.Fatal(err)
	}
	if err := goose.UpTo(raw, "migrations", 53); err != nil {
		t.Fatalf("migrate to v53: %v", err)
	}

	if _, err := raw.Exec(`INSERT INTO tracks (id, text, channel_ids) VALUES
		(1, 'control (needs rewrite)', '["C1"]'),
		(2, 'empty array', '[]'),
		(3, 'empty string', ''),
		(4, 'malformed', 'not json')`); err != nil {
		t.Fatalf("seed tracks: %v", err)
	}

	if err := goose.UpTo(raw, "migrations", 54); err != nil {
		t.Fatalf("apply 00054: %v", err)
	}

	var control, emptyArray, emptyString, malformed string
	if err := raw.QueryRow(`SELECT channel_ids FROM tracks WHERE id = 1`).Scan(&control); err != nil {
		t.Fatalf("read control row: %v", err)
	}
	if control != `["1:C1"]` {
		t.Errorf("control row channel_ids = %q, want [\"1:C1\"] (migration must still run on the rest of the table)", control)
	}
	if err := raw.QueryRow(`SELECT channel_ids FROM tracks WHERE id = 2`).Scan(&emptyArray); err != nil {
		t.Fatalf("read empty array row: %v", err)
	}
	if emptyArray != `[]` {
		t.Errorf("empty array channel_ids = %q, want [] (untouched)", emptyArray)
	}
	if err := raw.QueryRow(`SELECT channel_ids FROM tracks WHERE id = 3`).Scan(&emptyString); err != nil {
		t.Fatalf("read empty string row: %v", err)
	}
	if emptyString != `` {
		t.Errorf("empty string channel_ids = %q, want \"\" (untouched)", emptyString)
	}
	if err := raw.QueryRow(`SELECT channel_ids FROM tracks WHERE id = 4`).Scan(&malformed); err != nil {
		t.Fatalf("read malformed row: %v", err)
	}
	if malformed != `not json` {
		t.Errorf("malformed channel_ids = %q, want \"not json\" (untouched)", malformed)
	}
}

// TestMigration00054_ReRunIsNoOp applies 00054 once, then re-executes the
// Up block's statements a second time directly (pulled from the embedded
// migration file, so the test can never drift from the SQL that actually
// ships) against the already-migrated data, and asserts nothing changes —
// the WHERE...EXISTS guard on each statement must make re-application safe.
func TestMigration00054_ReRunIsNoOp(t *testing.T) {
	raw, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer raw.Close()
	raw.SetMaxOpenConns(1)
	if _, err := raw.Exec("PRAGMA foreign_keys=ON"); err != nil {
		t.Fatal(err)
	}
	if err := goose.UpTo(raw, "migrations", 53); err != nil {
		t.Fatalf("migrate to v53: %v", err)
	}

	if _, err := raw.Exec(`INSERT INTO tracks (id, text, channel_ids, participants) VALUES
		(1, 'reruncheck', '["C1","1:C2"]', '[{"name":"@A","user_id":"U1","stance":"s"}]')`); err != nil {
		t.Fatalf("seed tracks: %v", err)
	}
	if _, err := raw.Exec(`INSERT INTO user_profile (id, slack_user_id, reports, peers, starred_channels, starred_people) VALUES
		(1, '1:U0000', '["U0001"]', '["U0002"]', '["C0001"]', '["U0003"]')`); err != nil {
		t.Fatalf("seed user_profile: %v", err)
	}

	if err := goose.UpTo(raw, "migrations", 54); err != nil {
		t.Fatalf("apply 00054: %v", err)
	}

	before := snapshotJSONIDColumns(t, raw)

	for _, stmt := range migration00054UpStatements(t) {
		if _, err := raw.Exec(stmt); err != nil {
			t.Fatalf("re-running Up statement failed: %v\n%s", err, stmt)
		}
	}

	after := snapshotJSONIDColumns(t, raw)
	if before != after {
		t.Errorf("re-running 00054's Up statements changed data:\nbefore: %s\nafter:  %s", before, after)
	}
}

// TestMigration00054DownUpCycle seeds the pre-00054 shape, applies 00054,
// walks its own Down back to 00053 and asserts the ids are bare again, then
// re-applies Up and asserts they're namespaced again — the
// TestMigration00049DownUpCycle shape.
func TestMigration00054DownUpCycle(t *testing.T) {
	raw, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer raw.Close()
	raw.SetMaxOpenConns(1)
	if _, err := raw.Exec("PRAGMA foreign_keys=ON"); err != nil {
		t.Fatal(err)
	}
	if err := goose.UpTo(raw, "migrations", 53); err != nil {
		t.Fatalf("migrate to v53: %v", err)
	}

	if _, err := raw.Exec(`INSERT INTO tracks (id, text, channel_ids, participants) VALUES
		(1, 'downup', '["C1"]', '[{"name":"@A","user_id":"U1","stance":"s"}]')`); err != nil {
		t.Fatalf("seed tracks: %v", err)
	}

	if err := goose.UpTo(raw, "migrations", 54); err != nil {
		t.Fatalf("apply 00054: %v", err)
	}
	var channelIDs, userID string
	if err := raw.QueryRow(`SELECT channel_ids, json_extract(participants, '$[0].user_id') FROM tracks WHERE id = 1`).
		Scan(&channelIDs, &userID); err != nil {
		t.Fatalf("read after up: %v", err)
	}
	if channelIDs != `["1:C1"]` || userID != "1:U1" {
		t.Fatalf("after up: channel_ids=%q user_id=%q, want namespaced", channelIDs, userID)
	}

	if err := goose.DownTo(raw, "migrations", 53); err != nil {
		t.Fatalf("goose down to 53: %v", err)
	}
	if err := raw.QueryRow(`SELECT channel_ids, json_extract(participants, '$[0].user_id') FROM tracks WHERE id = 1`).
		Scan(&channelIDs, &userID); err != nil {
		t.Fatalf("read after down: %v", err)
	}
	if channelIDs != `["C1"]` || userID != "U1" {
		t.Errorf("after down: channel_ids=%q user_id=%q, want bare", channelIDs, userID)
	}

	if err := goose.UpTo(raw, "migrations", 54); err != nil {
		t.Fatalf("re-apply 00054: %v", err)
	}
	if err := raw.QueryRow(`SELECT channel_ids, json_extract(participants, '$[0].user_id') FROM tracks WHERE id = 1`).
		Scan(&channelIDs, &userID); err != nil {
		t.Fatalf("read after re-up: %v", err)
	}
	if channelIDs != `["1:C1"]` || userID != "1:U1" {
		t.Errorf("after re-up: channel_ids=%q user_id=%q, want namespaced again", channelIDs, userID)
	}
}

// snapshotJSONIDColumns concatenates every column touched by 00054 across
// both seeded tables, for a cheap before/after equality check. The ORDER BY
// has to sit inside the sub-select: group_concat() itself has no ordering
// guarantee over the rows it aggregates, only over pre-sorted input.
func snapshotJSONIDColumns(t *testing.T, raw *sql.DB) string {
	t.Helper()
	var tracksSnap, profileSnap string
	if err := raw.QueryRow(`SELECT group_concat(row) FROM (
		SELECT id || ':' || channel_ids || ':' || participants AS row FROM tracks ORDER BY id
	)`).Scan(&tracksSnap); err != nil {
		t.Fatalf("snapshot tracks: %v", err)
	}
	if err := raw.QueryRow(`SELECT group_concat(row) FROM (
		SELECT id || ':' || reports || ':' || peers || ':' || starred_channels || ':' || starred_people AS row
		FROM user_profile ORDER BY id
	)`).Scan(&profileSnap); err != nil {
		t.Fatalf("snapshot user_profile: %v", err)
	}
	return tracksSnap + "|" + profileSnap
}

// migration00054UpStatements pulls the six Up-block UPDATE statements out
// of the migration file itself, so TestMigration00054_ReRunIsNoOp can never
// drift from the SQL that actually ships.
func migration00054UpStatements(t *testing.T) []string {
	t.Helper()
	raw, err := migrationsFS.ReadFile("migrations/00054_namespace_json_slack_ids.sql")
	if err != nil {
		t.Fatalf("reading migration 00054: %v", err)
	}
	text := string(raw)
	markers := []string{
		"UPDATE tracks\nSET channel_ids = (",
		"UPDATE user_profile\nSET reports = (",
		"UPDATE user_profile\nSET peers = (",
		"UPDATE user_profile\nSET starred_channels = (",
		"UPDATE user_profile\nSET starred_people = (",
		"UPDATE tracks\nSET participants = (",
	}
	stmts := make([]string, 0, len(markers))
	for _, m := range markers {
		stmts = append(stmts, extractStatement(t, text, m, "migration 00054"))
	}
	return stmts
}
