# Voice Registry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single-centroid voice-print system with a per-sample voice registry that names speakers across meetings, asks the owner only about unsure/unknown voices through a post-meeting "who spoke" window, keeps learning from confident matches anchored to owner confirmations, relabels past recordings, and imports/exports encrypted embeddings.

**Architecture:** Go owns only the schema (migration 00077) and passes the enriched `speakers_json` through `transcript save` untouched. All logic is Swift: pure policy/matching/grouping/crypto in `WatchtowerCore` (tested in `Tests/Core`), persistence in GRDB query enums, orchestration in a new `VoiceRegistryCenter` on `AppState`, integration into `MeetingRecorderCenter.renderRoles`, and a new "Voices" window opened from the tray, notifications and the Transcript tab. The LLM speaker-guess feature and the in-transcript rename are removed.

**Tech Stack:** Go 1.25 + goose + modernc sqlite; Swift 5.10 language mode, SwiftUI, GRDB, CryptoKit + CommonCrypto (PBKDF2), AVFoundation.

**Spec:** `docs/superpowers/specs/2026-09-28-voice-registry-design.md`

## Global Constraints

- Thresholds (single source `VoiceRegistryPolicy`): confident ≥ 0.70 with margin ≥ 0.10 over the runner-up; confident without an event ≥ 0.75; unsure band 0.55 ≤ best < 0.70; self-training ≥ 0.80 + margin + anchor match ≥ 0.70 + `speech_sec` ≥ 30; cap 20 active `auto` samples per person per channel; min clean speech per cluster 20 s; clips ≥ 4 s, max 10 s, 2–3 per cluster; export ≤ 5 samples per person per channel; import conflict similarity ≥ 0.80.
- Embedding model version string: `"fluidaudio-wespeaker-v1"` — identical in the Go migration SQL and `VoiceRegistryPolicy.embeddingModelVersion`.
- Invariants 1–5 of spec §1.6 hold at every write site.
- Retro relabel changes only clusters whose effective `label_source` is `none` (label matches `^Speaker \d+$`).
- No clip files are ever written to disk; clips play from the `.caf` time range.
- Export file: AES-GCM, key = PBKDF2-HMAC-SHA256(password, 16-byte random salt, 200 000 iterations, 32 bytes); never audio, text, meeting titles, dates or recording ids.
- Settings keys: `transcription.voiceRecognition` (absent = on), `transcription.voiceNotifications` (absent = on).
- Repo is public: no live names, emails, meeting titles or stats in tests, fixtures, docs or commit messages — use `alice@example.com`, "Colleague A".
- Inner loop: `go test ./internal/<pkg>`; `make test-swift FILTER=<TestClass>`; Core logic tests go in `WatchtowerDesktop/Tests/Core`. Gate before PR: `make test`, `make test-swift`, `make lint-all`.
- Desktop conventions in `docs/review/review-rules.md` ("Swift / Desktop conventions") apply to every Swift task.

## Review Focus

1. **Two clusters of one recording both confidently match the same person** → only the higher-scoring cluster gets the name; the other becomes `unsure` (a person speaks as one cluster per recording). Pinned in Task 3.
2. **The owner's «Я» cluster and retro relabel** → retro never renames «Я» (it is not `Speaker N`) and the registry never names a cluster that `RoleAssigner.detectSelf` labeled «Я». Pinned in Tasks 9 and 11.
3. **A person without an email (name-keyed `person_key`) and the invite check** → invited when an attendee's display name matches case-insensitively, the way `VoicePrintMatcher.scoped` matched before. Pinned in Task 11.
4. **Corrupt or dimension-mismatched embedding BLOBs** (legacy rows, imports) → the sample is skipped, never crashes, never matches. Pinned in Task 3.
5. **A queued task goes stale** (the cluster was relabeled by retro or by another confirm while the task waited) → Confirm reports "already labeled" and closes the task without writing. Pinned in Task 8.

---

## File Structure

**Go**
- Create `internal/db/migrations/00077_voice_registry.sql` — rebuild `voice_prints`, new `voice_samples`, `voice_imports`, `voice_label_queue`, `meeting_transcripts.speaker_names_changed_at`.
- Modify `internal/db/schema.sql`, `internal/db/testdata/schema_v73.golden` (regenerated), `internal/db/db_test.go` (table list).
- Modify `cmd/meeting_transcript.go` — `loadTranscriptSpeakers` preserves unknown JSON fields; delete the `speaker-guess` command.
- Modify `internal/meeting/speakers.go` — parse validates, raw objects kept.
- Delete `internal/meeting/speaker_guess.go`, `internal/meeting/speaker_guess_test.go`; modify `internal/prompts/{store.go,defaults.go}`, `internal/digest/models.go`, `cmd/meeting_transcript_test.go`.

**Swift — WatchtowerCore (`WatchtowerDesktop/Sources/WatchtowerCore/`)**
- Modify `Models/VoicePrint.swift` — `VoicePrint` becomes a person; `SpeakerEmbedding` gains optional registry fields; `ClipSpan`, `VoiceLabelSource`.
- Create `Models/VoiceSample.swift` — `VoiceSample`, `VoiceSampleOrigin`, `VoiceSampleStatus`, `VoiceChannel`.
- Create `Models/VoiceImport.swift`, `Models/VoiceLabelTask.swift`.
- Create `Services/VoiceRegistry/VoiceRegistryPolicy.swift` — constants.
- Create `Services/VoiceRegistry/VoiceMatcher.swift` — nearest-sample scoring, bands, per-recording uniqueness.
- Create `Services/VoiceRegistry/VoiceLearning.swift` — self-training decision.
- Create `Services/VoiceRegistry/VoiceGrouping.swift` — train-mode grouping + accuracy estimate.
- Create `Services/VoiceRegistry/VoiceExportCodec.swift` — file format + crypto.

**Swift — Desktop target (`WatchtowerDesktop/Sources/`)**
- Rewrite `Database/Queries/VoicePrintQueries.swift` — person CRUD.
- Create `Database/Queries/VoiceSampleQueries.swift`, `VoiceLabelQueueQueries.swift`, `VoiceImportQueries.swift`, `VoiceLabelingQueries.swift` (confirm/rollback/retro transactions).
- Modify `Database/Queries/MeetingTranscriptQueries.swift` — `renameSpeaker` → `relabelCluster`.
- Create `Services/Transcription/ClusterFeatures.swift` — channel, speech seconds, clip spans.
- Delete `Services/Transcription/VoicePrintMatcher.swift` (logic moves to `VoiceMatcher`; `isOwnerPrint` moves to `VoicePrintQueries`).
- Modify `Services/MeetingRecorderCenter.swift` — registry identification.
- Create `Services/VoiceRegistryCenter.swift`, `Services/ClipPlayer.swift`, `Services/VoiceRetroRelabeler.swift`.
- Create `Views/Voices/VoicesWindowView.swift`, `VoiceCardView.swift`, `VoiceReviewView.swift`, `VoiceTrainView.swift`, `VoiceImportExportView.swift`.
- Modify `App/AppState.swift`, `App/WatchtowerApp.swift`, `Views/TrayMenuView.swift`, `Services/NotificationService.swift`, `Views/Settings/MeetingsSettings.swift`, `Services/Transcription/TranscriptionEngine.swift`, `Views/Calendar/RecordingDetailTabs.swift`, `Views/Calendar/RecordingDetailView.swift`.
- Delete `Services/SpeakerGuessCenter.swift`, `Tests/SpeakerGuessCenterTests.swift`; trim `WatchtowerCore/Services/TranscriptSaveService.swift`.
- Modify `Tests/Support/TestDatabase+Schema.swift`.

**Docs**
- Modify `CLAUDE.md` (Meeting Transcriber section), `docs/app-guide.md`, `docs/superpowers/specs/2026-07-31-transcript-stack-design.md` (export non-goal superseded).

---

### Task 1: Go migration 00077 and schema

**Files:**
- Create: `internal/db/migrations/00077_voice_registry.sql`
- Modify: `internal/db/schema.sql:1083-1090`, `internal/db/db_test.go:178`
- Regenerate: `internal/db/testdata/schema_v73.golden`
- Test: `internal/db/voice_registry_migration_test.go`

**Interfaces:**
- Produces: tables `voice_prints(id, person_key, display_name, created_at, updated_at)`, `voice_samples`, `voice_imports`, `voice_label_queue`; column `meeting_transcripts.speaker_names_changed_at`. Model version literal `'fluidaudio-wespeaker-v1'`.

- [ ] **Step 1: Write the failing migration test**

```go
package db

import (
	"testing"
)

func TestVoiceRegistryMigration_MovesPrintsIntoAnchoredSamples(t *testing.T) {
	d := openTestDBAtVersion(t, 76) // helper used by other migration tests in this package
	emb := make([]byte, 256*4)
	emb[0] = 0x3f
	if _, err := d.Exec(`INSERT INTO voice_prints (person_key, display_name, embedding, sample_count)
		VALUES ('alice@example.com', 'Alice', ?, 3)`, emb); err != nil {
		t.Fatal(err)
	}
	migrateUpTo(t, d, 77)

	var n int
	if err := d.QueryRow(`SELECT count(*) FROM voice_prints WHERE person_key='alice@example.com' AND display_name='Alice'`).Scan(&n); err != nil || n != 1 {
		t.Fatalf("person row: n=%d err=%v", n, err)
	}
	var origin, status, model string
	var anchor int
	var got []byte
	err := d.QueryRow(`SELECT s.origin, s.status, s.model_version, s.anchor, s.embedding
		FROM voice_samples s JOIN voice_prints p ON p.id = s.person_id
		WHERE p.person_key='alice@example.com'`).Scan(&origin, &status, &model, &anchor, &got)
	if err != nil {
		t.Fatal(err)
	}
	if origin != "owner" || status != "active" || model != "fluidaudio-wespeaker-v1" || anchor != 1 || len(got) != len(emb) {
		t.Fatalf("sample = %s %s %s %d len=%d", origin, status, model, anchor, len(got))
	}
}

func TestVoiceRegistryMigration_QueueRejectsBadReasonAndDuplicatePending(t *testing.T) {
	d := openTestDB(t)
	res, err := d.Exec(`INSERT INTO meeting_transcripts (text, audio_path, duration_sec) VALUES ('x', '', 1)`)
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
```

Before writing, open `internal/db/migrations_test.go` (or the file defining existing per-version migration tests — `grep -rn "func openTestDBAtVersion\|func migrateUpTo" internal/db`) and use the helpers that exist; if the package names them differently, rename the calls above to match — do not add new helpers when equivalents exist. Use the real `meeting_transcripts` required columns from `schema.sql` in the INSERT.

- [ ] **Step 2: Run to verify failure**

Run: `go test ./internal/db -run TestVoiceRegistryMigration -v`
Expected: FAIL — `no such table: voice_samples`.

- [ ] **Step 3: Write the migration**

```sql
-- +goose NO TRANSACTION
-- +goose Up
-- Voice registry (spec docs/superpowers/specs/2026-09-28-voice-registry-design.md).
-- voice_prints becomes a person row; voices live as per-sample rows in
-- voice_samples (nearest-sample matching, owner anchors, self-training,
-- imports). Supersedes 00046's "never exported" note: prints are exported
-- only by an explicit owner action as an encrypted file of embeddings.
-- The model_version literal MUST equal VoiceRegistryPolicy.embeddingModelVersion (Swift).
PRAGMA foreign_keys = OFF;

CREATE TABLE voice_prints_new (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    person_key   TEXT NOT NULL UNIQUE,
    display_name TEXT NOT NULL,
    created_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
INSERT INTO voice_prints_new (id, person_key, display_name, created_at, updated_at)
    SELECT id, person_key, display_name, updated_at, updated_at FROM voice_prints;

CREATE TABLE voice_imports (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    sender_name   TEXT NOT NULL,
    sender_email  TEXT NOT NULL DEFAULT '',
    file_sha256   TEXT NOT NULL UNIQUE,
    people_count  INTEGER NOT NULL,
    sample_count  INTEGER NOT NULL,
    model_version TEXT NOT NULL,
    imported_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

CREATE TABLE voice_samples (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    person_id     INTEGER NOT NULL REFERENCES voice_prints_new(id) ON DELETE CASCADE,
    embedding     BLOB NOT NULL,
    model_version TEXT NOT NULL,
    origin        TEXT NOT NULL CHECK (origin IN ('owner', 'auto', 'imported')),
    anchor        INTEGER NOT NULL DEFAULT 0 CHECK (anchor IN (0, 1)),
    status        TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'pending', 'retired')),
    transcript_id INTEGER REFERENCES meeting_transcripts(id) ON DELETE SET NULL,
    cluster_label TEXT,
    channel       TEXT NOT NULL DEFAULT 'unknown' CHECK (channel IN ('room', 'remote', 'unknown')),
    score         REAL,
    speech_sec    REAL NOT NULL DEFAULT 0,
    import_id     INTEGER REFERENCES voice_imports(id) ON DELETE CASCADE,
    created_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    CHECK (anchor = 0 OR origin = 'owner')
);
INSERT INTO voice_samples (person_id, embedding, model_version, origin, anchor, status)
    SELECT id, embedding, 'fluidaudio-wespeaker-v1', 'owner', 1, 'active' FROM voice_prints;

DROP TABLE voice_prints;
ALTER TABLE voice_prints_new RENAME TO voice_prints;
CREATE INDEX idx_voice_samples_person_status ON voice_samples(person_id, status);
CREATE INDEX idx_voice_samples_transcript ON voice_samples(transcript_id);

CREATE TABLE voice_label_queue (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    transcript_id       INTEGER NOT NULL REFERENCES meeting_transcripts(id) ON DELETE CASCADE,
    cluster_label       TEXT NOT NULL,
    reason              TEXT NOT NULL CHECK (reason IN ('unsure', 'unknown', 'import_confirm', 'conflict', 'relabel')),
    suggested_person_id INTEGER REFERENCES voice_prints(id) ON DELETE SET NULL,
    score               REAL,
    status              TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'done', 'skipped')),
    created_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    resolved_at         TEXT
);
CREATE UNIQUE INDEX idx_voice_label_queue_open ON voice_label_queue(transcript_id, cluster_label) WHERE status = 'pending';
CREATE INDEX idx_voice_label_queue_status ON voice_label_queue(status, created_at);

ALTER TABLE meeting_transcripts ADD COLUMN speaker_names_changed_at TEXT;

PRAGMA foreign_keys = ON;

-- +goose Down
PRAGMA foreign_keys = OFF;
DROP TABLE IF EXISTS voice_label_queue;
CREATE TABLE voice_prints_old (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    person_key   TEXT NOT NULL UNIQUE,
    display_name TEXT NOT NULL,
    embedding    BLOB NOT NULL,
    sample_count INTEGER NOT NULL DEFAULT 1,
    updated_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
INSERT INTO voice_prints_old (id, person_key, display_name, embedding, sample_count, updated_at)
    SELECT p.id, p.person_key, p.display_name,
           (SELECT s.embedding FROM voice_samples s WHERE s.person_id = p.id AND s.anchor = 1 ORDER BY s.id LIMIT 1),
           1, p.updated_at
    FROM voice_prints p
    WHERE EXISTS (SELECT 1 FROM voice_samples s WHERE s.person_id = p.id AND s.anchor = 1);
DROP TABLE voice_samples;
DROP TABLE voice_imports;
DROP TABLE voice_prints;
ALTER TABLE voice_prints_old RENAME TO voice_prints;
ALTER TABLE meeting_transcripts DROP COLUMN speaker_names_changed_at;
PRAGMA foreign_keys = ON;
```

- [ ] **Step 4: Mirror into `schema.sql`** — replace the `voice_prints` block at L1083–1090 with the four `CREATE TABLE` statements (final shape, `REFERENCES voice_prints(id)`), both indexes, the partial unique index, and add `speaker_names_changed_at TEXT` to the `meeting_transcripts` definition. Add `"voice_samples", "voice_imports", "voice_label_queue"` to the table list in `db_test.go:178` (`TestAllTablesExist`).

- [ ] **Step 5: Run and regenerate the snapshot**

