package db

import (
	"database/sql"
	"testing"

	"github.com/pressly/goose/v3"
	_ "modernc.org/sqlite"
)

// TestVoiceRegistryMigration_MovesPrintsIntoAnchoredSamples replays goose up
// to 00079 on a raw connection, seeds the pre-00080 voice_prints shape (one
// person row carrying its own embedding), applies 00080, and asserts the
// in-place data migration: the person row survives (person_key/display_name)
// and its embedding becomes an owner-anchored active voice_samples row tagged
// with the model version literal.
func TestVoiceRegistryMigration_MovesPrintsIntoAnchoredSamples(t *testing.T) {
	raw, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer raw.Close()
	raw.SetMaxOpenConns(1)
	if _, err := raw.Exec("PRAGMA foreign_keys=ON"); err != nil {
		t.Fatal(err)
	}
	if err := goose.UpTo(raw, "migrations", 79); err != nil {
		t.Fatalf("migrate to v79: %v", err)
	}

	emb := make([]byte, 256*4)
	emb[0] = 0x3f
	if _, err := raw.Exec(`INSERT INTO voice_prints (person_key, display_name, embedding, sample_count)
		VALUES ('alice@example.com', 'Alice', ?, 3)`, emb); err != nil {
		t.Fatal(err)
	}

	for _, id := range []string{"meeting.speaker_guess", "meeting.recap"} {
		if _, err := raw.Exec(`INSERT OR IGNORE INTO prompts (id, template) VALUES (?, 'x')`, id); err != nil {
			t.Fatal(err)
		}
	}

	if err := goose.UpByOne(raw, "migrations"); err != nil {
		t.Fatalf("apply 00080: %v", err)
	}

	var retired, live int
	if err := raw.QueryRow(`SELECT count(*) FROM prompts WHERE id = 'meeting.speaker_guess'`).Scan(&retired); err != nil || retired != 0 {
		t.Fatalf("retired meeting.speaker_guess prompt row must be deregistered: n=%d err=%v", retired, err)
	}
	if err := raw.QueryRow(`SELECT count(*) FROM prompts WHERE id = 'meeting.recap'`).Scan(&live); err != nil || live != 1 {
		t.Fatalf("the DELETE must be scoped to the retired id: n=%d err=%v", live, err)
	}

	var n int
	if err := raw.QueryRow(`SELECT count(*) FROM voice_prints WHERE person_key='alice@example.com' AND display_name='Alice'`).Scan(&n); err != nil || n != 1 {
		t.Fatalf("person row: n=%d err=%v", n, err)
	}
	var origin, status, model string
	var anchor int
	var got []byte
	err = raw.QueryRow(`SELECT s.origin, s.status, s.model_version, s.anchor, s.embedding
		FROM voice_samples s JOIN voice_prints p ON p.id = s.person_id
		WHERE p.person_key='alice@example.com'`).Scan(&origin, &status, &model, &anchor, &got)
	if err != nil {
		t.Fatal(err)
	}
	if origin != "owner" || status != "active" || model != "fluidaudio-wespeaker-v1" || anchor != 1 || len(got) != len(emb) {
		t.Fatalf("sample = %s %s %s %d len=%d", origin, status, model, anchor, len(got))
	}
}

// TestVoiceRegistryMigration_QueueRejectsBadReasonAndDuplicatePending runs on
// a fully-migrated DB and covers the new voice_label_queue CHECK constraint
// (reason must be one of the five known values) plus its partial unique
// index (at most one pending task per transcript+cluster_label).
func TestVoiceRegistryMigration_QueueRejectsBadReasonAndDuplicatePending(t *testing.T) {
	d := openTestDB(t)
	res, err := d.Exec(`INSERT INTO meeting_transcripts (title, transcript_text) VALUES ('t', 'x')`)
	if err != nil {
		t.Fatal(err)
	}
	tid, _ := res.LastInsertId()
	if _, err := d.Exec(`INSERT INTO voice_label_queue (transcript_id, cluster_label, reason) VALUES (?, 'Speaker 1', 'bogus')`, tid); err == nil {
		t.Fatal("bad reason accepted")
	}
	if _, err := d.Exec(`INSERT INTO voice_label_queue (transcript_id, cluster_label, reason) VALUES (?, 'Speaker 1', 'unknown')`, tid); err != nil {
		t.Fatal(err)
	}
	if _, err := d.Exec(`INSERT INTO voice_label_queue (transcript_id, cluster_label, reason) VALUES (?, 'Speaker 1', 'unsure')`, tid); err == nil {
		t.Fatal("second pending task for the same cluster accepted")
	}
}