Run: `go test ./internal/db -run 'TestVoiceRegistryMigration|TestAllTablesExist' -v && go test ./internal/db -run TestSchemaGolden -update && go test ./internal/db`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add internal/db
git commit -m "feat(db): voice registry schema (migration 00077)"
```

---

### Task 2: Go `transcript save` keeps enriched speakers JSON; remove `speaker_guess`

**Files:**
- Modify: `internal/meeting/speakers.go:15-40`, `cmd/meeting_transcript.go:97-104,126,287-338,667-733`
- Delete: `internal/meeting/speaker_guess.go`, `internal/meeting/speaker_guess_test.go`
- Modify: `internal/prompts/store.go:35`, `internal/prompts/defaults.go:27,71,117,165,1016`, `internal/digest/models.go:19`, `cmd/meeting_transcript_test.go:1000-1080`
- Test: `cmd/meeting_transcript_test.go` (new test near L813–897)

**Interfaces:**
- Produces: `speakers_json` stored byte-for-byte per kept object (unknown fields preserved).

- [ ] **Step 1: Write the failing test** (next to the existing speakers-file tests, reuse `writeSpeakersFile`)

```go
func TestTranscriptSaveSpeakersKeepsRegistryFields(t *testing.T) {
	// A segment speaker "Alice" plus one dropped entry forces the re-encode path.
	speakers := `[{"speaker":"Alice","embedding":[0.1,0.2],"original_label":"Speaker 1","label_source":"auto","person_id":7,"clips":[{"start":1.5,"end":6}]},
	              {"speaker":"Ghost","embedding":[0.3]}]`
	env, row := runTranscriptSaveWithSpeakers(t, speakers) // build from the existing save-test harness in this file
	if env.SpeakersOK {
		t.Fatal("dropped entry must be reported")
	}
	for _, want := range []string{`"original_label":"Speaker 1"`, `"label_source":"auto"`, `"person_id":7`, `"clips":[{"start":1.5,"end":6}]`} {
		if !strings.Contains(row.SpeakersJSON.String, want) {
			t.Fatalf("speakers_json lost %s: %s", want, row.SpeakersJSON.String)
		}
	}
	if strings.Contains(row.SpeakersJSON.String, "Ghost") {
		t.Fatal("unmatched entry kept")
	}
}
```

`runTranscriptSaveWithSpeakers` does not exist: write it inside this test file by copying the setup of the closest existing speakers test (L813–897) — same segments fixture with one utterance whose speaker is `"Alice"` — returning the decoded envelope and the saved `db.MeetingTranscript`.

- [ ] **Step 2: Run to verify failure**

Run: `go test ./cmd -run TestTranscriptSaveSpeakersKeepsRegistryFields -v`
Expected: FAIL — `speakers_json lost "original_label"` (the current `json.Marshal(kept)` drops unknown fields).

- [ ] **Step 3: Implement raw passthrough**

In `internal/meeting/speakers.go` add:

```go
// ParseSpeakerEmbeddingsRaw validates like ParseSpeakerEmbeddings but also
// returns each entry's raw JSON so callers can store Desktop-owned fields
// (voice registry: original_label, label_source, person_id, clips, …) untouched.
func ParseSpeakerEmbeddingsRaw(data []byte) ([]SpeakerEmbedding, []json.RawMessage, error) {
	var raws []json.RawMessage
	if err := json.Unmarshal(data, &raws); err != nil {
		return nil, nil, fmt.Errorf("parsing speaker embeddings: %w", err)
	}
	parsed, err := ParseSpeakerEmbeddings(data)
	if err != nil {
		return nil, nil, err
	}
	return parsed, raws, nil
}
```

In `loadTranscriptSpeakers` switch to `ParseSpeakerEmbeddingsRaw`, collect `keptRaw []json.RawMessage` alongside `kept`, and replace `json.Marshal(kept)` with `json.Marshal(keptRaw)` (a `[]json.RawMessage` marshals each element verbatim).

- [ ] **Step 4: Remove `speaker_guess`**

- Delete `internal/meeting/speaker_guess.go` and `speaker_guess_test.go`. Move `speakerNumberRe`/`reservedSpeakerLabel` into `internal/meeting/speakers.go` only if something else still references them (`grep -rn "reservedSpeakerLabel\|speakerNumberRe" internal cmd`); otherwise delete them too and remove the dual-path note from `SpeakerNaming.isUnnamed` in Task 4.
- In `cmd/meeting_transcript.go` delete `transcriptSpeakerGuessCmd`, its `AddCommand` entry and `runTranscriptSpeakerGuess`; delete the three `TestTranscriptSpeakerGuess*` tests.
- In `internal/prompts` delete the `MeetingSpeakerGuess` constant, its `Defaults`, ordered-id, `DefaultVersions`, description entries and `defaultMeetingSpeakerGuess`.
- In `internal/digest/models.go:19` remove `"meeting.speaker_guess"` from the light-tier case.

- [ ] **Step 5: Run**

Run: `go build ./... && go test ./internal/meeting ./internal/prompts ./internal/digest ./internal/db && go test ./cmd -run 'TestTranscript|TestPromptStoreWiring' -v`
Expected: PASS (the tier and prompt-store property scans stay green).

- [ ] **Step 6: Commit**

```bash
git add -A internal cmd
git commit -m "feat(meeting): keep registry fields in speakers_json; remove speaker_guess"
```

---

### Task 3: Core models, policy and matcher

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Models/VoicePrint.swift`
- Create: `WatchtowerCore/Models/VoiceSample.swift`, `Models/VoiceImport.swift`, `Models/VoiceLabelTask.swift`, `Services/VoiceRegistry/VoiceRegistryPolicy.swift`, `Services/VoiceRegistry/VoiceMatcher.swift`
- Modify: `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift:896,902-909`
- Test: `WatchtowerDesktop/Tests/Core/VoiceMatcherTests.swift`, `Tests/Core/SpeakerEmbeddingRegistryFieldsTests.swift`

**Interfaces:**
- Produces:
  - `package struct VoicePrint { var id: Int64?; let personKey: String; var displayName: String; let createdAt: String; var updatedAt: String }` (table `voice_prints`).
  - `package enum VoiceSampleOrigin: String { owner, auto, imported }`, `VoiceSampleStatus { active, pending, retired }`, `VoiceChannel { room, remote, unknown }`.
  - `package struct VoiceSample: FetchableRecord, PersistableRecord` with fields matching migration columns; `var vector: [Float]` (decoded, empty when corrupt).
  - `package struct VoiceImport`, `package struct VoiceLabelTask` (+ `VoiceLabelReason { unsure, unknown, importConfirm = "import_confirm", conflict, relabel }`, `VoiceLabelTaskStatus { pending, done, skipped }`).
  - `package struct ClipSpan: Codable, Equatable, Sendable { start: Double; end: Double }`.
  - `package enum VoiceLabelSource: String, Codable { owner, auto, none }`.
  - `SpeakerEmbedding` new optional fields: `originalLabel`, `personID: Int64?`, `labelSource: VoiceLabelSource?`, `score: Float?`, `matchedSampleID: Int64?`, `channel: VoiceChannel?`, `clips: [ClipSpan]?`, `speechSec: Double?`, `modelVersion: String?`; `var effectiveLabelSource: VoiceLabelSource`.
  - `VoiceRegistryPolicy` constants (see Global Constraints) + `embeddingModelVersion = "fluidaudio-wespeaker-v1"`.
  - `VoiceMatcher.decide(clusters: [VoiceMatcher.Cluster], samples: [VoiceSample], invited: Set<Int64>?, ownerPersonIDs: Set<Int64>) -> [String: VoiceMatcher.Decision]` where `Cluster { label: String; embedding: [Float]; speechSec: Double }` and
    `enum Decision: Equatable { case confident(personID: Int64, sampleID: Int64, score: Float); case unsure(personID: Int64?, score: Float, reason: VoiceLabelReason); case unknown(bestScore: Float); case tooShort }`.
  - `VoiceMatcher.nearest(embedding: [Float], samples: [VoiceSample]) -> [(personID: Int64, sampleID: Int64, score: Float)]` sorted desc, one entry per person.

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import WatchtowerCore

final class VoiceMatcherTests: XCTestCase {
    private func unit(_ angle: Float) -> [Float] { var v = [Float](repeating: 0, count: 4); v[0] = cos(angle); v[1] = sin(angle); return v }
    private func sample(_ id: Int64, person: Int64, _ v: [Float], status: VoiceSampleStatus = .active,
                        origin: VoiceSampleOrigin = .owner, model: String = VoiceRegistryPolicy.embeddingModelVersion) -> VoiceSample {
        VoiceSample(id: id, personID: person, embedding: VoicePrintEmbedding.encode(v), modelVersion: model,
                    origin: origin, anchor: origin == .owner, status: status)
    }
    private func cluster(_ label: String, _ v: [Float], speech: Double = 60) -> VoiceMatcher.Cluster {
        .init(label: label, embedding: v, speechSec: speech)
    }

    func testNearestSampleWinsOverAveragedCentroid() {
        // person 1 has two channel variants 90° apart; the cluster matches one exactly
        let s = [sample(1, person: 1, unit(0)), sample(2, person: 1, unit(.pi / 2)), sample(3, person: 2, unit(.pi))]
        let d = VoiceMatcher.decide(clusters: [cluster("Speaker 1", unit(.pi / 2))], samples: s, invited: [1, 2], ownerPersonIDs: [])
        XCTAssertEqual(d["Speaker 1"], .confident(personID: 1, sampleID: 2, score: 1))
    }

    func testMarginBelowPointOneIsConflict() {
        let s = [sample(1, person: 1, unit(0)), sample(2, person: 2, unit(0.05))]
        let d = VoiceMatcher.decide(clusters: [cluster("Speaker 1", unit(0.02))], samples: s, invited: [1, 2], ownerPersonIDs: [])
        guard case .unsure(_, _, .conflict) = d["Speaker 1"] else { return XCTFail("\(String(describing: d["Speaker 1"]))") }
    }

    func testNotInvitedStrongMatchIsUnsure() {
        let s = [sample(1, person: 1, unit(0))]
        let d = VoiceMatcher.decide(clusters: [cluster("Speaker 1", unit(0))], samples: s, invited: [9], ownerPersonIDs: [])
        XCTAssertEqual(d["Speaker 1"], .unsure(personID: 1, score: 1, reason: .unsure))
    }

    func testOwnerIsAlwaysInvited() {
        let s = [sample(1, person: 1, unit(0))]
        let d = VoiceMatcher.decide(clusters: [cluster("Speaker 1", unit(0))], samples: s, invited: [9], ownerPersonIDs: [1])
        XCTAssertEqual(d["Speaker 1"], .confident(personID: 1, sampleID: 1, score: 1))
    }

    func testNoEventNeedsPointSevenFive() {
        let s = [sample(1, person: 1, unit(0))]
        let c = cluster("Speaker 1", unit(acos(0.72)))   // cosine 0.72
        XCTAssertEqual(VoiceMatcher.decide(clusters: [c], samples: s, invited: nil, ownerPersonIDs: [])["Speaker 1"],
                       .unsure(personID: 1, score: 0.72, reason: .unsure))
    }

    func testUnsureBandAndUnknown() {
        let s = [sample(1, person: 1, unit(0))]
        let unsure = VoiceMatcher.decide(clusters: [cluster("A", unit(acos(0.6)))], samples: s, invited: [1], ownerPersonIDs: [])
        XCTAssertEqual(unsure["A"], .unsure(personID: 1, score: 0.6, reason: .unsure))
        let unknown = VoiceMatcher.decide(clusters: [cluster("B", unit(acos(0.3)))], samples: s, invited: [1], ownerPersonIDs: [])
        XCTAssertEqual(unknown["B"], .unknown(bestScore: 0.3))
    }

    func testShortClusterNeverMatches() {
        let s = [sample(1, person: 1, unit(0))]
        XCTAssertEqual(VoiceMatcher.decide(clusters: [cluster("A", unit(0), speech: 19)], samples: s, invited: [1], ownerPersonIDs: [])["A"], .tooShort)
    }

    func testPendingImportedOnlyYieldsImportConfirm() {
        let s = [sample(1, person: 1, unit(0), status: .pending, origin: .imported)]
        XCTAssertEqual(VoiceMatcher.decide(clusters: [cluster("A", unit(0))], samples: s, invited: [1], ownerPersonIDs: [])["A"],
                       .unsure(personID: 1, score: 1, reason: .importConfirm))
    }

    func testRetiredAndOtherModelAndCorruptSamplesAreIgnored() {
        var corrupt = sample(3, person: 3, unit(0)); corrupt.embedding = Data([1, 2, 3])
        let s = [sample(1, person: 1, unit(0), status: .retired), sample(2, person: 2, unit(0), model: "other"), corrupt,
                 sample(4, person: 4, [1, 0])]                        // dimension mismatch
        XCTAssertEqual(VoiceMatcher.decide(clusters: [cluster("A", unit(0))], samples: s, invited: [1, 2, 3, 4], ownerPersonIDs: [])["A"],
                       .unknown(bestScore: 0))
    }

    func testOnePersonAtMostOneConfidentClusterPerRecording() {
        let s = [sample(1, person: 1, unit(0))]
        let d = VoiceMatcher.decide(clusters: [cluster("A", unit(0)), cluster("B", unit(acos(0.9)))], samples: s, invited: [1], ownerPersonIDs: [])
        XCTAssertEqual(d["A"], .confident(personID: 1, sampleID: 1, score: 1))
        XCTAssertEqual(d["B"], .unsure(personID: 1, score: 0.9, reason: .unsure))
    }
}
```

Tolerance: compare scores with a helper if exact float equality is flaky — implement `Decision` equality on scores rounded to 3 decimals (`(score * 1000).rounded()`), documented in the type.

`SpeakerEmbeddingRegistryFieldsTests`:

```swift
final class SpeakerEmbeddingRegistryFieldsTests: XCTestCase {
    func testLegacyJSONDecodesWithDerivedLabelSource() throws {
        let legacy = #"[{"speaker":"Speaker 2","embedding":[1,0]},{"speaker":"Alice","embedding":[0,1]},{"speaker":"Я","embedding":[1,1]}]"#
        let s = try XCTUnwrap(SpeakerEmbeddings.decode(legacy))
        XCTAssertEqual(s.map(\.effectiveLabelSource), [.none, .owner, .owner])
        XCTAssertNil(s[0].personID)
    }

    func testRoundTripKeepsRegistryFieldsWithSnakeCaseKeys() throws {
        var e = SpeakerEmbedding(speaker: "Alice", embedding: [1, 0])
        e.originalLabel = "Speaker 1"; e.personID = 7; e.labelSource = .auto; e.matchedSampleID = 3
        e.channel = .remote; e.clips = [ClipSpan(start: 1, end: 5)]; e.speechSec = 42; e.score = 0.8
        e.modelVersion = VoiceRegistryPolicy.embeddingModelVersion
        let json = try XCTUnwrap(SpeakerEmbeddings.encode([e]))
        XCTAssertTrue(json.contains(#""original_label":"Speaker 1""#))
        XCTAssertTrue(json.contains(#""matched_sample_id":3"#))
        XCTAssertEqual(SpeakerEmbeddings.decode(json)?.first, e)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `make test-swift FILTER='VoiceMatcherTests|SpeakerEmbeddingRegistryFieldsTests'`
Expected: compile failure — `VoiceMatcher`, `VoiceSample` not found.

- [ ] **Step 3: Implement models**

`VoicePrint.swift` — replace the `VoicePrint` struct (keep `VoicePrintEmbedding`, `SpeakerNaming`, `SpeakerEmbeddings`):

```swift
package struct VoicePrint: Codable, FetchableRecord, PersistableRecord, Equatable, Identifiable, Sendable {
    package static let databaseTableName = "voice_prints"
    package var id: Int64?
    package let personKey: String
    package var displayName: String
    package var createdAt: String
    package var updatedAt: String

    package init(id: Int64? = nil, personKey: String, displayName: String,
                 createdAt: String = "", updatedAt: String = "") {
        self.id = id; self.personKey = personKey; self.displayName = displayName
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }
    enum CodingKeys: String, CodingKey {
        case id, personKey = "person_key", displayName = "display_name", createdAt = "created_at", updatedAt = "updated_at"
    }
    package mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

package enum VoiceLabelSource: String, Codable, Sendable { case owner, auto, none }
package struct ClipSpan: Codable, Equatable, Sendable {
    package let start: Double; package let end: Double
    package init(start: Double, end: Double) { self.start = start; self.end = end }
}
```

Replace `SpeakerEmbedding`:

```swift
package struct SpeakerEmbedding: Codable, Equatable, Sendable {
    package var speaker: String
    package let embedding: [Float]
    package var originalLabel: String?
    package var personID: Int64?
    package var labelSource: VoiceLabelSource?
    package var score: Float?
    package var matchedSampleID: Int64?
    package var channel: VoiceChannel?
    package var clips: [ClipSpan]?
    package var speechSec: Double?
    package var modelVersion: String?

    package init(speaker: String, embedding: [Float]) { self.speaker = speaker; self.embedding = embedding }

    enum CodingKeys: String, CodingKey {
        case speaker, embedding, originalLabel = "original_label", personID = "person_id", labelSource = "label_source",
             score, matchedSampleID = "matched_sample_id", channel, clips, speechSec = "speech_sec", modelVersion = "model_version"
    }

    /// Legacy rows carry no label_source: an unnamed "Speaker N" is `none`,
    /// anything else (a name, «Я») was set by the owner or the role pass and
    /// retro relabel must never touch it (spec §1.7, invariant 5).
    package var effectiveLabelSource: VoiceLabelSource {
        labelSource ?? (SpeakerNaming.isUnnamed(speaker) ? .none : .owner)
    }
    /// The label retro/rollback restores; legacy rows fall back to the current label.
    package var restoreLabel: String { originalLabel ?? speaker }
}
```

`VoiceSample.swift`:

```swift
import Foundation
import GRDB

package enum VoiceSampleOrigin: String, Codable, Sendable { case owner, auto, imported }
package enum VoiceSampleStatus: String, Codable, Sendable { case active, pending, retired }
package enum VoiceChannel: String, Codable, Sendable { case room, remote, unknown }

package struct VoiceSample: Codable, FetchableRecord, PersistableRecord, Equatable, Identifiable, Sendable {
    package static let databaseTableName = "voice_samples"
    package var id: Int64?
    package var personID: Int64
    package var embedding: Data
    package var modelVersion: String
    package var origin: VoiceSampleOrigin
    package var anchor: Bool
    package var status: VoiceSampleStatus
    package var transcriptID: Int64?
    package var clusterLabel: String?
    package var channel: VoiceChannel
    package var score: Float?
    package var speechSec: Double
    package var importID: Int64?
    package var createdAt: String?

    package init(id: Int64? = nil, personID: Int64, embedding: Data, modelVersion: String, origin: VoiceSampleOrigin,
                 anchor: Bool, status: VoiceSampleStatus, transcriptID: Int64? = nil, clusterLabel: String? = nil,
                 channel: VoiceChannel = .unknown, score: Float? = nil, speechSec: Double = 0, importID: Int64? = nil) {
        self.id = id; self.personID = personID; self.embedding = embedding; self.modelVersion = modelVersion
        self.origin = origin; self.anchor = anchor; self.status = status; self.transcriptID = transcriptID
        self.clusterLabel = clusterLabel; self.channel = channel; self.score = score; self.speechSec = speechSec
        self.importID = importID
    }

    enum CodingKeys: String, CodingKey {
        case id, personID = "person_id", embedding, modelVersion = "model_version", origin, anchor, status,
             transcriptID = "transcript_id", clusterLabel = "cluster_label", channel, score, speechSec = "speech_sec",
             importID = "import_id", createdAt = "created_at"
    }
    package mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    /// Decoded, L2-normalized vector; empty for a corrupt BLOB (never matches).
    package var vector: [Float] { VoiceMatcher.normalize(VoicePrintEmbedding.decode(embedding)) ?? [] }
}
```

`VoiceImport.swift`: `VoiceImport` record over `voice_imports` (`id, senderName, senderEmail, fileSHA256, peopleCount, sampleCount, modelVersion, importedAt`, snake_case CodingKeys, `didInsert`).

`VoiceLabelTask.swift`: `VoiceLabelReason` (raw values `unsure`, `unknown`, `import_confirm`, `conflict`, `relabel`), `VoiceLabelTaskStatus`, and `VoiceLabelTask` record over `voice_label_queue` (`id, transcriptID, clusterLabel, reason, suggestedPersonID, score, status, createdAt, resolvedAt`, `didInsert`).

`VoiceRegistryPolicy.swift`:

```swift
/// Every voice-registry threshold in one place (spec §2, Global Constraints).
package enum VoiceRegistryPolicy {
    package static let embeddingModelVersion = "fluidaudio-wespeaker-v1"   // == migration 00077 literal
    package static let confident: Float = 0.70
    package static let confidentWithoutEvent: Float = 0.75
    package static let margin: Float = 0.10
    package static let unsureFloor: Float = 0.55
    package static let learn: Float = 0.80
    package static let learnAnchorFloor: Float = 0.70
    package static let learnMinSpeechSec: Double = 30
    package static let autoCapPerChannel = 20
    package static let minClusterSpeechSec: Double = 20
    package static let clipMinSec: Double = 4
    package static let clipMaxSec: Double = 10
    package static let clipsPerCluster = 3
    package static let exportPerChannel = 5
    package static let importConflict: Float = 0.80
    package static let groupMerge: Float = 0.60
}
```

`VoiceMatcher.swift`:

```swift
import Foundation

/// Pure nearest-sample voice identification (spec §2.2). No I/O.
package enum VoiceMatcher {
    package struct Cluster: Equatable, Sendable {
        package let label: String; package let embedding: [Float]; package let speechSec: Double
        package init(label: String, embedding: [Float], speechSec: Double) {
            self.label = label; self.embedding = embedding; self.speechSec = speechSec
        }
    }

    package enum Decision: Equatable, Sendable {
        case confident(personID: Int64, sampleID: Int64, score: Float)
        case unsure(personID: Int64?, score: Float, reason: VoiceLabelReason)
        case unknown(bestScore: Float)
        case tooShort

        /// Scores compare at 3 decimals so float noise never fails an equality.
        package static func == (a: Decision, b: Decision) -> Bool {
            func r(_ x: Float) -> Float { (x * 1000).rounded() }
            switch (a, b) {
            case let (.confident(p1, s1, x), .confident(p2, s2, y)): return p1 == p2 && s1 == s2 && r(x) == r(y)
            case let (.unsure(p1, x, q1), .unsure(p2, y, q2)): return p1 == p2 && q1 == q2 && r(x) == r(y)
            case let (.unknown(x), .unknown(y)): return r(x) == r(y)
            case (.tooShort, .tooShort): return true
            default: return false
            }
        }
    }

    package static func normalize(_ v: [Float]) -> [Float]? {
        guard !v.isEmpty else { return nil }
        let n = sqrt(v.reduce(Float(0)) { $0 + $1 * $1 })
        guard n > 0, n.isFinite else { return nil }
        return v.map { $0 / n }
    }

    package static func cosine(_ a: [Float], _ b: [Float]) -> Float? {
        guard a.count == b.count, !a.isEmpty, let na = normalize(a), let nb = normalize(b) else { return nil }
        return zip(na, nb).reduce(Float(0)) { $0 + $1.0 * $1.1 }
    }

    /// Best sample per person, highest first.
    package static func nearest(embedding: [Float], samples: [VoiceSample]) -> [(personID: Int64, sampleID: Int64, score: Float)] {
        var best: [Int64: (Int64, Float)] = [:]
        for s in samples {
            guard let sid = s.id, let score = cosine(embedding, s.vector) else { continue }
            if score > (best[s.personID]?.1 ?? -.infinity) { best[s.personID] = (sid, score) }
        }
        return best.map { (personID: $0.key, sampleID: $0.value.0, score: $0.value.1) }.sorted { $0.score > $1.score }
    }

    package static func decide(clusters: [Cluster], samples: [VoiceSample], invited: Set<Int64>?,
                               ownerPersonIDs: Set<Int64>) -> [String: Decision] {
        let usable = samples.filter { $0.modelVersion == VoiceRegistryPolicy.embeddingModelVersion }
        let active = usable.filter { $0.status == .active }
        let pending = usable.filter { $0.status == .pending }
        let threshold = invited == nil ? VoiceRegistryPolicy.confidentWithoutEvent : VoiceRegistryPolicy.confident
        var out: [String: Decision] = [:]
        var confidentByPerson: [Int64: (label: String, score: Float)] = [:]

        for c in clusters {
            guard c.speechSec >= VoiceRegistryPolicy.minClusterSpeechSec else { out[c.label] = .tooShort; continue }
            let ranked = nearest(embedding: c.embedding, samples: active)
            let top = ranked.first
            let second = ranked.dropFirst().first?.score ?? -1
            if let top, top.score >= threshold {
                if top.score - second < VoiceRegistryPolicy.margin {
                    out[c.label] = .unsure(personID: top.personID, score: top.score, reason: .conflict)
                } else if let invited, !invited.contains(top.personID), !ownerPersonIDs.contains(top.personID) {
                    out[c.label] = .unsure(personID: top.personID, score: top.score, reason: .unsure)
                } else {
                    out[c.label] = .confident(personID: top.personID, sampleID: top.sampleID, score: top.score)
                    if let prev = confidentByPerson[top.personID], prev.score >= top.score {
                        out[c.label] = .unsure(personID: top.personID, score: top.score, reason: .unsure)
                    } else {
                        if let prev = confidentByPerson[top.personID] {
                            out[prev.label] = .unsure(personID: top.personID, score: prev.score, reason: .unsure)
                        }
                        confidentByPerson[top.personID] = (c.label, top.score)
                    }
                }
                continue
            }
            if let p = nearest(embedding: c.embedding, samples: pending).first,
               p.score >= threshold, p.score > (top?.score ?? -1) {
                out[c.label] = .unsure(personID: p.personID, score: p.score, reason: .importConfirm)
                continue
            }
            if let top, top.score >= VoiceRegistryPolicy.unsureFloor {
                out[c.label] = .unsure(personID: top.personID, score: top.score, reason: .unsure)
            } else {
                out[c.label] = .unknown(bestScore: max(0, top?.score ?? 0))
            }
        }
        return out
    }
}
```

Update `TestDatabase+Schema.swift`: replace the `voice_prints` block (L902–909) with the four tables and indexes exactly as in `schema.sql` (Task 1 Step 4) and add `speaker_names_changed_at TEXT,` next to `speakers_json TEXT,` (L896).

- [ ] **Step 4: Run**

Run: `make test-swift FILTER='VoiceMatcherTests|SpeakerEmbeddingRegistryFieldsTests'`
Expected: the two new classes PASS. Desktop-target files that still reference `VoicePrint.embedding`/`sampleCount`/`embeddingVector` will not compile yet — that is expected and fixed in Task 4; do not commit until Task 4 compiles. (If the executor prefers a green commit per task, merge Tasks 3 and 4 into one commit.)

- [ ] **Step 5: Commit (together with Task 4)** — see Task 4 Step 6.

---

### Task 4: Registry queries; replace `VoicePrintMatcher` and `renameSpeaker`

**Files:**
- Rewrite: `WatchtowerDesktop/Sources/Database/Queries/VoicePrintQueries.swift`
- Create: `Sources/Database/Queries/VoiceSampleQueries.swift`, `VoiceLabelQueueQueries.swift`, `VoiceImportQueries.swift`
- Modify: `Sources/Database/Queries/MeetingTranscriptQueries.swift:130-200`
- Delete: `Sources/Services/Transcription/VoicePrintMatcher.swift`, `Tests/VoicePrintMatcherTests.swift`
- Modify tests: `Tests/MeetingTranscriptQueriesTests.swift:460-480`, `Tests/AppStateTests.swift:36-82`, `Tests/MeetingRecorderCenterTests.swift:1242`
- Test: `Tests/VoiceRegistryQueriesTests.swift`

**Interfaces:**
- Consumes: Task 3 models.
- Produces:
  - `VoicePrintQueries.fetchAll(_:) -> [VoicePrint]`, `fetch(_:personKey:) -> VoicePrint?`, `fetch(_:id:) -> VoicePrint?`, `findOrCreate(_:personKey:displayName:) -> VoicePrint` (never renames an existing person), `delete(_:id:)`, `isOwner(_ print: VoicePrint, ownerEmails: Set<String>) -> Bool`, `personIDs(_:matching attendees: [EventAttendee]) -> Set<Int64>` (email or case-insensitive display name).
  - `VoiceSampleQueries.fetchUsable(_:) -> [VoiceSample]` (status active|pending, current model), `insert(_:_ sample: inout VoiceSample)`, `anchors(_:personID:) -> [VoiceSample]`, `insertAuto(_:_ sample: VoiceSample) -> Int64` (retires oldest active auto beyond `autoCapPerChannel` for the same person+channel), `retire(_:id:)`, `activatePending(_:personID:importID:)`, `fetchByPerson(_:) -> [Int64: [VoiceSample]]`.
  - `VoiceLabelQueueQueries.enqueue(_:transcriptID:clusterLabel:reason:suggestedPersonID:score:)` (INSERT OR IGNORE on the open unique index), `pending(_:transcriptID: Int64?) -> [VoiceLabelTask]`, `pendingCount(_:) -> Int`, `close(_:id:status:)`, `skipTasksWithoutAudio(_:) -> Int`.
  - `VoiceImportQueries.fetchAll`, `delete(_:id:)`.
  - `MeetingTranscriptQueries.relabelCluster(_ db: Database, id: Int64, from: String, to: String, patch: (inout SpeakerEmbedding) -> Void) throws -> Bool` — rewrites segments/text/speakers_json in one UPDATE, applies `patch` to the cluster entry, sets `speaker_names_changed_at`; returns false (no write) when the row is missing, no utterance carries `from`, the name is empty, or `to` is reserved while `from` is a name. `renameSpeaker` is deleted.

- [ ] **Step 1: Write failing tests** (`Tests/VoiceRegistryQueriesTests.swift`, using the existing `TestDatabase` helper the other query tests use)

```swift
import XCTest
import GRDB
@testable import WatchtowerDesktop
@testable import WatchtowerCore

final class VoiceRegistryQueriesTests: XCTestCase {
    private func v(_ x: Float, _ y: Float) -> Data { VoicePrintEmbedding.encode([x, y]) }

    func testInsertAutoRetiresOldestBeyondCapPerChannel() throws {
        let db = try TestDatabase.make()
        try db.write { conn in
            let p = try VoicePrintQueries.findOrCreate(conn, personKey: "alice@example.com", displayName: "Alice")
            for i in 0..<(VoiceRegistryPolicy.autoCapPerChannel + 2) {
                _ = try VoiceSampleQueries.insertAuto(conn, VoiceSample(personID: p.id!, embedding: self.v(1, Float(i)),
                    modelVersion: VoiceRegistryPolicy.embeddingModelVersion, origin: .auto, anchor: false, status: .active, channel: .remote))
            }
            let active = try VoiceSample.filter(Column("person_id") == p.id! && Column("status") == "active").fetchAll(conn)
            XCTAssertEqual(active.count, VoiceRegistryPolicy.autoCapPerChannel)
            XCTAssertEqual(try VoiceSample.filter(Column("status") == "retired").fetchCount(conn), 2)
        }
    }

    func testFindOrCreateNeverRenamesExistingPerson() throws {
        let db = try TestDatabase.make()
        try db.write { conn in
            _ = try VoicePrintQueries.findOrCreate(conn, personKey: "alice@example.com", displayName: "Alice")
            let again = try VoicePrintQueries.findOrCreate(conn, personKey: "alice@example.com", displayName: "A. Imported")
            XCTAssertEqual(again.displayName, "Alice")
        }
    }

    func testEnqueueIsIdempotentWhileOpen() throws {
        let db = try TestDatabase.make()
        let tid = try db.insertTranscript(segmentsJSON: TestFixtures.twoSpeakerSegments) // existing helper or inline INSERT
        try db.write { conn in
            try VoiceLabelQueueQueries.enqueue(conn, transcriptID: tid, clusterLabel: "Speaker 1", reason: .unknown, suggestedPersonID: nil, score: nil)
            try VoiceLabelQueueQueries.enqueue(conn, transcriptID: tid, clusterLabel: "Speaker 1", reason: .unsure, suggestedPersonID: nil, score: 0.6)
            XCTAssertEqual(try VoiceLabelQueueQueries.pendingCount(conn), 1)
        }
    }

    func testRelabelClusterPatchesSpeakersJSONAndStampsChange() throws {
        let db = try TestDatabase.make()
        let tid = try db.insertTranscript(segmentsJSON: TestFixtures.twoSpeakerSegments,
                                          speakersJSON: #"[{"speaker":"Speaker 1","embedding":[1,0]}]"#)
        try db.write { conn in
            XCTAssertTrue(try MeetingTranscriptQueries.relabelCluster(conn, id: tid, from: "Speaker 1", to: "Alice") {
                $0.labelSource = .owner; $0.personID = 7; $0.originalLabel = $0.originalLabel ?? "Speaker 1"
            })
            let t = try XCTUnwrap(MeetingTranscriptQueries.fetch(conn, id: tid))
            let s = try XCTUnwrap(t.speakerEmbeddings?.first)
            XCTAssertEqual(s.speaker, "Alice"); XCTAssertEqual(s.labelSource, .owner); XCTAssertEqual(s.originalLabel, "Speaker 1")
            XCTAssertNotNil(try String.fetchOne(conn, sql: "SELECT speaker_names_changed_at FROM meeting_transcripts WHERE id = ?", arguments: [tid]))
            XCTAssertFalse(t.transcriptText.contains("Speaker 1:"))
        }
    }

    func testPersonIDsMatchByEmailOrDisplayName() throws {
        let db = try TestDatabase.make()
        try db.write { conn in
            let a = try VoicePrintQueries.findOrCreate(conn, personKey: "alice@example.com", displayName: "Alice")
            let b = try VoicePrintQueries.findOrCreate(conn, personKey: "colleague a", displayName: "Colleague A")
            let att = [EventAttendee(email: "ALICE@example.com", displayName: "", responseStatus: "accepted", slackUserID: ""),
                       EventAttendee(email: "", displayName: "colleague a", responseStatus: "accepted", slackUserID: "")]
            XCTAssertEqual(try VoicePrintQueries.personIDs(conn, matching: att), [a.id!, b.id!])
        }
    }
}
```

Adapt `TestDatabase.make()` / `insertTranscript` / `TestFixtures` to the helpers that already exist in `Tests/Support` (`grep -rn "static func make\|func insertTranscript\|twoSpeaker" WatchtowerDesktop/Tests/Support`); if no transcript-insert helper exists, write the INSERT inline in a private helper in this file. Use `EventAttendee`'s real memberwise initializer.

- [ ] **Step 2: Run to verify failure**

Run: `make test-swift FILTER=VoiceRegistryQueriesTests`
Expected: compile failure (new query types missing).

- [ ] **Step 3: Implement queries**

`VoicePrintQueries.swift`:

```swift
import Foundation
import GRDB
import WatchtowerCore

enum VoicePrintQueries {
    static func fetchAll(_ db: Database) throws -> [VoicePrint] { try VoicePrint.order(Column("person_key")).fetchAll(db) }
    static func fetch(_ db: Database, personKey: String) throws -> VoicePrint? {
        try VoicePrint.filter(Column("person_key") == personKey).fetchOne(db)
    }
    static func fetch(_ db: Database, id: Int64) throws -> VoicePrint? { try VoicePrint.fetchOne(db, key: id) }

    static func findOrCreate(_ db: Database, personKey: String, displayName: String) throws -> VoicePrint {
        let key = personKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let existing = try fetch(db, personKey: key) { return existing }
        var p = VoicePrint(personKey: key, displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines))
        try p.insert(db)
        return p
    }

    static func delete(_ db: Database, id: Int64) throws { _ = try VoicePrint.deleteOne(db, key: id) }

    static func isOwner(_ print: VoicePrint, ownerEmails: Set<String>) -> Bool {
        ownerEmails.contains { $0.lowercased() == print.personKey.lowercased() }
    }

    static func personIDs(_ db: Database, matching attendees: [EventAttendee]) throws -> Set<Int64> {
        let keys = Set(attendees.flatMap { [$0.email, $0.displayName] }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })
        return Set(try fetchAll(db).filter { keys.contains($0.personKey) || keys.contains($0.displayName.lowercased()) }
            .compactMap(\.id))
    }
}
```

`VoiceSampleQueries.swift`:

```swift
enum VoiceSampleQueries {
    static func fetchUsable(_ db: Database) throws -> [VoiceSample] {
        try VoiceSample.filter(["active", "pending"].contains(Column("status"))
            && Column("model_version") == VoiceRegistryPolicy.embeddingModelVersion).fetchAll(db)
    }
    static func anchors(_ db: Database, personID: Int64) throws -> [VoiceSample] {
        try VoiceSample.filter(Column("person_id") == personID && Column("anchor") == true && Column("status") == "active").fetchAll(db)
    }
    static func insert(_ db: Database, _ sample: inout VoiceSample) throws { try sample.insert(db) }

    @discardableResult
    static func insertAuto(_ db: Database, _ sample: VoiceSample) throws -> Int64 {
        precondition(sample.origin == .auto && !sample.anchor)
        var s = sample
        try s.insert(db)
        try db.execute(sql: """
            UPDATE voice_samples SET status = 'retired'
            WHERE id IN (
              SELECT id FROM voice_samples
              WHERE person_id = ? AND channel = ? AND origin = 'auto' AND status = 'active'
              ORDER BY created_at DESC, id DESC LIMIT -1 OFFSET ?)
            """, arguments: [s.personID, s.channel.rawValue, VoiceRegistryPolicy.autoCapPerChannel])
        return s.id!
    }
    static func retire(_ db: Database, id: Int64) throws {
        try db.execute(sql: "UPDATE voice_samples SET status = 'retired' WHERE id = ?", arguments: [id])
    }
    static func activatePending(_ db: Database, personID: Int64, importID: Int64?) throws {
        try db.execute(sql: """
            UPDATE voice_samples SET status = 'active'
            WHERE person_id = ? AND status = 'pending' AND origin = 'imported' AND (? IS NULL OR import_id = ?)
            """, arguments: [personID, importID, importID])
    }
    static func fetchByPerson(_ db: Database) throws -> [Int64: [VoiceSample]] {
        Dictionary(grouping: try VoiceSample.fetchAll(db), by: \.personID)
    }
}
```

`VoiceLabelQueueQueries.swift`:

```swift
enum VoiceLabelQueueQueries {
    static func enqueue(_ db: Database, transcriptID: Int64, clusterLabel: String, reason: VoiceLabelReason,
                        suggestedPersonID: Int64?, score: Float?) throws {
        try db.execute(sql: """
            INSERT OR IGNORE INTO voice_label_queue (transcript_id, cluster_label, reason, suggested_person_id, score)
            VALUES (?, ?, ?, ?, ?)
            """, arguments: [transcriptID, clusterLabel, reason.rawValue, suggestedPersonID, score])
    }
    static func pending(_ db: Database, transcriptID: Int64? = nil) throws -> [VoiceLabelTask] {
        var q = VoiceLabelTask.filter(Column("status") == "pending")
        if let transcriptID { q = q.filter(Column("transcript_id") == transcriptID) }
        return try q.order(Column("created_at").desc, Column("id")).fetchAll(db)
    }
    static func pendingCount(_ db: Database) throws -> Int {
        try VoiceLabelTask.filter(Column("status") == "pending").fetchCount(db)
    }
    static func close(_ db: Database, id: Int64, status: VoiceLabelTaskStatus) throws {
        try db.execute(sql: "UPDATE voice_label_queue SET status = ?, resolved_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ?",
                       arguments: [status.rawValue, id])
    }
    /// Spec §3.1: tasks whose recording lost its audio become `skipped` — never an audio-less card.
    static func skipTasksWithoutAudio(_ db: Database, audioExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) throws -> Int {
        let rows = try Row.fetchAll(db, sql: """
            SELECT q.id, t.audio_path FROM voice_label_queue q JOIN meeting_transcripts t ON t.id = q.transcript_id
            WHERE q.status = 'pending'
            """)
        var n = 0
        for r in rows where !audioExists((r["audio_path"] as String?) ?? "") {
            try close(db, id: r["id"], status: .skipped); n += 1
        }
        return n
    }
}
```

`VoiceImportQueries.swift`: `fetchAll(_:) -> [VoiceImport]` ordered by `imported_at DESC`, `delete(_:id:)` (`VoiceImport.deleteOne`; samples cascade).

`MeetingTranscriptQueries.relabelCluster` — replace `renameSpeaker` (keep its doc comment's invariants, drop the voice-print upsert):

```swift
@discardableResult
static func relabelCluster(_ db: Database, id: Int64, from: String, to newLabel: String,
                           patch: (inout SpeakerEmbedding) -> Void = { _ in }) throws -> Bool {
    let target = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !target.isEmpty,
          !(SpeakerNaming.isReserved(target) && !SpeakerNaming.isUnnamed(target)),   // «Я» never assignable here
          let transcript = try fetch(db, id: id),
          let segmentsJSON = transcript.segmentsJSON,
          var utterances = TranscriptSegments.decode(segmentsJSON),
          utterances.contains(where: { $0.speaker == from }) else { return false }
    for i in utterances.indices where utterances[i].speaker == from {
        let u = utterances[i]
        utterances[i] = TranscriptUtterance(idx: u.idx, startSec: u.startSec, endSec: u.endSec, speaker: target, text: u.text, deleted: u.deleted)
    }
    guard let updatedJSON = TranscriptSegments.encode(utterances) else { return false }
    var speakersJSON = transcript.speakersJSON
    if let json = transcript.speakersJSON, var speakers = SpeakerEmbeddings.decode(json) {
        for i in speakers.indices where speakers[i].speaker == from {
            if speakers[i].originalLabel == nil { speakers[i].originalLabel = from }
            speakers[i].speaker = target
            patch(&speakers[i])
        }
        guard let re = SpeakerEmbeddings.encode(speakers) else { throw MeetingTranscriptQueryError.speakerEncodeFailed }
        speakersJSON = re
    }
    try db.execute(sql: """
        UPDATE meeting_transcripts
        SET segments_json = ?, transcript_text = ?, speakers_json = ?,
            speaker_names_changed_at = strftime('%Y-%m-%dT%H:%M:%SZ','now'),
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
        WHERE id = ?
        """, arguments: [updatedJSON, TranscriptSegments.render(utterances), speakersJSON, id])
    return true
}
```

Also add `speakerNamesChangedAt: String?` (`speaker_names_changed_at`) to `MeetingTranscript` in WatchtowerCore (CodingKeys + init) and to its full-row fetch projection only (never to `fetchRecordingList`).

Delete `VoicePrintMatcher.swift` and `VoicePrintMatcherTests.swift`. Port the still-relevant assertions: `normalize`/`cosine` degenerate-vector cases → add to `VoiceMatcherTests` (Task 3 file) as `testDegenerateVectorsNeverMatch`. Update `MeetingTranscriptQueriesTests` rename tests to `relabelCluster` (the "reserved name rejected" and "stale from returns false" cases stay; the voice-print upsert assertions at L469–473 are removed). Keep `RecordingDetailView.renameSpeaker` compiling by calling `relabelCluster` with `labelSource = .owner` (Task 12 removes it).

**Commit unit:** deleting `VoicePrintMatcher` breaks `MeetingRecorderCenter.matchVoiceNames` until Task 7 replaces it, and stubbing it out would regress behavior inside a commit. Tasks 3, 4, 5 and 7 are therefore implemented in that order and committed once, at the end of Task 7. Tasks 3–5 run their own test filters as they go; the build is expected to be red between them.

- [ ] **Step 4: Run**

Run: `make test-swift FILTER='VoiceRegistryQueriesTests|VoiceMatcherTests|MeetingTranscriptQueriesTests|SpeakerEmbeddingRegistryFieldsTests'`
Expected: PASS once Tasks 5 and 7 compile.

- [ ] **Step 5: Commit** — after Task 7 (single commit "feat(desktop): voice registry core — samples, matcher, queries, pipeline").

---

### Task 5: Cluster features — channel, clean speech, clip spans

**Files:**
- Create: `WatchtowerDesktop/Sources/Services/Transcription/ClusterFeatures.swift`
- Test: `WatchtowerDesktop/Tests/ClusterFeaturesTests.swift`

**Interfaces:**
- Consumes: `SpeakerSegment { speakerID, startSec, endSec, embedding }`, `MicActivity`, `ClipSpan`, `VoiceChannel`, `VoiceRegistryPolicy`.
- Produces: `struct ClusterFeatures: Equatable { let speechSec: Double; let channel: VoiceChannel; let clips: [ClipSpan] }` and `static func compute(speakers: [SpeakerSegment], activity: MicActivity?) -> [String: ClusterFeatures]` (keyed by `speakerID`).

- [ ] **Step 1: Failing test**

```swift
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

final class ClusterFeaturesTests: XCTestCase {
    private func seg(_ id: String, _ a: Double, _ b: Double) -> SpeakerSegment {
        SpeakerSegment(speakerID: id, startSec: a, endSec: b, embedding: nil)
    }
    private func activity(seconds: Int, mic: Float, sys: Float) -> MicActivity {
        MicActivity(bins: Array(repeating: .init(mic: mic, sys: sys), count: seconds * 10))
    }

    func testSpeechAndClipsPickLongestTrimmedSegments() {
        let f = ClusterFeatures.compute(speakers: [seg("A", 0, 3), seg("A", 10, 30), seg("A", 40, 46), seg("A", 50, 55)], activity: nil)["A"]!
        XCTAssertEqual(f.speechSec, 3 + 20 + 6 + 5, accuracy: 0.01)
        XCTAssertEqual(f.clips.count, 3)
        XCTAssertEqual(f.clips.first, ClipSpan(start: 10.3, end: 20.3))            // trimmed 0.3 s, capped at 10 s
        XCTAssertFalse(f.clips.contains { $0.end - $0.start < VoiceRegistryPolicy.clipMinSec })
        XCTAssertEqual(f.channel, .unknown)
    }

    func testChannelFromActivity() {
        XCTAssertEqual(ClusterFeatures.compute(speakers: [seg("A", 0, 30)], activity: activity(seconds: 30, mic: 0.001, sys: 0.05))["A"]!.channel, .remote)
        XCTAssertEqual(ClusterFeatures.compute(speakers: [seg("A", 0, 30)], activity: activity(seconds: 30, mic: 0.05, sys: 0.0))["A"]!.channel, .room)
    }
}
```

Use `MicActivity`'s real initializer (`MicActivity(bins:)` is the synthesized memberwise init of `let bins`; add a `package`/`internal` init only if the struct hides it).

- [ ] **Step 2: Run** — `make test-swift FILTER=ClusterFeaturesTests` → compile failure.

- [ ] **Step 3: Implement**

```swift
import Foundation
import WatchtowerCore

/// Per-cluster registry features derived from diarization + the mic/system
/// activity sidecar (spec §2.1). Pure.
struct ClusterFeatures: Equatable {
    let speechSec: Double
    let channel: VoiceChannel
    let clips: [ClipSpan]

    static let edgeTrimSec = 0.3
    /// Share of the cluster's active bins that must be system-dominant (or mic-dominant) to call the channel.
    static let channelShare = 0.6

    static func compute(speakers: [SpeakerSegment], activity: MicActivity?) -> [String: ClusterFeatures] {
        Dictionary(grouping: speakers, by: \.speakerID).mapValues { segs in
            let speech = segs.reduce(0) { $0 + max(0, $1.endSec - $1.startSec) }
            let clips = segs
                .map { (a: $0.startSec + edgeTrimSec, b: $0.endSec - edgeTrimSec) }
                .filter { $0.b - $0.a >= VoiceRegistryPolicy.clipMinSec }
                .sorted { ($0.b - $0.a) > ($1.b - $1.a) }
                .prefix(VoiceRegistryPolicy.clipsPerCluster)
                .map { ClipSpan(start: $0.a, end: min($0.b, $0.a + VoiceRegistryPolicy.clipMaxSec)) }
            return ClusterFeatures(speechSec: speech, channel: channel(segs, activity), clips: Array(clips))
        }
    }

    private static func channel(_ segs: [SpeakerSegment], _ activity: MicActivity?) -> VoiceChannel {
        guard let activity else { return .unknown }
        var mic = 0, sys = 0
        for s in segs {
            var t = s.startSec
            while t < s.endSec {
                if let b = activity.bin(at: t) {
                    if b.mic > RoleAssigner.micDominanceFactor * b.sys { mic += 1 }
                    else if b.sys > RoleAssigner.micDominanceFactor * b.mic { sys += 1 }
                }
                t += MicActivity.binDuration
            }
        }
        let total = mic + sys
        guard total > 0 else { return .unknown }
        if Double(sys) / Double(total) >= channelShare { return .remote }
        if Double(mic) / Double(total) >= channelShare { return .room }
        return .unknown
    }
}
```

- [ ] **Step 4: Run** — `make test-swift FILTER=ClusterFeaturesTests` → PASS.
- [ ] **Step 5:** commit together with Task 7.

---

### Task 6: Self-training rule

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/VoiceRegistry/VoiceLearning.swift`
- Test: `WatchtowerDesktop/Tests/Core/VoiceLearningTests.swift`

**Interfaces:**
- Produces: `VoiceLearning.shouldLearn(decision: VoiceMatcher.Decision, runnerUp: Float, embedding: [Float], speechSec: Double, anchors: [VoiceSample]) -> Bool`.

- [ ] **Step 1: Failing test**

```swift
import XCTest
@testable import WatchtowerCore

final class VoiceLearningTests: XCTestCase {
    private let anchor = VoiceSample(id: 1, personID: 1, embedding: VoicePrintEmbedding.encode([1, 0]),
                                     modelVersion: VoiceRegistryPolicy.embeddingModelVersion, origin: .owner, anchor: true, status: .active)
    func testLearnsOnlyWhenStrongLongAndAnchored() {
        let strong = VoiceMatcher.Decision.confident(personID: 1, sampleID: 1, score: 0.85)
        XCTAssertTrue(VoiceLearning.shouldLearn(decision: strong, runnerUp: 0.4, embedding: [1, 0.1], speechSec: 40, anchors: [anchor]))
        XCTAssertFalse(VoiceLearning.shouldLearn(decision: strong, runnerUp: 0.4, embedding: [1, 0.1], speechSec: 29, anchors: [anchor]))
        XCTAssertFalse(VoiceLearning.shouldLearn(decision: strong, runnerUp: 0.8, embedding: [1, 0.1], speechSec: 40, anchors: [anchor]))
        XCTAssertFalse(VoiceLearning.shouldLearn(decision: strong, runnerUp: 0.4, embedding: [1, 0.1], speechSec: 40, anchors: []))
        XCTAssertFalse(VoiceLearning.shouldLearn(decision: .confident(personID: 1, sampleID: 1, score: 0.75),
                                                 runnerUp: 0.2, embedding: [1, 0.1], speechSec: 40, anchors: [anchor]))
        XCTAssertFalse(VoiceLearning.shouldLearn(decision: strong, runnerUp: 0.2, embedding: [0, 1], speechSec: 40, anchors: [anchor])) // drifted from anchor
    }
}
```

- [ ] **Step 2: Run** — `make test-swift FILTER=VoiceLearningTests` → FAIL.
- [ ] **Step 3: Implement**

```swift
/// Spec §2.4 + invariant 1: self-train only from strong, long, anchor-consistent matches.
package enum VoiceLearning {
    package static func shouldLearn(decision: VoiceMatcher.Decision, runnerUp: Float, embedding: [Float],
                                    speechSec: Double, anchors: [VoiceSample]) -> Bool {
        guard case let .confident(personID, _, score) = decision,
              score >= VoiceRegistryPolicy.learn,
              score - runnerUp >= VoiceRegistryPolicy.margin,
              speechSec >= VoiceRegistryPolicy.learnMinSpeechSec else { return false }
        return anchors.contains { $0.personID == personID && $0.anchor && $0.status == .active
            && (VoiceMatcher.cosine(embedding, $0.vector) ?? -1) >= VoiceRegistryPolicy.learnAnchorFloor }
    }
}
```

- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/Sources/WatchtowerCore/Services/VoiceRegistry/VoiceLearning.swift WatchtowerDesktop/Tests/Core/VoiceLearningTests.swift
git commit -m "feat(core): voice self-training rule anchored to owner samples"
```

---

### Task 7: Pipeline integration in `MeetingRecorderCenter`

**Files:**
- Modify: `WatchtowerDesktop/Sources/Services/MeetingRecorderCenter.swift:158-180,681-830,1419-1519`
- Modify: `WatchtowerDesktop/Sources/App/AppState.swift:388-430`
- Modify: `WatchtowerDesktop/Sources/Services/Transcription/TranscriptionEngine.swift:31-125` (add `voiceRecognition`)
- Modify: `WatchtowerDesktop/Sources/Services/NotificationService.swift:200-260`
- Test: `WatchtowerDesktop/Tests/MeetingRecorderVoiceRegistryTests.swift`; update `Tests/MeetingRecorderCenterTests.swift:1242`, `Tests/AppStateTests.swift:36-82`

**Interfaces:**
- Consumes: `VoiceMatcher.decide`, `VoiceLearning.shouldLearn`, `ClusterFeatures.compute`, queries from Task 4.
- Produces:
  - Center loaders replace `voicePrintsLoader`: `var registryLoader: (@Sendable (_ eventID: String?) async -> VoiceRegistrySnapshot)?` where `struct VoiceRegistrySnapshot: Sendable { samples: [VoiceSample]; people: [Int64: VoicePrint]; invited: Set<Int64>?; ownerPersonIDs: Set<Int64> }`.
  - `var registryWriter: (@Sendable (_ transcriptID: Int64, _ outcome: VoiceIdentificationOutcome) async -> Int)?` — persists queue tasks + auto samples after save, returns the number of enqueued tasks.
  - `struct VoiceIdentificationOutcome: Sendable { let tasks: [(label: String, reason: VoiceLabelReason, personID: Int64?, score: Float?)]; let autoSamples: [VoiceSample] }` (transcriptID filled by the writer).
  - `TranscriptionConfig.voiceRecognition: Bool` (`transcription.voiceRecognition`, absent = true), `voiceNotifications: Bool` (`transcription.voiceNotifications`, absent = true).
  - `NotificationService.sendVoicesToLabelNotification(title: String, count: Int, transcriptID: Int64)`: `userInfo = ["type": "voice_label", "transcriptID": transcriptID]`, identifier `"voice-label-\(transcriptID)"`; `MeetingTranscriptNotifying` gains it.

- [ ] **Step 1: Failing tests** (extend the existing `MeetingRecorderTestCase` harness used by `MeetingRecorderCenterTests`, with a fake diarizer returning fixed `SpeakerSegment`s — reuse the fake at the L1242 area)

```swift
final class MeetingRecorderVoiceRegistryTests: MeetingRecorderTestCase {
    func testConfidentClusterIsNamedAndUnknownIsQueuedAfterSave() async throws {
        let alice = VoicePrint(id: 1, personKey: "alice@example.com", displayName: "Alice")
        let sample = VoiceSample(id: 10, personID: 1, embedding: VoicePrintEmbedding.encode([1, 0]),
                                 modelVersion: VoiceRegistryPolicy.embeddingModelVersion, origin: .owner, anchor: true, status: .active)
        let center = makeCenter(diarization: [
            SpeakerSegment(speakerID: "A", startSec: 0, endSec: 40, embedding: [1, 0]),
            SpeakerSegment(speakerID: "B", startSec: 40, endSec: 80, embedding: [0, 1])])
        center.registryLoader = { _ in VoiceRegistrySnapshot(samples: [sample], people: [1: alice], invited: [1], ownerPersonIDs: []) }
        var written: VoiceIdentificationOutcome?
        center.registryWriter = { _, outcome in written = outcome; return outcome.tasks.count }

        let saved = try await runOneRecording(center)                 // helper from MeetingRecorderTestCase
        XCTAssertTrue(saved.transcriptText.contains("Alice"))
        let speakers = try XCTUnwrap(SpeakerEmbeddings.decode(saved.speakersJSONArgument))
        let a = try XCTUnwrap(speakers.first { $0.speaker == "Alice" })
        XCTAssertEqual(a.labelSource, .auto); XCTAssertEqual(a.personID, 1); XCTAssertEqual(a.matchedSampleID, 10)
        XCTAssertEqual(a.originalLabel?.hasPrefix("Speaker"), true)
        XCTAssertEqual(written?.tasks.map(\.reason), [.unknown])
        XCTAssertEqual(notifier.voiceLabelNotifications.count, 1)
    }

    func testOwnerClusterIsNeverRenamedByTheRegistry() async throws {
        // mic-dominant cluster A → «Я» by RoleAssigner; the registry matches A to Alice confidently
        let center = makeCenter(diarization: [SpeakerSegment(speakerID: "A", startSec: 0, endSec: 40, embedding: [1, 0])],
                                activity: .micDominant(seconds: 40))
        center.registryLoader = { _ in .init(samples: [self.aliceSample], people: [1: self.alice], invited: [1], ownerPersonIDs: []) }
        let saved = try await runOneRecording(center)
        XCTAssertTrue(saved.transcriptText.contains("Я"))
        XCTAssertFalse(saved.transcriptText.contains("Alice"))
    }

    func testRegistryFailureStillSavesPlainLabels() async throws {
        let center = makeCenter(diarization: [SpeakerSegment(speakerID: "A", startSec: 0, endSec: 40, embedding: [1, 0])])
        center.registryLoader = nil      // unwired loader = registry off
        let saved = try await runOneRecording(center)
        XCTAssertTrue(saved.transcriptText.contains("Speaker 1"))
    }

    func testVoiceRecognitionOffSkipsRegistry() async throws {
        defaults.set(false, forKey: "transcription.voiceRecognition")
        var loaded = false
        let center = makeCenter(diarization: [SpeakerSegment(speakerID: "A", startSec: 0, endSec: 40, embedding: [1, 0])])
        center.registryLoader = { _ in loaded = true; return .init(samples: [], people: [:], invited: nil, ownerPersonIDs: []) }
        _ = try await runOneRecording(center)
        XCTAssertFalse(loaded)
    }
}
```

`makeCenter`, `runOneRecording`, `notifier`, `defaults`, `.micDominant` are harness helpers: add the missing ones to `MeetingRecorderTestCase` (Tests/Support or the existing test base file) by extracting from the existing diarization tests; the fake notifier records `sendVoicesToLabelNotification` calls in `voiceLabelNotifications`. `saved.speakersJSONArgument` = the speakers file content captured by the fake CLI runner the save tests already use.

- [ ] **Step 2: Run** — `make test-swift FILTER=MeetingRecorderVoiceRegistryTests` → compile failure.

- [ ] **Step 3: Implement**

1. `TranscriptionConfig`: add `var voiceRecognition = true`, `var voiceNotifications = true`; in `fromDefaults` read both keys only when present (the L119–121 pattern).
2. Center: delete `voicePrintsLoader` and `ownerEmailsLoader`; keep `attendeesLoader` (still used by nothing else? — `grep`; delete if unused). Add `registryLoader`, `registryWriter`, `VoiceRegistrySnapshot`, `VoiceIdentificationOutcome`. Replace `matchVoiceNames(clusterEmbeddings:eventID:)` with:

```swift
/// Registry identification (spec §2): returns RoleAssigner inputs plus the
/// per-cluster registry payload and what to persist after save.
private func identifyVoices(clusterEmbeddings: [String: [Float]], features: [String: ClusterFeatures],
                            eventID: String?, config: TranscriptionConfig) async
    -> (names: [String: String], ownerClusters: Set<String>?, ownerVoiceAlike: Set<String>,
        decisions: [String: VoiceMatcher.Decision], snapshot: VoiceRegistrySnapshot?) {
    guard config.voiceRecognition, let loader = registryLoader else { return ([:], nil, [], [:], nil) }
    let snap = await loader(eventID)
    let clusters = clusterEmbeddings.map { VoiceMatcher.Cluster(label: $0.key, embedding: $0.value,
                                                                  speechSec: features[$0.key]?.speechSec ?? 0) }
    let decisions = VoiceMatcher.decide(clusters: clusters, samples: snap.samples, invited: snap.invited,
                                        ownerPersonIDs: snap.ownerPersonIDs)
    var names: [String: String] = [:], owners: Set<String> = [], alike: Set<String> = []
    for (cluster, d) in decisions {
        if case let .confident(pid, _, _) = d, let person = snap.people[pid] {
            names[cluster] = person.displayName
            if snap.ownerPersonIDs.contains(pid) { owners.insert(cluster) }
        }
        // ownerVoiceAlike: any owner sample ≥ confident even if someone else won (conservative mixed-print rule)
        let ownerSamples = snap.samples.filter { snap.ownerPersonIDs.contains($0.personID) && $0.status == .active }
        if let e = clusterEmbeddings[cluster],
           (VoiceMatcher.nearest(embedding: e, samples: ownerSamples).first?.score ?? -1) >= VoiceRegistryPolicy.confident {
            alike.insert(cluster)
        }
    }
    let ownerArmed = snap.samples.contains { snap.ownerPersonIDs.contains($0.personID) && $0.status == .active && $0.anchor }
    return (names, ownerArmed ? owners : nil, alike, decisions, snap)
}
```

3. In `renderRoles`: compute `let features = ClusterFeatures.compute(speakers: speakers, activity: activity)` right after loading `activity`; call `identifyVoices`; pass `names/owners/alike` to `filterMegaClusters`/`detectSelf`/`assign` exactly as before. When building `speakerEmbeddings`, enrich each entry:

```swift
var entry = SpeakerEmbedding(speaker: label, embedding: embedding)
entry.originalLabel = unnamedLabels[cluster]          // "Speaker N" the cluster would have had without a voice name
entry.speechSec = features[cluster]?.speechSec
entry.channel = features[cluster]?.channel
entry.clips = features[cluster]?.clips
entry.modelVersion = VoiceRegistryPolicy.embeddingModelVersion
if case let .confident(pid, sid, score) = decisions[cluster], label == names[cluster] {
    entry.labelSource = .auto; entry.personID = pid; entry.matchedSampleID = sid; entry.score = score
} else {
    entry.labelSource = SpeakerNaming.isUnnamed(label) ? VoiceLabelSource.none : .owner   // «Я» = role pass
}
```

`unnamedLabels` = `RoleAssigner.clusterLabels(speakers:activity:voiceNames: [:], ...)` computed once with empty voice names, so `originalLabel` is the stable `Speaker N`.
Extend `renderRoles`' return tuple with `registry: VoiceIdentificationOutcome?` built from decisions: tasks for `.unsure(pid, score, reason)` → `(label, reason, pid, score)` and `.unknown` → `(label, .unknown, nil, bestScore)`, **skipping clusters whose final label is «Я»** and clusters with empty `clips`; `autoSamples` for confident clusters where `VoiceLearning.shouldLearn(decision:runnerUp:embedding:speechSec:anchors:)` is true (runnerUp = second entry of `VoiceMatcher.nearest` over active samples; anchors = `snap.samples.filter(\.anchor)`), each `VoiceSample(personID:, embedding: VoicePrintEmbedding.encode(normalized), modelVersion:, origin: .auto, anchor: false, status: .active, clusterLabel: label, channel:, score:, speechSec:)`. Carry it through `renderAndSave` → `save`.
4. In `save`, after `TranscriptSaveService.save` returns the transcript id (read it from `TranscriptSaveResult`; add the field if the result lacks it — the envelope already carries `id`), call `let queued = await registryWriter?(id, outcome) ?? 0`; if `queued > 0 && config.voiceNotifications`, call `notifier.sendVoicesToLabelNotification(title:count:transcriptID:)`. Any error inside the writer is logged and ignored (spec §2.6).
5. `NotificationService.sendVoicesToLabelNotification` as specified; add it to `MeetingTranscriptNotifying`.
6. `AppState.wireMeetingRecorderLoaders`: replace the voice-print and owner-email loaders with:

```swift
meetingRecorder.registryLoader = { eventID in
    (try? await dbPool.read { db -> VoiceRegistrySnapshot in
        let people = Dictionary(uniqueKeysWithValues: try VoicePrintQueries.fetchAll(db).compactMap { p in p.id.map { ($0, p) } })
        let ownerEmails = Set(try GoogleAccountQueries.fetchAll(db).map { $0.email.lowercased() }.filter { !$0.isEmpty })
        let owners = Set(people.values.filter { VoicePrintQueries.isOwner($0, ownerEmails: ownerEmails) }.compactMap(\.id))
        var invited: Set<Int64>?
        if let eventID, let event = try CalendarQueries.fetchEvent(db, id: eventID) {
            invited = try VoicePrintQueries.personIDs(db, matching: event.attendeesIncludingOrganizer)
        }
        return VoiceRegistrySnapshot(samples: try VoiceSampleQueries.fetchUsable(db), people: people,
                                     invited: invited, ownerPersonIDs: owners)
    }) ?? VoiceRegistrySnapshot(samples: [], people: [:], invited: nil, ownerPersonIDs: [])
}
meetingRecorder.registryWriter = { transcriptID, outcome in
    (try? await dbPool.write { db -> Int in
        for s in outcome.autoSamples { var s = s; s.transcriptID = transcriptID; try VoiceSampleQueries.insertAuto(db, s) }
        for t in outcome.tasks {
            try VoiceLabelQueueQueries.enqueue(db, transcriptID: transcriptID, clusterLabel: t.label, reason: t.reason,
                                               suggestedPersonID: t.personID, score: t.score)
        }
        return outcome.tasks.count
    }) ?? 0
}
```

Keep the existing "event missing → log once" behavior. Update `AppStateTests` (L36–82) to assert the new loaders are wired, and `MeetingRecorderCenterTests` L1242 to set `registryLoader`.

- [ ] **Step 4: Run**

Run: `make test-swift FILTER='MeetingRecorderVoiceRegistryTests|MeetingRecorderCenterTests|AppStateTests|RoleAssignerTests|VoiceRegistryQueriesTests|VoiceMatcherTests|ClusterFeaturesTests|MeetingTranscriptQueriesTests'`
Expected: PASS.

- [ ] **Step 5: Commit** (Tasks 3, 4, 5, 7 together)

```bash
git add -A WatchtowerDesktop
git commit -m "feat(desktop): voice registry core — samples, matcher, queries, pipeline

Replaces the single-centroid VoicePrintMatcher and renameSpeaker with
per-sample nearest matching, bands, a label queue and self-training.
Tasks 3/4/5/7 of the plan land together to keep every commit building."
```

---

### Task 8: Labeling transactions — confirm, don't know, several people, skip

**Files:**
- Create: `WatchtowerDesktop/Sources/Database/Queries/VoiceLabelingQueries.swift`
- Test: `WatchtowerDesktop/Tests/VoiceLabelingQueriesTests.swift`

**Interfaces:**
- Consumes: Task 4 queries, `relabelCluster`.
- Produces:
  - `enum VoiceLabelingResult: Equatable { case labeled(personID: Int64), alreadyLabeled, stale }`
  - `VoiceLabelingQueries.confirm(_ db: Database, taskID: Int64?, transcriptID: Int64, clusterLabel: String, personKey: String, displayName: String) throws -> VoiceLabelingResult`
  - `VoiceLabelingQueries.dismiss(_ db: Database, taskID: Int64, kind: DismissKind)` where `enum DismissKind { case dontKnow, severalPeople, skip }` — `dontKnow`/`severalPeople` close the task `done` and mark the cluster `labelSource = .owner` keeping its `Speaker N` label (retro and future queues leave it alone); `severalPeople` additionally sets a `mixed` flag: store it as `labelSource = .owner` + `personID = nil` + `score = -1` sentinel? — no: add `package var mixed: Bool?` (`"mixed"`) to `SpeakerEmbedding` in this task and set it; `skip` leaves the task pending and only updates nothing (the UI moves on).

- [ ] **Step 1: Failing tests**

```swift
final class VoiceLabelingQueriesTests: XCTestCase {
    func testConfirmRelabelsAddsAnchorAndClosesTask() throws {
        let db = try TestDatabase.make()
        let tid = try db.insertTranscript(segmentsJSON: TestFixtures.twoSpeakerSegments,
                                          speakersJSON: #"[{"speaker":"Speaker 1","embedding":[1,0],"channel":"remote","speech_sec":40}]"#)
        try db.write { conn in
            try VoiceLabelQueueQueries.enqueue(conn, transcriptID: tid, clusterLabel: "Speaker 1", reason: .unknown, suggestedPersonID: nil, score: nil)
            let task = try XCTUnwrap(VoiceLabelQueueQueries.pending(conn).first)
            let r = try VoiceLabelingQueries.confirm(conn, taskID: task.id, transcriptID: tid, clusterLabel: "Speaker 1",
                                                     personKey: "alice@example.com", displayName: "Alice")
            guard case let .labeled(pid) = r else { return XCTFail("\(r)") }
            let anchors = try VoiceSampleQueries.anchors(conn, personID: pid)
            XCTAssertEqual(anchors.count, 1); XCTAssertEqual(anchors[0].channel, .remote); XCTAssertEqual(anchors[0].transcriptID, tid)
            XCTAssertEqual(try VoiceLabelQueueQueries.pendingCount(conn), 0)
            let s = try XCTUnwrap(MeetingTranscriptQueries.fetch(conn, id: tid)?.speakerEmbeddings?.first)
            XCTAssertEqual(s.speaker, "Alice"); XCTAssertEqual(s.labelSource, .owner); XCTAssertEqual(s.personID, pid)
        }
    }

    func testConfirmOnStaleTaskReportsAlreadyLabeledWithoutWriting() throws {
        let db = try TestDatabase.make()
        let tid = try db.insertTranscript(segmentsJSON: TestFixtures.twoSpeakerSegments,
                                          speakersJSON: #"[{"speaker":"Speaker 1","embedding":[1,0]}]"#)
        try db.write { conn in
            try VoiceLabelQueueQueries.enqueue(conn, transcriptID: tid, clusterLabel: "Speaker 1", reason: .unknown, suggestedPersonID: nil, score: nil)
            _ = try MeetingTranscriptQueries.relabelCluster(conn, id: tid, from: "Speaker 1", to: "Bob") { $0.labelSource = .auto }
            let task = try XCTUnwrap(VoiceLabelQueueQueries.pending(conn).first)
            XCTAssertEqual(try VoiceLabelingQueries.confirm(conn, taskID: task.id, transcriptID: tid, clusterLabel: "Speaker 1",
                                                            personKey: "alice@example.com", displayName: "Alice"), .alreadyLabeled)
            XCTAssertEqual(try VoicePrint.fetchCount(conn), 0)
            XCTAssertEqual(try VoiceLabelQueueQueries.pendingCount(conn), 0)
        }
    }

    func testImportConfirmActivatesPendingSamplesOfThatPerson() throws { /* enqueue reason .importConfirm with a pending imported sample
        for Alice (insert a voice_imports row + VoiceSample(status: .pending, origin: .imported, importID:)); confirm → that sample is active */ }

    func testOwnerCannotBeAssignedAsReservedLabel() throws { /* confirm with displayName "Я" → .stale, nothing written */ }

    func testSeveralPeopleMarksClusterMixedAndNeverLearns() throws { /* dismiss .severalPeople → speakers_json mixed == true,
        labelSource .owner, no voice_samples rows, task done */ }
}
```

Write the three commented tests fully in the same style (each ≤ 15 lines); they are listed compactly here only to keep the plan readable — the executor must not leave them as comments.

- [ ] **Step 2: Run** — `make test-swift FILTER=VoiceLabelingQueriesTests` → compile failure.
- [ ] **Step 3: Implement**

```swift
import Foundation
import GRDB
import WatchtowerCore

enum VoiceLabelingResult: Equatable { case labeled(personID: Int64), alreadyLabeled, stale }
enum DismissKind { case dontKnow, severalPeople, skip }

enum VoiceLabelingQueries {
    /// Spec §3.1 Confirm — one transaction (the caller's write block).
    static func confirm(_ db: Database, taskID: Int64?, transcriptID: Int64, clusterLabel: String,
                        personKey: String, displayName: String) throws -> VoiceLabelingResult {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !SpeakerNaming.isReserved(name) else { return .stale }
        guard let t = try MeetingTranscriptQueries.fetch(db, id: transcriptID),
              let cluster = t.speakerEmbeddings?.first(where: { $0.speaker == clusterLabel || $0.originalLabel == clusterLabel })
        else { if let taskID { try VoiceLabelQueueQueries.close(db, id: taskID, status: .skipped) }; return .stale }
        // Stale: the task was for an unnamed cluster that has since been named by someone else.
        if cluster.speaker != clusterLabel {
            if let taskID { try VoiceLabelQueueQueries.close(db, id: taskID, status: .done) }
            return .alreadyLabeled
        }
        let person = try VoicePrintQueries.findOrCreate(db, personKey: personKey, displayName: name)
        guard let pid = person.id,
              try MeetingTranscriptQueries.relabelCluster(db, id: transcriptID, from: clusterLabel, to: person.displayName, patch: {
                  $0.labelSource = .owner; $0.personID = pid; $0.matchedSampleID = nil; $0.score = nil
              }) else { return .stale }
        if let v = VoiceMatcher.normalize(cluster.embedding) {
            var s = VoiceSample(personID: pid, embedding: VoicePrintEmbedding.encode(v),
                                modelVersion: cluster.modelVersion ?? VoiceRegistryPolicy.embeddingModelVersion,
                                origin: .owner, anchor: true, status: .active, transcriptID: transcriptID,
                                clusterLabel: cluster.restoreLabel, channel: cluster.channel ?? .unknown,
                                speechSec: cluster.speechSec ?? 0)
            try VoiceSampleQueries.insert(db, &s)
        }
        if let taskID, let task = try VoiceLabelTask.fetchOne(db, key: taskID) {
            if task.reason == .importConfirm {
                // Spec §5: activate that person's pending samples from the sender whose sample
                // suggested this voice — the nearest pending sample of that person identifies it.
                let pending = try VoiceSample.filter(Column("person_id") == pid && Column("status") == "pending").fetchAll(db)
                if let nearest = VoiceMatcher.nearestSample(embedding: cluster.embedding, samples: pending) {
                    try VoiceSampleQueries.activatePending(db, personID: pid, importID: nearest.importID)
                }
            }
            try VoiceLabelQueueQueries.close(db, id: taskID, status: .done)
        }
        return .labeled(personID: pid)
    }

    static func dismiss(_ db: Database, taskID: Int64, kind: DismissKind) throws {
        guard kind != .skip, let task = try VoiceLabelTask.fetchOne(db, key: taskID) else { return }
        try markCluster(db, transcriptID: task.transcriptID, label: task.clusterLabel, mixed: kind == .severalPeople)
        try VoiceLabelQueueQueries.close(db, id: taskID, status: .done)
    }

    private static func markCluster(_ db: Database, transcriptID: Int64, label: String, mixed: Bool) throws {
        guard let t = try MeetingTranscriptQueries.fetch(db, id: transcriptID),
              let json = t.speakersJSON, var speakers = SpeakerEmbeddings.decode(json) else { return }
        for i in speakers.indices where speakers[i].speaker == label {
            speakers[i].labelSource = .owner
            if mixed { speakers[i].mixed = true }
        }
        guard let re = SpeakerEmbeddings.encode(speakers) else { throw MeetingTranscriptQueryError.speakerEncodeFailed }
        try db.execute(sql: "UPDATE meeting_transcripts SET speakers_json = ? WHERE id = ?", arguments: [re, transcriptID])
    }
}
```

Add to `VoiceMatcher` (Task 3 file): `package static func nearestSample(embedding: [Float], samples: [VoiceSample]) -> VoiceSample?` (highest cosine, degenerate vectors skipped). `testImportConfirmActivatesPendingSamplesOfThatPerson` must also pin that a *second* sender's pending samples for the same person stay `pending` (spec §5: "from that sender").
Add `mixed` to `SpeakerEmbedding` (Task 3 file): `package var mixed: Bool?`, CodingKey `mixed`; a mixed cluster is never learned from or relabeled (Task 9 retro skips `mixed == true`).

- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit**

```bash
git add -A WatchtowerDesktop
git commit -m "feat(desktop): voice labeling transactions (confirm, dismiss, stale guard)"
```

---

### Task 9: Retro relabel

**Files:**
- Create: `WatchtowerDesktop/Sources/Services/VoiceRetroRelabeler.swift`
- Test: `WatchtowerDesktop/Tests/VoiceRetroRelabelerTests.swift`

**Interfaces:**
- Consumes: `VoiceMatcher`, `relabelCluster`, `VoicePrintQueries.personIDs`, `CalendarQueries.fetchEvent`.
- Produces: `enum VoiceRetroRelabeler { static func run(_ db: Database, onlyPersonID: Int64? = nil) throws -> Int }` (returns clusters relabeled). Per transcript: decode `speakers_json`; clusters with `effectiveLabelSource == .none && mixed != true`; `VoiceMatcher.decide` with **active** samples only (strip pending) and the transcript's invited set (event attendees, nil without event); apply only `.confident` via `relabelCluster(... patch: labelSource = .auto, personID, matchedSampleID, score)`. Never enqueues, never inserts samples. `onlyPersonID` restricts applied labels to that person (still computing full decisions so margins stay correct).

- [ ] **Step 1: Failing tests**

```swift
final class VoiceRetroRelabelerTests: XCTestCase {
    func testRelabelsOnlyUnnamedClustersIncludingAudioLessRecordings() throws {
        let db = try TestDatabase.make()
        let tid = try db.insertTranscript(audioPath: "", segmentsJSON: TestFixtures.threeSpeakerSegments, // "Speaker 1","Bob","Я"
            speakersJSON: #"[{"speaker":"Speaker 1","embedding":[1,0]},{"speaker":"Bob","embedding":[1,0]},{"speaker":"Я","embedding":[1,0]}]"#)
        try db.write { conn in
            let p = try VoicePrintQueries.findOrCreate(conn, personKey: "alice@example.com", displayName: "Alice")
            var s = VoiceSample(personID: p.id!, embedding: VoicePrintEmbedding.encode([1, 0]), modelVersion: VoiceRegistryPolicy.embeddingModelVersion,
                                origin: .owner, anchor: true, status: .active)
            try VoiceSampleQueries.insert(conn, &s)
            XCTAssertEqual(try VoiceRetroRelabeler.run(conn), 1)
            let labels = try XCTUnwrap(MeetingTranscriptQueries.fetch(conn, id: tid)?.speakerEmbeddings).map(\.speaker)
            XCTAssertEqual(Set(labels), ["Alice", "Bob", "Я"])      // Bob and «Я» untouched
            XCTAssertEqual(try VoiceLabelQueueQueries.pendingCount(conn), 0)
            XCTAssertEqual(try VoiceSample.fetchCount(conn), 1)
        }
    }

    func testPendingImportedSamplesNeverDriveRetro() throws { /* only a pending imported sample for Alice → run == 0 */ }
    func testUninvitedPersonIsNotAppliedRetroactively() throws { /* transcript linked to an event without Alice → run == 0 */ }
    func testMixedClusterIsSkipped() throws { /* speakers_json {"speaker":"Speaker 1",...,"mixed":true} → run == 0 */ }
    func testIdempotent() throws { /* second run returns 0 */ }
}
```

Write the four compact tests fully. The event case inserts a `calendar_events` row via the helper the calendar query tests use.

- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement**

```swift
import Foundation
import GRDB
import WatchtowerCore

/// Spec §4.1: name past unnamed clusters from active samples; never enqueue, never learn.
enum VoiceRetroRelabeler {
    @discardableResult
    static func run(_ db: Database, onlyPersonID: Int64? = nil) throws -> Int {
        let samples = try VoiceSampleQueries.fetchUsable(db).filter { $0.status == .active }
        guard !samples.isEmpty else { return 0 }
        let people = Dictionary(uniqueKeysWithValues: try VoicePrintQueries.fetchAll(db).compactMap { p in p.id.map { ($0, p) } })
        let ownerEmails = Set(try GoogleAccountQueries.fetchAll(db).map { $0.email.lowercased() })
        let owners = Set(people.values.filter { VoicePrintQueries.isOwner($0, ownerEmails: ownerEmails) }.compactMap(\.id))
        let rows = try Row.fetchAll(db, sql: "SELECT id, event_id FROM meeting_transcripts WHERE speakers_json IS NOT NULL")
        var changed = 0
        for row in rows {
            let tid: Int64 = row["id"]
            guard let t = try MeetingTranscriptQueries.fetch(db, id: tid), let speakers = t.speakerEmbeddings else { continue }
            let candidates = speakers.filter { $0.effectiveLabelSource == .none && $0.mixed != true }
            guard !candidates.isEmpty else { continue }
            var invited: Set<Int64>?
            if let eventID: String = row["event_id"], let e = try CalendarQueries.fetchEvent(db, id: eventID) {
                invited = try VoicePrintQueries.personIDs(db, matching: e.attendeesIncludingOrganizer)
            }
            let clusters = speakers.map { VoiceMatcher.Cluster(label: $0.speaker, embedding: $0.embedding,
                                                               speechSec: $0.speechSec ?? VoiceRegistryPolicy.minClusterSpeechSec) }
            let decisions = VoiceMatcher.decide(clusters: clusters, samples: samples, invited: invited, ownerPersonIDs: owners)
            for c in candidates {
                guard case let .confident(pid, sid, score) = decisions[c.speaker], onlyPersonID == nil || onlyPersonID == pid,
                      let person = people[pid] else { continue }
                if try MeetingTranscriptQueries.relabelCluster(db, id: tid, from: c.speaker, to: person.displayName, patch: {
                    $0.labelSource = .auto; $0.personID = pid; $0.matchedSampleID = sid; $0.score = score
                }) { changed += 1 }
            }
        }
        return changed
    }
}
```

Legacy clusters without `speech_sec` are treated as long enough (they were saved before the 20 s rule and their speech is unknown); note this in the doc comment. Already-named clusters in the same transcript still take part in `decide` so the per-recording uniqueness rule (Review Focus 1) keeps a second cluster from getting the same person.

- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit**

```bash
git add -A WatchtowerDesktop
git commit -m "feat(desktop): retro relabel of unnamed clusters from active samples"
```

---

### Task 10: Rollback — wrong auto label, delete person, delete import

**Files:**
- Modify: `WatchtowerDesktop/Sources/Database/Queries/VoiceLabelingQueries.swift`
- Test: `WatchtowerDesktop/Tests/VoiceRollbackTests.swift`

**Interfaces:**
- Produces: `VoiceLabelingQueries.rejectAutoLabel(_ db:, transcriptID:, clusterLabel:) throws -> Int` (clusters reverted), `deletePerson(_ db:, personID:) throws -> Int`, `deleteImport(_ db:, importID:) throws -> Int`. All three end by calling a private `revertOrphanedAutoLabels(_ db:, removedSampleIDs: Set<Int64>)` that re-matches every `auto` cluster whose `matchedSampleID` is in the set against the remaining active samples and reverts to `restoreLabel` (patch `labelSource = .none`, `personID = nil`, `matchedSampleID = nil`, `score = nil`) when no longer confident for the same person; a rejected cluster with audio is enqueued as `.relabel`.

- [ ] **Step 1: Failing tests**

```swift
final class VoiceRollbackTests: XCTestCase {
    func testRejectRetiresMintedSampleAndRevertsDependents() throws {
        // Alice anchor A0; transcript T1 cluster X auto-labeled Alice (matched A0) and minted auto sample S1;
        // transcript T2 cluster Y auto-labeled Alice with matchedSampleID S1 and only S1 matches Y.
        // rejectAutoLabel(T1, "Alice") → X back to "Speaker 1", S1 retired, Y back to its Speaker label; X enqueued .relabel
    }
    func testDeletePersonKeepsOwnerSetNamesAsText() throws {
        // cluster labeled by owner (labelSource .owner) stays "Alice" with personID nil; auto cluster reverts
    }
    func testDeleteImportRevertsLabelsThatDependedOnlyOnIt() throws {
        // an activated imported sample was the matched sample of an auto cluster; deleteImport → cluster reverts
    }
}
```

Write each test fully with the fixture helpers from Tasks 8–9 (set `speakers_json` directly with `label_source`, `person_id`, `matched_sample_id`, `original_label` fields; insert samples with explicit ids).

- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement** in `VoiceLabelingQueries`:

```swift
static func rejectAutoLabel(_ db: Database, transcriptID: Int64, clusterLabel: String) throws -> Int {
    guard let t = try MeetingTranscriptQueries.fetch(db, id: transcriptID),
          let c = t.speakerEmbeddings?.first(where: { $0.speaker == clusterLabel }), c.labelSource == .auto else { return 0 }
    let minted = try Int64.fetchAll(db, sql: "SELECT id FROM voice_samples WHERE transcript_id = ? AND cluster_label = ? AND origin = 'auto' AND status = 'active'",
                                    arguments: [transcriptID, c.restoreLabel])
    for id in minted { try VoiceSampleQueries.retire(db, id: id) }
    var n = try revert(db, transcriptID: transcriptID, cluster: c) ? 1 : 0
    if FileManager.default.fileExists(atPath: t.audioPath ?? "") {
        try VoiceLabelQueueQueries.enqueue(db, transcriptID: transcriptID, clusterLabel: c.restoreLabel, reason: .relabel,
                                           suggestedPersonID: nil, score: nil)
    }
    n += try revertOrphanedAutoLabels(db, removedSampleIDs: Set(minted))
    return n
}

static func deletePerson(_ db: Database, personID: Int64) throws -> Int {
    let ids = Set(try Int64.fetchAll(db, sql: "SELECT id FROM voice_samples WHERE person_id = ?", arguments: [personID]))
    var n = 0
    for (tid, c) in try clusters(db, where: { $0.personID == personID }) {
        if c.labelSource == .auto { n += try revert(db, transcriptID: tid, cluster: c) ? 1 : 0 }
        else { try patchCluster(db, transcriptID: tid, label: c.speaker) { $0.personID = nil } }
    }
    try VoicePrintQueries.delete(db, id: personID)
    return n + (try revertOrphanedAutoLabels(db, removedSampleIDs: ids))
}

static func deleteImport(_ db: Database, importID: Int64) throws -> Int {
    let ids = Set(try Int64.fetchAll(db, sql: "SELECT id FROM voice_samples WHERE import_id = ?", arguments: [importID]))
    try VoiceImportQueries.delete(db, id: importID)          // samples cascade
    return try revertOrphanedAutoLabels(db, removedSampleIDs: ids)
}

private static func revertOrphanedAutoLabels(_ db: Database, removedSampleIDs: Set<Int64>) throws -> Int {
    guard !removedSampleIDs.isEmpty else { return 0 }
    let active = try VoiceSampleQueries.fetchUsable(db).filter { $0.status == .active }
    var n = 0
    for (tid, c) in try clusters(db, where: { $0.labelSource == .auto && removedSampleIDs.contains($0.matchedSampleID ?? -1) }) {
        let best = VoiceMatcher.nearest(embedding: c.embedding, samples: active)
        let stillSure = best.first.map { $0.personID == c.personID && $0.score >= VoiceRegistryPolicy.confident
            && $0.score - (best.dropFirst().first?.score ?? -1) >= VoiceRegistryPolicy.margin } ?? false
        if stillSure, let top = best.first {
            try patchCluster(db, transcriptID: tid, label: c.speaker) { $0.matchedSampleID = top.sampleID; $0.score = top.score }
        } else if try revert(db, transcriptID: tid, cluster: c) { n += 1 }
    }
    return n
}

private static func revert(_ db: Database, transcriptID: Int64, cluster c: SpeakerEmbedding) throws -> Bool {
    try MeetingTranscriptQueries.relabelCluster(db, id: transcriptID, from: c.speaker, to: c.restoreLabel) {
        $0.labelSource = VoiceLabelSource.none; $0.personID = nil; $0.matchedSampleID = nil; $0.score = nil
    }
}

private static func clusters(_ db: Database, where match: (SpeakerEmbedding) -> Bool) throws -> [(Int64, SpeakerEmbedding)] {
    try Row.fetchAll(db, sql: "SELECT id FROM meeting_transcripts WHERE speakers_json IS NOT NULL").flatMap { row -> [(Int64, SpeakerEmbedding)] in
        let tid: Int64 = row["id"]
        return (try MeetingTranscriptQueries.fetch(db, id: tid)?.speakerEmbeddings ?? []).filter(match).map { (tid, $0) }
    }
}

private static func patchCluster(_ db: Database, transcriptID: Int64, label: String, _ patch: (inout SpeakerEmbedding) -> Void) throws {
    guard let t = try MeetingTranscriptQueries.fetch(db, id: transcriptID), let json = t.speakersJSON,
          var s = SpeakerEmbeddings.decode(json) else { return }
    for i in s.indices where s[i].speaker == label { patch(&s[i]) }
    guard let re = SpeakerEmbeddings.encode(s) else { throw MeetingTranscriptQueryError.speakerEncodeFailed }
    try db.execute(sql: "UPDATE meeting_transcripts SET speakers_json = ? WHERE id = ?", arguments: [re, transcriptID])
}
```

`relabelCluster` with `to` = `Speaker N` passes its guard (unnamed labels are allowed as targets; only «Я» is rejected). Refactor `markCluster` from Task 8 onto `patchCluster`.

- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(desktop): voice registry rollback (reject, delete person, delete import)"`

---

### Task 11: `VoiceRegistryCenter` and clip playback

**Files:**
- Create: `WatchtowerDesktop/Sources/Services/VoiceRegistryCenter.swift`, `Sources/Services/ClipPlayer.swift`
- Modify: `Sources/App/AppState.swift` (own the center, wire the db pool, launch catch-up)
- Test: `WatchtowerDesktop/Tests/VoiceRegistryCenterTests.swift`, `Tests/ClipPlayerTests.swift`

**Interfaces:**
- Produces:
  - `@MainActor @Observable final class VoiceRegistryCenter`:
    - `var pendingCount: Int`, `var cards: [VoiceCard]`, `var mode: VoicesWindowMode`, `var lastError: String?`
    - `enum VoicesWindowMode: Equatable { case queue(transcriptID: Int64?), review, train }`
    - `struct VoiceCard: Identifiable, Equatable { let id: Int64 /* task id */; let transcriptID: Int64; let meetingTitle: String; let date: String; let clusterLabel: String; let reason: VoiceLabelReason; let suggestion: VoicePrint?; let score: Float?; let clips: [ClipSpan]; let clipTexts: [String]; let audioPath: String; let candidates: [PersonChoice] }`, `struct PersonChoice: Hashable { let personKey: String; let displayName: String; let inRegistry: Bool }`
    - `func attach(dbPool: DatabasePool)`, `func refresh() async`, `func open(_ mode: VoicesWindowMode) async`, `func confirm(_ card: VoiceCard, person: PersonChoice) async`, `func dismiss(_ card: VoiceCard, _ kind: DismissKind) async`, `func relabel(transcriptID: Int64, clusterLabel: String) async` (enqueue `.relabel` then open queue for that transcript), `func catchUp() async` (skip audio-less tasks, retro run), `var openWindow: (() -> Void)?`
  - `@MainActor final class ClipPlayer`: `init(playerFactory: (URL) throws -> AudioPlayback)`, `func play(url: URL, span: ClipSpan)`, `func stop()`, `var playingSpan: ClipSpan?` — plays `[start, end)` using `currentTime = start`, then stops via a timer check `currentTime >= end`.

- [ ] **Step 1: Failing tests**

```swift
@MainActor
final class VoiceRegistryCenterTests: XCTestCase {
    func testRefreshBuildsCardsOnlyForTasksWithAudioAndClips() async throws {
        let db = try TestDatabase.makePool()
        let audio = try TestFixtures.tempAudioFile()                      // any existing file path
        let t1 = try db.insertTranscript(audioPath: audio.path, title: "Weekly",
            speakersJSON: #"[{"speaker":"Speaker 1","embedding":[1,0],"clips":[{"start":1,"end":6}]}]"#)
        let t2 = try db.insertTranscript(audioPath: "/nonexistent.caf",
            speakersJSON: #"[{"speaker":"Speaker 1","embedding":[1,0],"clips":[{"start":1,"end":6}]}]"#)
        try await db.write { c in
            try VoiceLabelQueueQueries.enqueue(c, transcriptID: t1, clusterLabel: "Speaker 1", reason: .unknown, suggestedPersonID: nil, score: nil)
            try VoiceLabelQueueQueries.enqueue(c, transcriptID: t2, clusterLabel: "Speaker 1", reason: .unknown, suggestedPersonID: nil, score: nil)
        }
        let center = VoiceRegistryCenter(); center.attach(dbPool: db)
        await center.catchUp(); await center.open(.queue(transcriptID: nil))
        XCTAssertEqual(center.cards.map(\.transcriptID), [t1])
        XCTAssertEqual(center.pendingCount, 1)
    }

    func testConfirmRunsRetroForThatPersonAndRemovesCard() async throws { /* two transcripts with the same voice; confirm on the first →
        the second (audio-less) gets the name via retro; cards empty; pendingCount 0 */ }

    func testStateSurvivesWindowCloseAndReopen() async throws { /* open(.review), set mode, simulate window closing (openWindow = nil),
        open(.queue) again → cards reloaded from DB, not lost */ }
}

@MainActor
final class ClipPlayerTests: XCTestCase {
    func testPlaysOnlyTheSpan() {
        let fake = FakeAudioPlayback(duration: 60)                      // add to Tests/Support if absent (AudioPlaybackCenterTests has one)
        let p = ClipPlayer(playerFactory: { _ in fake })
        p.play(url: URL(fileURLWithPath: "/tmp/x.caf"), span: ClipSpan(start: 10, end: 15))
        XCTAssertEqual(fake.currentTime, 10); XCTAssertTrue(fake.isPlaying)
        fake.currentTime = 15.01; p.tick()
        XCTAssertFalse(fake.isPlaying); XCTAssertNil(p.playingSpan)
    }
}
```

Write the two commented center tests fully.

- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement**

`ClipPlayer.swift`:

```swift
import AVFoundation
import WatchtowerCore

/// Plays one time range of a recording straight from the `.caf` — no clip
/// files are ever written (spec §3.1).
@MainActor
final class ClipPlayer {
    private let playerFactory: (URL) throws -> AudioPlayback
    private var player: AudioPlayback?
    private var timer: Timer?
    private(set) var playingSpan: ClipSpan?

    init(playerFactory: @escaping (URL) throws -> AudioPlayback = { try AVAudioPlayer(contentsOf: $0) }) {
        self.playerFactory = playerFactory
    }

    func play(url: URL, span: ClipSpan) {
        stop()
        guard let p = try? playerFactory(url) else { return }
        p.currentTime = span.start
        guard p.play() else { return }
        player = p; playingSpan = span
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func tick() {
        guard let p = player, let s = playingSpan else { return }
        if p.currentTime >= s.end || !p.isPlaying { stop() }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        player?.stop(); player = nil; playingSpan = nil
    }
}
```

`VoiceRegistryCenter.swift` — implement the interface above:
- `refresh()`: `pendingCount = VoiceLabelQueueQueries.pendingCount` read.
- `open(_:)`: set `mode`; for `.queue(tid)` load `pending(transcriptID:)`, join transcript (`title`, `created_at`, `audio_path`, `speakers_json`, `segments_json`), drop tasks whose cluster has no `clips` or whose audio file is missing, build `clipTexts` from utterances overlapping each clip, `candidates` = event attendees not in registry (via `CalendarQueries.fetchEvent`) + registry people (`VoicePrintQueries.fetchAll`) sorted by display name; `suggestion` = `VoicePrintQueries.fetch(id:)`. Then `openWindow?()`.
- `confirm`: `dbPool.write { VoiceLabelingQueries.confirm(...) }`; on `.labeled(pid)` run `VoiceRetroRelabeler.run(db, onlyPersonID: pid)` in a second write (off-main via `dbPool.write` async); remove the card; `refresh()`. `.alreadyLabeled`/`.stale` → remove the card and set `lastError` = "This voice was already labeled".
- `dismiss`: `VoiceLabelingQueries.dismiss` then remove the card (except `.skip`: move the card to the end).
- `catchUp()`: `skipTasksWithoutAudio`, then `VoiceRetroRelabeler.run(db)`, then `refresh()`. Called from AppState after the DB opens and after every `meetingRecorder` save (`savedTick` observation).
- Errors from DB calls set `lastError` (no silent `try?`), per review-rules error-handling convention.
- `AppState`: `let voiceRegistryCenter = VoiceRegistryCenter()`, `attach(dbPool:)` where `wireMeetingRecorderLoaders` runs, `Task { await voiceRegistryCenter.catchUp() }` once per DB open; `var openVoicesWindow: (() -> Void)?` set by the scene (Task 12).

- [ ] **Step 4: Run** — `make test-swift FILTER='VoiceRegistryCenterTests|ClipPlayerTests'` → PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(desktop): VoiceRegistryCenter and span clip playback"`

---

### Task 12: Voices window, tray, notification routing, settings; remove rename + speaker-guess UI

**Files:**
- Create: `WatchtowerDesktop/Sources/Views/Voices/VoicesWindowView.swift`, `VoiceCardView.swift`
- Modify: `Sources/App/WatchtowerApp.swift:338-412` (scene), `WatchtowerApp.swift:103-150` (`NotificationDelegate.route`), `Sources/Views/TrayMenuView.swift:8-108`, `Sources/Views/Settings/MeetingsSettings.swift:11-25,148-161`, `Sources/Views/Calendar/RecordingDetailTabs.swift:535-890`, `Sources/Views/Calendar/RecordingDetailView.swift:172-188,374-409`, `Sources/Services/NotificationForwarding.swift:51`
- Delete: `Sources/Services/SpeakerGuessCenter.swift`, `Tests/SpeakerGuessCenterTests.swift`; remove `speakerGuess(transcriptID:)`, `SpeakerGuessResult`, `SpeakerSuggestion` from `WatchtowerCore/Services/TranscriptSaveService.swift` and their tests in `Tests/Core/TranscriptSaveServiceTests.swift`; remove `speakerGuessCenter` from `AppState`.
- Test: `WatchtowerDesktop/Tests/VoiceCardViewTests.swift` (ViewInspector), `Tests/TrayMenuContentTests.swift` (extend existing), `Tests/NotificationRoutingTests.swift` (extend existing `route` tests), `Tests/RecordingTranscriptTabTests.swift` (extend existing)

**Interfaces:**
- Consumes: `VoiceRegistryCenter`, `ClipPlayer`.
- Produces: scene `Window("Voices", id: VoicesWindowView.sceneID)` with `sceneID = "voices"`; `TrayMenuContent` gains `voicesPendingCount: Int`, `voicesAction`, `reviewVoicesAction`, `trainVoicesAction`; `RecordingTranscriptTab` loses `suggestions/isSuggesting/suggestError/suggestNotice/onSuggestNames/onRenameSpeaker/onDismissSuggestion` and gains `onListenToSamples: (_ speaker: String) -> Void` and `showRecapRefreshHint: Bool`, `onRegenerateRecap: () -> Void`.

- [ ] **Step 1: Failing tests**

```swift
final class VoiceCardViewTests: XCTestCase {
    func testCardShowsReasonClipsAndPreselectedSuggestion() throws {
        let card = VoiceCard.fixture(reason: .unsure, suggestion: VoicePrint(id: 1, personKey: "alice@example.com", displayName: "Alice"),
                                     score: 0.66, clips: [ClipSpan(start: 1, end: 6), ClipSpan(start: 9, end: 14)])
        let view = VoiceCardView(card: card, onPlay: { _ in }, onConfirm: { _ in }, onDismiss: { _ in })
        XCTAssertNoThrow(try view.inspect().find(text: "Looks like Alice (0.66)"))
        XCTAssertEqual(try view.inspect().findAll(ViewType.Button.self, where: { try $0.labelView().text().string().hasPrefix("▶") }).count, 2)
        XCTAssertEqual(try view.inspect().find(ViewType.Picker.self).selectedValue(PersonChoice.self)?.displayName, "Alice")
    }
}
```

Tray: assert `TrayMenuContent(... voicesPendingCount: 3 ...)` renders a button "Voices to label (3)" and hides it at 0; "Review voices" and "Train voices" always present.
Routing: `NotificationDelegate.route(actionID: UNNotificationDefaultActionIdentifier, userInfo: ["type": "voice_label", "transcriptID": Int64(5)], appState: app, forwarded: false)` → `app.voiceRegistryCenter.mode == .queue(transcriptID: 5)`. Add `"transcriptID"` to `NotificationForwarding.routedKeys`.
Transcript tab: speaker label tap calls `onListenToSamples("Speaker 2")`; no "Suggest speaker names" button exists; recap hint visible when `showRecapRefreshHint`.

- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement**
- `VoiceCardView`: header (meeting · date · reason text per `VoiceLabelReason`: unknown → "Not recognized", unsure → "Looks like X (0.66)" or "… but X was not invited" when `score ≥ 0.70`, importConfirm → "From an imported file: is this X?", conflict → "Two sources disagree", relabel → "Relabel this voice"), one `▶ mm:ss` button per clip + its text, `Picker` over `card.candidates` with "New person…" (reveals name + email fields; name must not be reserved — reuse `SpeakerNaming.isReserved`), buttons Confirm / Don't know / Several people / Skip. Keyboard: `.keyboardShortcut(.space)` plays the first clip, `.keyboardShortcut(.defaultAction)` confirms, number keys 1–9 select candidates via `.onKeyPress`.
- `VoicesWindowView`: switches on `center.mode` — `.queue` shows the cards list (empty state "No voices to label"), `.review` → `VoiceReviewView` (Task 13), `.train` → `VoiceTrainView` (Task 14); a segmented control switches modes (calls `center.open`).
- Scene in `WatchtowerApp.body`: `Window("Voices", id: VoicesWindowView.sceneID) { VoicesWindowView().environment(appState) }.defaultSize(width: 640, height: 720)`; set `appState.openVoicesWindow = { openWindow(id: VoicesWindowView.sceneID) }` at the same two places `openQuickCapture` is set, and `appState.voiceRegistryCenter.openWindow = { ActivationPolicyDecision.becomeRegularAndActivate(); appState.openVoicesWindow?() }`. The Voices window counts as a visible window for the activation policy like Settings/Pipeline Progress (check `TrayAppDelegate`'s visible-window logic and add the scene id if it filters by id).
- `NotificationDelegate.route`: `case "voice_label": if let id = userInfo["transcriptID"] as? Int64 ?? (userInfo["transcriptID"] as? NSNumber)?.int64Value { await appState?.voiceRegistryCenter.open(.queue(transcriptID: id)) }`.
- Tray: new buttons between "New Voice Idea" and "Open Watchtower": `if voicesPendingCount > 0 { Button("Voices to label (\(voicesPendingCount))", action: voicesAction) }`, `Button("Review voices", action: reviewVoicesAction)`, `Button("Train voices", action: trainVoicesAction)`; `TrayMenuView` passes `appState.voiceRegistryCenter.pendingCount` and closures calling `open(.queue(transcriptID: nil))`, `.review`, `.train`.
- Settings `speakersSection`: `@AppStorage("transcription.voiceRecognition") var voiceRecognition = true`, `@AppStorage("transcription.voiceNotifications") var voiceNotifications = true`; toggles "Voice recognition" and "Notify about unknown voices" (the latter disabled when recognition is off).
- Transcript tab: delete `SpeakerRenameTarget`, `SpeakerRenameSheet`, `suggestBar`, `suggestionChip`, the chip anchors; `speakerLabel` for non-«Я» labels becomes a button with `.help("Listen to samples")` calling `onListenToSamples(label)`. Add the recap hint row above the utterance list when `showRecapRefreshHint`: text "Speaker names were updated — regenerate the recap?" + button calling `onRegenerateRecap`.
- `RecordingDetailView`: remove `suggestSpeakerNames`, `renameSpeaker`, `consumeSuggestion` and all `speakerGuessCenter` reads; `onListenToSamples: { label in Task { await appState.voiceRegistryCenter.relabel(transcriptID: transcriptID, clusterLabel: label) } }`; `showRecapRefreshHint` = `transcript.speakerNamesChangedAt > max(recap updated_at, notes updated_at)` using the timestamps `load()` already has (string compare on the shared ISO format); `onRegenerateRecap` calls the existing recap-regenerate action of the Recap tab (the one behind its retry button).

- [ ] **Step 4: Run** — `make test-swift FILTER='VoiceCardViewTests|TrayMenuContentTests|NotificationRoutingTests|RecordingTranscriptTabTests|TranscriptSaveServiceTests|AppStateTests'` → PASS; `cd WatchtowerDesktop && swift build` → no references to `SpeakerGuess*`, `renameSpeaker`, `VoicePrintMatcher` (`grep -rn` returns nothing).
- [ ] **Step 5: Commit** — `git commit -m "feat(desktop): Voices window, tray and notification entry points; drop rename and speaker-guess UI"`

---

### Task 13: Review mode — registry list, deletion, spot checks

**Files:**
- Create: `WatchtowerDesktop/Sources/Views/Voices/VoiceReviewView.swift`
- Modify: `Sources/Services/VoiceRegistryCenter.swift` (review state + actions), `Sources/Database/Queries/VoiceSampleQueries.swift` (summary query)
- Test: `WatchtowerDesktop/Tests/VoiceReviewTests.swift`

**Interfaces:**
- Produces:
  - `struct VoicePersonSummary: Identifiable, Equatable { let id: Int64; let displayName: String; let personKey: String; let counts: [VoiceSampleOrigin: Int]; let channels: Set<VoiceChannel>; let lastRecognized: String? }`
  - `VoiceSampleQueries.personSummaries(_:) -> [VoicePersonSummary]` (active samples grouped; `lastRecognized` = max `created_at` of samples with a transcript)
  - `struct VoiceSpotCheck: Identifiable { let id: String /* "\(tid):\(label)" */; let transcriptID: Int64; let clusterLabel: String; let personID: Int64; let clips: [ClipSpan]; let audioPath: String; let meetingTitle: String }`
  - Center: `var people: [VoicePersonSummary]`, `var imports: [VoiceImport]`, `var spotChecks: [VoiceSpotCheck]`, `func loadReview() async`, `func spotCheck(_:correct: Bool) async` (false → `rejectAutoLabel`), `func deletePerson(_ id: Int64) async`, `func deleteImport(_ id: Int64) async`.
  - Spot checks = per person the 3 latest `labelSource == .auto` clusters whose recording still has audio.

- [ ] **Step 1: Failing tests** — summaries count by origin and channel; spot checks exclude audio-less recordings and owner-set clusters; `spotCheck(correct: false)` reverts the label and enqueues `.relabel`; `deletePerson` removes the row and reverts its auto labels (reuse Task 10 fixtures).
- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement** the query (`SELECT person_id, origin, channel, count(*) … GROUP BY person_id, origin, channel`, folded in Swift), the center methods (each through `dbPool.write`/`read`, errors to `lastError`), and the view: a `List` of people (name, "3 yours · 12 auto · 2 imported", channel chips, a destructive "Delete" with `confirmationDialog`), an "Imports" section (sender, date, counts, "Delete everything from <sender>"), a "Spot checks" section (clip buttons via `ClipPlayer`, "Correct" / "Wrong"), and a "Channel gaps" line for people with a single channel ("Only meeting-room samples"). Export/Import buttons live here (wired in Task 15).
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(desktop): voice review mode"`

---

### Task 14: Train mode — cross-meeting groups and quality numbers

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/VoiceRegistry/VoiceGrouping.swift`, `Sources/Views/Voices/VoiceTrainView.swift`
- Modify: `Sources/Services/VoiceRegistryCenter.swift`
- Test: `WatchtowerDesktop/Tests/Core/VoiceGroupingTests.swift`, `Tests/VoiceTrainTests.swift`

**Interfaces:**
- Produces:
  - `package struct GroupableCluster: Equatable, Sendable { let key: String /* "tid:label" */; let transcriptID: Int64; let label: String; let embedding: [Float]; let speechSec: Double; let hasAudio: Bool; let attendees: Set<String> /* person keys */ }`
  - `package enum VoiceGrouping { static func group(_ clusters: [GroupableCluster], mergeAt: Float = VoiceRegistryPolicy.groupMerge) -> [[GroupableCluster]]` (average linkage, cannot-link on same `transcriptID`, sorted by total speech desc) `; static func suggestion(for group: [GroupableCluster], registeredKeys: Set<String>) -> (personKey: String, meetings: Int, of: Int)?` (most frequent not-registered attendee key) `; static func estimateAccuracy(anchors: [VoiceSample], threshold: Float = VoiceRegistryPolicy.confident) -> (precision: Double, recall: Double, evaluated: Int)` (leave-one-recording-out over anchors with a non-nil `transcriptID`) }`
  - Center: `var groups: [TrainGroup]`, `var quality: TrainQuality`, `func loadTrain() async`, `func confirmGroup(_:person:) async`, `func dismissGroup(_:severalPeople: Bool) async`. `struct TrainGroup: Identifiable { let id: String; let members: [GroupableCluster]; let audioMembers: [GroupableCluster]; let suggestion: PersonChoice?; let hint: String; let speechMin: Double }`, `struct TrainQuality: Equatable { let namedMinutes: Double; let ownerMinutes: Double; let autoMinutes: Double; let precision: Double; let recall: Double; let people: Int; let singleChannelPeople: Int }`.

- [ ] **Step 1: Failing tests** (`VoiceGroupingTests`)

```swift
final class VoiceGroupingTests: XCTestCase {
    private func c(_ key: String, tid: Int64, _ v: [Float], speech: Double = 60, audio: Bool = true, att: Set<String> = []) -> GroupableCluster {
        GroupableCluster(key: key, transcriptID: tid, label: key, embedding: v, speechSec: speech, hasAudio: audio, attendees: att)
    }
    func testSameRecordingNeverMerges() {
        let g = VoiceGrouping.group([c("a", tid: 1, [1, 0]), c("b", tid: 1, [1, 0])])
        XCTAssertEqual(g.count, 2)
    }
    func testSimilarAcrossRecordingsMergeAndSortBySpeech() {
        let g = VoiceGrouping.group([c("a", tid: 1, [1, 0], speech: 30), c("b", tid: 2, [0.99, 0.1], speech: 30), c("z", tid: 3, [0, 1], speech: 100)])
        XCTAssertEqual(g.map { $0.map(\.key).sorted() }, [["z"], ["a", "b"]])
    }
    func testSuggestionUsesInviteIntersectionExcludingRegistered() {
        let group = [c("a", tid: 1, [1, 0], att: ["alice@example.com", "bob@example.com"]), c("b", tid: 2, [1, 0], att: ["alice@example.com"])]
        XCTAssertEqual(VoiceGrouping.suggestion(for: group, registeredKeys: [])?.personKey, "alice@example.com")
        XCTAssertEqual(VoiceGrouping.suggestion(for: group, registeredKeys: ["alice@example.com"])?.personKey, "bob@example.com")
    }
    func testAccuracyEstimateLeaveOneRecordingOut() {
        func a(_ id: Int64, _ p: Int64, _ tid: Int64, _ v: [Float]) -> VoiceSample {
            VoiceSample(id: id, personID: p, embedding: VoicePrintEmbedding.encode(v), modelVersion: VoiceRegistryPolicy.embeddingModelVersion,
                        origin: .owner, anchor: true, status: .active, transcriptID: tid)
        }
        let r = VoiceGrouping.estimateAccuracy(anchors: [a(1, 1, 1, [1, 0]), a(2, 1, 2, [0.98, 0.1]), a(3, 2, 1, [0, 1]), a(4, 2, 3, [0.1, 0.99])])
        XCTAssertEqual(r.precision, 1); XCTAssertEqual(r.recall, 1); XCTAssertEqual(r.evaluated, 4)
    }
}
```

`VoiceTrainTests`: groups exclude clusters from recordings without audio unless the group has ≥ 1 audio member (audio-less members listed in `members` only); a group with no audio member is dropped; `confirmGroup` labels every member (audio-less ones via `relabelCluster` with `labelSource = .owner`) and creates anchors only from audio members; `dismissGroup(severalPeople: true)` marks all members `mixed`.

- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement** `VoiceGrouping` (average-linkage loop as in the research spike: repeatedly merge the pair with the highest mean cosine ≥ `mergeAt`, skipping pairs sharing a `transcriptID`; O(n³) is fine for the ≤ few hundred clusters of a local install — note the bound in a comment), `suggestion` (count attendee keys across distinct recordings of the group, skip `registeredKeys`, return max), `estimateAccuracy` (for each anchor with a transcript: prints = anchors of other recordings; best person by nearest sample with margin; count TP/FP/FN as in the spike; `evaluated` counts anchors whose person has prints elsewhere). Center `loadTrain`: clusters = every `speakers_json` entry with `effectiveLabelSource == .none`, `mixed != true`, `speechSec ≥ minClusterSpeechSec` (legacy nil → included), `hasAudio` from the recording's file; attendees via event; drop groups without an audio member; `hint` text like the spec ("looks like X, 0.64" when the nearest registry person is ≥ unsureFloor, else "was at N of M meetings"). `quality` from `speakers_json` speech per `labelSource` and `estimateAccuracy` over anchors. `confirmGroup` runs `VoiceLabelingQueries.confirm(taskID: nil, …)` per audio member, `relabelCluster(... labelSource = .owner, personID)` per audio-less member, then `VoiceRetroRelabeler.run(onlyPersonID:)` and `loadTrain()` (live regrouping). The view: header with the quality numbers, then group cards reusing `VoiceCardView`'s clip row and picker, a "+N meetings without audio — will be labeled from this" line, Confirm / Several people / Don't know; empty state "No new voices to train".
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(desktop): voice train mode with live regrouping and quality estimate"`

---

### Task 15: Import / export

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/VoiceRegistry/VoiceExportCodec.swift`, `Sources/Views/Voices/VoiceImportExportView.swift`
- Modify: `Sources/Database/Queries/VoiceImportQueries.swift`, `Sources/Services/VoiceRegistryCenter.swift`, `Sources/Views/Voices/VoiceReviewView.swift`
- Test: `WatchtowerDesktop/Tests/Core/VoiceExportCodecTests.swift`, `Tests/VoiceImportTests.swift`

**Interfaces:**
- Produces:
  - `package struct VoiceExportPayload: Codable, Equatable { let formatVersion: Int /* 1 */; let modelVersion: String; let sender: Sender; let people: [Person]; struct Sender: Codable, Equatable { let name: String; let email: String }; struct Person: Codable, Equatable { let personKey: String; let displayName: String; let samples: [Sample] }; struct Sample: Codable, Equatable { let embedding: [Float]; let channel: VoiceChannel; let speechSec: Double } }`
  - `package enum VoiceExportCodec { static let magic = Data("WTVOICES1".utf8); static func seal(_ payload: VoiceExportPayload, password: String) throws -> Data; static func open(_ data: Data, password: String) throws -> VoiceExportPayload; enum CodecError: Error, Equatable { case badMagic, wrongPasswordOrCorrupt, unsupportedFormat, emptyPassword } }` — layout `magic ‖ salt(16) ‖ AES.GCM.SealedBox.combined`.
  - `VoiceImportQueries.buildExport(_ db:, sender:, personIDs: Set<Int64>) -> VoiceExportPayload` (invariant 4, ≤ `exportPerChannel` per person+channel: anchors first, then `score` desc)
  - `struct VoiceImportPreview: Equatable { let sender: VoiceExportPayload.Sender; let people: Int; let samples: Int; let merges: [String]; let newPeople: [String]; let conflicts: [String]; let skippedOwner: Int; let modelMismatch: Bool; let alreadyImported: Bool }`
  - `VoiceImportQueries.preview(_ db:, payload:, fileSHA256:, ownerEmails:) -> VoiceImportPreview`, `apply(_ db:, payload:, fileSHA256:, ownerEmails:) throws -> Int64?` (nil = duplicate or mismatch; one transaction; replaces the same sender's previous pending samples; skips owner emails and reserved names; inserts `imported`/`pending`)
  - Center: `func export(to url: URL, password: String, personIDs: Set<Int64>) async throws`, `func previewImport(url: URL, password: String) async throws -> VoiceImportPreview`, `func applyImport() async throws`.

- [ ] **Step 1: Failing tests**

```swift
final class VoiceExportCodecTests: XCTestCase {
    private let payload = VoiceExportPayload(formatVersion: 1, modelVersion: VoiceRegistryPolicy.embeddingModelVersion,
        sender: .init(name: "Colleague A", email: "a@example.com"),
        people: [.init(personKey: "alice@example.com", displayName: "Alice", samples: [.init(embedding: [0.6, 0.8], channel: .remote, speechSec: 40)])])

    func testRoundTrip() throws {
        XCTAssertEqual(try VoiceExportCodec.open(try VoiceExportCodec.seal(payload, password: "pw"), password: "pw"), payload)
    }
    func testWrongPasswordAndTamperFail() throws {
        var data = try VoiceExportCodec.seal(payload, password: "pw")
        XCTAssertThrowsError(try VoiceExportCodec.open(data, password: "nope")) { XCTAssertEqual($0 as? VoiceExportCodec.CodecError, .wrongPasswordOrCorrupt) }
        data[data.count - 1] ^= 0xFF
        XCTAssertThrowsError(try VoiceExportCodec.open(data, password: "pw")) { XCTAssertEqual($0 as? VoiceExportCodec.CodecError, .wrongPasswordOrCorrupt) }
    }
    func testFileNeverContainsPlaintextNames() throws {
        let data = try VoiceExportCodec.seal(payload, password: "pw")
        XCTAssertNil(data.range(of: Data("alice@example.com".utf8)))
    }
    func testEmptyPasswordRejected() {
        XCTAssertThrowsError(try VoiceExportCodec.seal(payload, password: "")) { XCTAssertEqual($0 as? VoiceExportCodec.CodecError, .emptyPassword) }
    }
}
```

`VoiceImportTests`: export from DB A (owner + auto + one imported sample) → the imported one is absent and ≤ 5 per channel; import into DB B → samples `pending`, person merged by email keeps B's display name; owner email skipped; same file twice → `apply` returns nil; a newer file from the same sender replaces its previous pending samples but keeps activated ones; model mismatch → preview `modelMismatch == true`, `apply` returns nil and writes nothing; conflict: an imported sample ≥ 0.80 to a different local person appears in `preview.conflicts`.

- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement codec**

```swift
import CommonCrypto
import CryptoKit
import Foundation

package enum VoiceExportCodec {
    package static let magic = Data("WTVOICES1".utf8)
    static let iterations: UInt32 = 200_000
    package enum CodecError: Error, Equatable { case badMagic, wrongPasswordOrCorrupt, unsupportedFormat, emptyPassword }

    package static func seal(_ payload: VoiceExportPayload, password: String) throws -> Data {
        guard !password.isEmpty else { throw CodecError.emptyPassword }
        var salt = Data(count: 16)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        precondition(status == errSecSuccess)
        let key = try deriveKey(password: password, salt: salt)
        let body = try JSONEncoder().encode(payload)
        guard let combined = try AES.GCM.seal(body, using: key).combined else { throw CodecError.wrongPasswordOrCorrupt }
        return magic + salt + combined
    }

    package static func open(_ data: Data, password: String) throws -> VoiceExportPayload {
        guard data.count > magic.count + 16, data.prefix(magic.count) == magic else { throw CodecError.badMagic }
        let salt = data.subdata(in: magic.count..<(magic.count + 16))
        let key = try deriveKey(password: password, salt: salt)
        do {
            let box = try AES.GCM.SealedBox(combined: data.suffix(from: magic.count + 16))
            let payload = try JSONDecoder().decode(VoiceExportPayload.self, from: try AES.GCM.open(box, using: key))
            guard payload.formatVersion == 1 else { throw CodecError.unsupportedFormat }
            return payload
        } catch let e as CodecError { throw e } catch { throw CodecError.wrongPasswordOrCorrupt }
    }

    private static func deriveKey(password: String, salt: Data) throws -> SymmetricKey {
        var key = Data(count: 32)
        let pw = Array(password.utf8)
        let rc = key.withUnsafeMutableBytes { k in
            salt.withUnsafeBytes { s in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw.map { Int8(bitPattern: $0) }, pw.count,
                                     s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                                     k.bindMemory(to: UInt8.self).baseAddress, 32)
            }
        }
        guard rc == kCCSuccess else { throw CodecError.wrongPasswordOrCorrupt }
        return SymmetricKey(data: key)
    }
}
```

Payload CodingKeys snake_case (`format_version`, `model_version`, `person_key`, `display_name`, `speech_sec`). `VoiceImportQueries.buildExport/preview/apply` per the interface (preview reads only; apply in the caller's write transaction; `sender_email` stored lower-cased; `file_sha256` = `SHA256.hash(data:)` hex of the file bytes). Center export writes `seal` output to `url.appendingPathExtension("tmp")` then `FileManager.replaceItemAt`/move to `url` (atomic rename). `VoiceImportExportView`: an Export sheet (people checklist, default all, the owner included; password + confirmation; `NSSavePanel` with `.wtvoices`), an Import sheet (`NSOpenPanel`, password, preview summary with merges / new / conflicts / skipped-owner / mismatch, "Import" disabled on mismatch or duplicate). Both sheets are opened from `VoiceReviewView`.

- [ ] **Step 4: Run** — `make test-swift FILTER='VoiceExportCodecTests|VoiceImportTests'` → PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(desktop): encrypted voice print import/export"`

---

### Task 16: Docs, research seed hand-off, gate

**Files:**
- Modify: `CLAUDE.md` (Meeting Transcriber → replace the voice-print/speaker-guess sentences of "Speaker roles (v75+)" with a "Voice registry (2026-09-28)" bullet), `docs/app-guide.md` (Voices window, tray items, Settings toggles, Transcript "Listen to samples"), `docs/superpowers/specs/2026-07-31-transcript-stack-design.md` (§D3: note that exporting voice prints is superseded by the voice-registry spec; "Suggest speaker names" removed)

- [ ] **Step 1: Write the docs** — CLAUDE.md bullet (≤ 12 lines): tables, bands and thresholds live in `VoiceRegistryPolicy`, invariants 1–5, retro only `label_source: none`, pending imports only suggest, `.wtvoices` AES-GCM/PBKDF2, `speaker_guess` removed, the model-version literal dual-path (migration 00077 ↔ `VoiceRegistryPolicy.embeddingModelVersion`), tests `VoiceMatcherTests`/`VoiceRetroRelabelerTests` as the guards.
- [ ] **Step 2: Gate**

Run each with its own log and explicit exit code (never through `tail`):
```bash
make test > /tmp/vr-go.log 2>&1; echo "go exit=$?"
make test-swift > /tmp/vr-swift.log 2>&1; echo "swift exit=$?"
make lint-all > /tmp/vr-lint.log 2>&1; echo "lint exit=$?"
```
Expected: all `exit=0`. Swift XCTest failures appear above the swift-testing summary — grep the log for `error:` and `failed`.

- [ ] **Step 3: Manual checklist (owner)** — record a short meeting with an event → notification "N voices — who is this?" → label in the Voices window → an older recording of the same person shows the name → Recording shows "Speaker names were updated — regenerate the recap?" → Review → Export to a file → Import into a second workspace DB → the voice is suggested as "From an imported file" → Confirm.

- [ ] **Step 4: Research seed (owner-run, outside the repo)** — after this branch merges and migration 00077 is applied, the owner's private research labels are seeded by a one-off script kept in the owner's private archive (it reads live data and must never be committed): dry-run report (people, samples, merges with existing persons by email) → apply with a DB backup, inserting `origin='owner', anchor=1, status='active'` samples at the current model version, then `VoiceRetroRelabeler` runs on the next app launch. Not part of this plan's commits.

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md docs
git commit -m "docs: voice registry notes, app guide, transcript-stack spec supersession"
```

---

## Self-Review

- **Spec coverage:** §1 data model → T1, T3, T4; §1.6 invariants → T3 (matcher), T4 (`insertAuto` precondition), T6 (anchor), T8 (reserved/owner), T9 (retro scope), T15 (export/import); §1.7 migration → T1 (existing prints), T16 Step 4 (research seed); §2 pipeline → T5, T6, T7; §3 window/queue/review/removal → T8, T11, T12, T13; §4.1 retro → T9, T11 (`catchUp`); §4.2 train → T14; §4.3 rollback → T10; §5 import/export → T15; §6 errors/tests/rollout → per-task tests, T7 (settings keys, failure path), T12 (toggles), T16 (gate, manual).
- **Placeholders:** the compactly-described tests in T8/T9/T10/T11/T13/T14/T15 are explicitly required to be written in full by the executor; no TBD/TODO remain.
- **Type consistency:** `VoiceMatcher.Decision`, `VoiceLabelReason` raw values, `VoiceSample` fields, `relabelCluster(…patch:)`, `VoiceRegistrySnapshot`, `VoiceIdentificationOutcome`, `VoiceCard`/`PersonChoice`, `VoiceExportPayload` are used with the same names across tasks.
- **Review Focus:** items 1–5 are pinned in T3 (`testOnePersonAtMostOneConfidentClusterPerRecording`, `testRetiredAndOtherModelAndCorruptSamplesAreIgnored`), T9 (`testRelabelsOnlyUnnamedClusters…` keeps «Я»), T7 (`testOwnerClusterIsNeverRenamedByTheRegistry`), T4 (`testPersonIDsMatchByEmailOrDisplayName`), T8 (`testConfirmOnStaleTaskReportsAlreadyLabeledWithoutWriting`).
