package sources

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/hub/secure"
	hubslices "watchtower/internal/hub/slices"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/wire"
)

// The meeting_transcript slice's caps (MeetingTranscriptSlice).
const (
	maxTranscripts      = 200
	transcriptWindow    = 30 * 24 * time.Hour
	maxRecapEntries     = 50
	maxRecapEntryLength = 500
	maxTranscriptSpeak  = 20
	maxTranscriptTitle  = 300
	maxOverview         = 2000
	// maxSegmentsAsset is the segments.json cap: 20 MB.
	maxSegmentsAsset = 20 * 1024 * 1024
	// transcriptSettle: a row whose updated_at is this recent may still
	// change within the same stored second, so its light key is not trusted.
	transcriptSettle = 2 * time.Second
)

// TranscriptOptions wires the meeting_transcript source. AssetDir (required)
// is where the sealed segments.json files are staged (0700); it must be a
// dedicated directory, the first call sweeps its *.asset files; Store (nil =
// none) gives a phone upload's id (the done recording_jobs row holding the
// transcript); Now and Location are the calendar window's.
type TranscriptOptions struct {
	CalendarOptions
	AssetDir string
	Store    *state.Store
}

// MeetingTranscript is the meeting_transcript slice (MeetingTranscriptSlice,
// mobile POC spec §4.11), record meeting_transcript-<meeting_transcripts.id>:
// the recap fields in the payload, the transcript body as the record's
// sealed segments.json asset.
//
// Window: created in the last 30 days, or its event is in the calendar window
// (calendar_event's, whatever the transcript's age); at most 200, newest
// first. Recap: meeting_recaps joined by transcript_id first, then by the
// transcript's event_id; otherwise the transcript's own summary_json (ad-hoc
// recordings). Never read, so never published: audio_path, speakers_json
// (voice embeddings), notes_md and the chapters other than overall_summary.
//
// Private recordings publish like any other: MEETPRIV protects the readers
// that feed prompts, and the phone is the owner's own end-to-end encrypted
// view (the Swift twin publishes them too).
//
// An unchanged transcript is neither read in full nor sealed again: its
// record is kept while a light key (small columns, the big columns' lengths,
// the candidate recaps, the phone id) and its staged file hold; a changed
// light key re-reads the row and keeps the record while the full
// fingerprint (SHA-256 of the raw columns) holds.
func MeetingTranscript(d *db.DB, o TranscriptOptions) (hubslices.Source, error) {
	if d == nil {
		return nil, errors.New("hub slices: meeting_transcript needs the database")
	}
	if o.AssetDir == "" {
		return nil, errors.New("hub slices: meeting_transcript needs an asset directory")
	}
	return &transcriptSource{d: d, o: o, cache: map[int64]*transcriptEntry{}, warns: newWarnings(), maxAsset: maxSegmentsAsset}, nil
}

type transcriptSource struct {
	d        *db.DB
	o        TranscriptOptions
	warns    *warnings
	maxAsset int

	mu    sync.Mutex // one Items at a time; guards cache and stale
	cache map[int64]*transcriptEntry
	stale []string
	swept bool

	builds, fullReads, recapReads atomic.Int64
}

func (*transcriptSource) Kind() hubslices.Kind { return "meeting_transcript" }

// transcriptEntry is one transcript's derived record.
type transcriptEntry struct {
	fingerprint []byte
	light       []byte // nil: read it in full
	payload     []byte
	desc        secure.AssetDescriptor
	path        string
}

// transcriptPayload is the Kit mirror WatchtowerKit.MeetingTranscript.
type transcriptPayload struct {
	ID                int64    `json:"id"`
	EventID           *string  `json:"event_id,omitempty"`
	Title             string   `json:"title"`
	TitleClipped      *bool    `json:"title_clipped,omitempty"`
	DurationSec       int      `json:"duration_sec"`
	CreatedAt         string   `json:"created_at"`
	UpdatedAt         string   `json:"updated_at"`
	PhoneRecordingID  *string  `json:"phone_recording_id,omitempty"`
	Speakers          []string `json:"speakers"`
	SpeakersMore      *int     `json:"speakers_more,omitempty"`
	Summary           *string  `json:"summary,omitempty"`
	KeyDecisions      []string `json:"key_decisions"`
	KeyDecisionsMore  *int     `json:"key_decisions_more,omitempty"`
	ActionItems       []string `json:"action_items"`
	ActionItemsMore   *int     `json:"action_items_more,omitempty"`
	OpenQuestions     []string `json:"open_questions"`
	OpenQuestionsMore *int     `json:"open_questions_more,omitempty"`
	Overview          *string  `json:"overview,omitempty"`
	OverviewClipped   *bool    `json:"overview_clipped,omitempty"`
	SegmentsClipped   *bool    `json:"segments_clipped,omitempty"`
}

// segment is one segments.json entry: {start_sec, end_sec, speaker, text}.
type segment struct {
	StartSec float64 `json:"start_sec"`
	EndSec   float64 `json:"end_sec"`
	Speaker  string  `json:"speaker"`
	Text     string  `json:"text"`
}

// transcriptRow is a meeting_transcripts row as the projection reads it.
type transcriptRow struct {
	id                        int64
	eventID                   *string
	title                     string
	durationSec               int
	segmentsJSON, legacyText  *string
	summaryJSON, chaptersJSON *string
	createdAt, updatedAt      string
	lengths                   [4]sql.NullInt64
}

type recapRef struct {
	id        int64
	updatedAt string
}

type recapIndex struct {
	byTranscript map[int64][]recapRef
	byEvent      map[string][]recapRef
}

// candidates is a transcript's recaps in precedence order: its own, then its event's.
func (r recapIndex) candidates(id int64, eventID *string) []recapRef {
	out := append([]recapRef(nil), r.byTranscript[id]...)
	if eventID != nil {
		out = append(out, r.byEvent[*eventID]...)
	}
	return out
}

type transcriptBuild struct {
	row         transcriptRow
	recaps      []recapRef
	recapJSON   []string // same order as recaps
	phone       *string
	fingerprint []byte
	light       []byte
}

type plannedTranscript struct {
	entry *transcriptEntry // reused
	build *transcriptBuild
}

func (s *transcriptSource) Items(ctx context.Context) ([]hubslices.Item, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.prepareDir(); err != nil {
		return nil, err
	}
	now := s.o.now()
	phones, err := s.phoneIDs(ctx)
	if err != nil {
		return nil, err
	}
	var (
		window  []int64
		planned = map[int64]plannedTranscript{}
	)
	err = readTx(ctx, s.d, func(tx *sql.Tx) error {
		var err error
		var eventIDs map[int64]*string
		window, eventIDs, err = s.window(ctx, tx, now)
		if err != nil {
			return err
		}
		recaps, err := s.recaps(ctx, tx, window, eventIDs)
		if err != nil {
			return err
		}
		keys, err := s.lightKeys(ctx, tx, window)
		if err != nil {
			return err
		}
		var unread []int64
		for _, k := range keys {
			cands := recaps.candidates(k.id, k.eventID)
			light := lightFingerprint(k, cands, phones[k.id])
			hit := s.cache[k.id]
			if hit != nil && settled(k.updatedAt, now) && equalBytes(hit.light, light) && fileExists(hit.path) {
				planned[k.id] = plannedTranscript{entry: hit}
			} else {
				unread = append(unread, k.id)
			}
		}
		s.fullReads.Add(int64(len(unread)))
		rows, err := s.rows(ctx, tx, unread)
		if err != nil {
			return err
		}
		var builds []*transcriptBuild
		for _, row := range rows {
			cands := recaps.candidates(row.id, row.eventID)
			phone := phones[row.id]
			fp := fingerprint(row, cands, phone)
			var light []byte
			if settled(row.updatedAt, now) {
				light = lightFingerprint(row, cands, phone)
			}
			if hit := s.cache[row.id]; hit != nil && equalBytes(hit.fingerprint, fp) && fileExists(hit.path) {
				hit.light = light
				planned[row.id] = plannedTranscript{entry: hit}
				continue
			}
			builds = append(builds, &transcriptBuild{row: row, recaps: cands, phone: phone, fingerprint: fp, light: light})
		}
		ids := map[int64]bool{}
		for _, b := range builds {
			for _, r := range b.recaps {
				ids[r.id] = true
			}
		}
		json, err := s.recapJSON(ctx, tx, ids)
		if err != nil {
			return err
		}
		s.recapReads.Add(int64(len(json)))
		for _, b := range builds {
			for _, r := range b.recaps {
				b.recapJSON = append(b.recapJSON, json[r.id])
			}
			planned[b.row.id] = plannedTranscript{build: b}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	var items []hubslices.Item
	for _, id := range window {
		p, ok := planned[id]
		if !ok {
			continue
		}
		e := p.entry
		if p.build != nil {
			if e, err = s.build(p.build); err != nil {
				return nil, err
			}
			if old := s.cache[id]; old != nil && old.path != e.path {
				s.stale = append(s.stale, old.path)
			}
			s.cache[id] = e
			s.builds.Add(1)
		}
		desc := e.desc
		items = append(items, hubslices.Item{ID: strconv.FormatInt(id, 10), Payload: append([]byte(nil), e.payload...), Asset: &desc, AssetPath: e.path})
	}
	s.prune(window)
	return items, nil
}

// prepareDir creates the staging directory and, once, removes the sealed
// files an earlier process left behind.
func (s *transcriptSource) prepareDir() error {
	if err := os.MkdirAll(s.o.AssetDir, 0o700); err != nil {
		return fmt.Errorf("hub slices: asset directory: %w", err)
	}
	for _, p := range s.stale {
		_ = os.Remove(p)
	}
	s.stale = nil
	if s.swept {
		return nil
	}
	s.swept = true
	old, _ := filepath.Glob(filepath.Join(s.o.AssetDir, "*.asset"))
	for _, p := range old {
		_ = os.Remove(p)
	}
	tmp, _ := filepath.Glob(filepath.Join(s.o.AssetDir, ".asset-*.tmp"))
	for _, p := range tmp {
		_ = os.Remove(p)
	}
	return nil
}

// prune forgets transcripts that left the window; their files go at the next call.
func (s *transcriptSource) prune(window []int64) {
	keep := make(map[int64]bool, len(window))
	for _, id := range window {
		keep[id] = true
	}
	for id, e := range s.cache {
		if !keep[id] {
			s.stale = append(s.stale, e.path)
			delete(s.cache, id)
		}
	}
}

// phoneIDs is transcript id → the phone upload that made it.
func (s *transcriptSource) phoneIDs(ctx context.Context) (map[int64]*string, error) {
	out := map[int64]*string{}
	if s.o.Store == nil {
		return out, nil
	}
	jobs, err := s.o.Store.RecordingJobs(ctx)
	if err != nil {
		return nil, err
	}
	for _, j := range jobs {
		if j.Status == state.RecordingDone && j.TranscriptID != nil {
			id := j.UploadID
			out[*j.TranscriptID] = &id
		}
	}
	return out, nil
}

// window is the window's transcripts, newest first and
// their event ids.
func (s *transcriptSource) window(ctx context.Context, tx *sql.Tx, now time.Time) ([]int64, map[int64]*string, error) {
	events, err := calendarWindowEventIDs(ctx, tx, now, s.o.loc())
	if err != nil {
		return nil, nil, err
	}
	clause := ""
	args := []any{isoStamp(now.Add(-transcriptWindow))}
	if len(events) > 0 {
		ph, a := inListStrings(events)
		clause = " OR event_id IN (" + ph + ")"
		args = append(args, a...)
	}
	var ids []int64
	eventIDs := map[int64]*string{}
	err = scanRows(ctx, tx, `SELECT id, event_id FROM meeting_transcripts
		WHERE (created_at >= ?`+clause+`)
		ORDER BY created_at DESC, id DESC LIMIT `+strconv.Itoa(maxTranscripts), args, func(r *sql.Rows) error {
		var id int64
		var ev sql.NullString
		if err := r.Scan(&id, &ev); err != nil {
			return err
		}
		ids = append(ids, id)
		if ev.Valid {
			e := ev.String
			eventIDs[id] = &e
		}
		return nil
	})
	return ids, eventIDs, err
}

// recaps is the non-empty meeting_recaps rows of the window's
// transcripts (id and updated_at only), by transcript_id and by event_id.
func (s *transcriptSource) recaps(ctx context.Context, tx *sql.Tx, ids []int64, eventIDs map[int64]*string) (recapIndex, error) {
	out := recapIndex{byTranscript: map[int64][]recapRef{}, byEvent: map[string][]recapRef{}}
	if len(ids) == 0 {
		return out, nil
	}
	ph, args := inList(ids)
	seen := map[string]bool{}
	var events []string
	for _, e := range eventIDs {
		if e != nil && !seen[*e] {
			seen[*e] = true
			events = append(events, *e)
		}
	}
	clause := ""
	if len(events) > 0 {
		eph, eargs := inListStrings(events)
		clause = " OR r.event_id IN (" + eph + ")"
		args = append(args, eargs...)
	}
	err := scanRows(ctx, tx, `SELECT r.id, r.event_id, r.transcript_id, r.updated_at FROM meeting_recaps r
		WHERE (r.transcript_id IN (`+ph+`)`+clause+`)
		  AND r.recap_json IS NOT NULL AND r.recap_json != ''
		ORDER BY r.updated_at DESC, r.id DESC`, args, func(r *sql.Rows) error {
		var ref recapRef
		var ev sql.NullString
		var tid sql.NullInt64
		if err := r.Scan(&ref.id, &ev, &tid, &ref.updatedAt); err != nil {
			return err
		}
		if tid.Valid {
			out.byTranscript[tid.Int64] = append(out.byTranscript[tid.Int64], ref)
		}
		if ev.Valid {
			out.byEvent[ev.String] = append(out.byEvent[ev.String], ref)
		}
		return nil
	})
	return out, err
}

func (s *transcriptSource) recapJSON(ctx context.Context, tx *sql.Tx, ids map[int64]bool) (map[int64]string, error) {
	out := map[int64]string{}
	if len(ids) == 0 {
		return out, nil
	}
	list := make([]int64, 0, len(ids))
	for id := range ids {
		list = append(list, id)
	}
	ph, args := inList(list)
	err := scanRows(ctx, tx, `SELECT id, recap_json FROM meeting_recaps WHERE id IN (`+ph+`)`, args, func(r *sql.Rows) error {
		var id int64
		var js sql.NullString
		if err := r.Scan(&id, &js); err != nil {
			return err
		}
		if js.Valid {
			out[id] = js.String
		}
		return nil
	})
	return out, err
}

const lengthColumns = `octet_length(segments_json), octet_length(transcript_text), octet_length(summary_json), octet_length(chapters_json)`

// lightKeys are the window rows' light keys: no big column leaves SQLite.
func (s *transcriptSource) lightKeys(ctx context.Context, tx *sql.Tx, ids []int64) ([]transcriptRow, error) {
	if len(ids) == 0 {
		return nil, nil
	}
	ph, args := inList(ids)
	var out []transcriptRow
	err := scanRows(ctx, tx, `SELECT id, event_id, title, duration_sec, created_at, updated_at, `+lengthColumns+`
		FROM meeting_transcripts WHERE id IN (`+ph+`)`, args, func(r *sql.Rows) error {
		var t transcriptRow
		var ev sql.NullString
		if err := r.Scan(&t.id, &ev, &t.title, &t.durationSec, &t.createdAt, &t.updatedAt,
			&t.lengths[0], &t.lengths[1], &t.lengths[2], &t.lengths[3]); err != nil {
			return err
		}
		t.eventID = nullPtr(ev)
		out = append(out, t)
		return nil
	})
	return out, err
}

// rows reads the projection's columns of ids, in the window's order.
func (s *transcriptSource) rows(ctx context.Context, tx *sql.Tx, ids []int64) ([]transcriptRow, error) {
	if len(ids) == 0 {
		return nil, nil
	}
	ph, args := inList(ids)
	var out []transcriptRow
	err := scanRows(ctx, tx, `SELECT id, event_id, title, duration_sec, segments_json, summary_json, chapters_json, created_at, updated_at,
		CASE WHEN segments_json IS NULL OR NOT json_valid(segments_json) THEN transcript_text END, `+lengthColumns+`
		FROM meeting_transcripts WHERE id IN (`+ph+`) ORDER BY created_at DESC, id DESC`, args, func(r *sql.Rows) error {
		var t transcriptRow
		var ev, seg, sum, ch, legacy sql.NullString
		if err := r.Scan(&t.id, &ev, &t.title, &t.durationSec, &seg, &sum, &ch, &t.createdAt, &t.updatedAt, &legacy,
			&t.lengths[0], &t.lengths[1], &t.lengths[2], &t.lengths[3]); err != nil {
			return err
		}
		t.eventID, t.segmentsJSON, t.summaryJSON = nullPtr(ev), nullPtr(seg), nullPtr(sum)
		t.chaptersJSON, t.legacyText = nullPtr(ch), nullPtr(legacy)
		out = append(out, t)
		return nil
	})
	return out, err
}

func nullPtr(n sql.NullString) *string {
	if !n.Valid {
		return nil
	}
	return &n.String
}

func settled(updatedAt string, now time.Time) bool {
	t := parseDate(updatedAt)
	return t != nil && now.Sub(t.Time) >= transcriptSettle
}

func fileExists(p string) bool {
	_, err := os.Stat(p)
	return err == nil
}

func equalBytes(a, b []byte) bool { return a != nil && string(a) == string(b) }

// lightFingerprint covers every column the record is derived from, the big
// ones by their length only. A writer that changes a big column bumps
// updated_at, and a same-second rewrite of the same length is caught by the
// settle time.
func lightFingerprint(k transcriptRow, recaps []recapRef, phone *string) []byte {
	f := []*string{
		sp(strconv.FormatInt(k.id, 10)), k.eventID, sp(k.title), sp(strconv.Itoa(k.durationSec)), sp(k.createdAt), sp(k.updatedAt),
	}
	for _, l := range k.lengths {
		if l.Valid {
			f = append(f, sp(strconv.FormatInt(l.Int64, 10)))
		} else {
			f = append(f, nil)
		}
	}
	return digest(append(append(f, recapFields(recaps)...), phone))
}

// fingerprint is SHA-256 over everything the record is derived from.
func fingerprint(r transcriptRow, recaps []recapRef, phone *string) []byte {
	f := []*string{
		sp(strconv.FormatInt(r.id, 10)), r.eventID, sp(r.title), sp(strconv.Itoa(r.durationSec)), sp(r.createdAt), sp(r.updatedAt),
		r.segmentsJSON, r.legacyText, r.summaryJSON, r.chaptersJSON,
	}
	return digest(append(append(f, recapFields(recaps)...), phone))
}

// recapFields: the candidates' count, then each one's id and updated_at. Any
// candidate's change rebuilds the row (which one is readable is known only
// once decoded).
func recapFields(recaps []recapRef) []*string {
	f := []*string{sp(strconv.Itoa(len(recaps)))}
	for _, r := range recaps {
		f = append(f, sp(strconv.FormatInt(r.id, 10)), sp(r.updatedAt))
	}
	return f
}

func sp(s string) *string { return &s }

// digest is SHA-256 over fields, each tagged (nil vs present) and
// length-prefixed, so no two inputs collide.
func digest(fields []*string) []byte {
	h := sha256.New()
	for _, f := range fields {
		if f == nil {
			h.Write([]byte{0})
			continue
		}
		var n [8]byte
		binary.LittleEndian.PutUint64(n[:], uint64(len(*f)))
		h.Write([]byte{1})
		h.Write(n[:])
		h.Write([]byte(*f))
	}
	return h.Sum(nil)
}

// --- build ---

func (s *transcriptSource) build(b *transcriptBuild) (*transcriptEntry, error) {
	row := b.row
	segs := s.segments(row)
	plain, clipped := encodeSegments(segs, s.maxAsset)
	var recap *recapContent
	for i, js := range b.recapJSON {
		if recap = s.decodeRecap(js, "meeting recap", b.recaps[i].id); recap != nil {
			break
		}
	}
	if recap == nil && row.summaryJSON != nil {
		recap = s.decodeRecap(*row.summaryJSON, "summary_json of transcript", row.id)
	}
	payload, err := wire.Marshal(s.payload(row, recap, b.phone, speakersOf(segs), clipped))
	if err != nil {
		return nil, err
	}
	path, desc, err := s.sealAsset(row.id, plain)
	if err != nil {
		return nil, err
	}
	return &transcriptEntry{fingerprint: b.fingerprint, light: b.light, payload: payload, desc: desc, path: path}, nil
}

// utterance is one segments_json entry; every field but deleted is required.
type utterance struct {
	Idx      *int     `json:"idx"`
	StartSec *float64 `json:"start_sec"`
	EndSec   *float64 `json:"end_sec"`
	Speaker  *string  `json:"speaker"`
	Text     *string  `json:"text"`
	Deleted  *bool    `json:"deleted"`
}

// decodeUtterances is TranscriptSegments.decode: nil for malformed JSON, an
// entry missing a field, or an empty array.
func decodeUtterances(raw string) []utterance {
	var out []utterance
	if json.Unmarshal([]byte(raw), &out) != nil || len(out) == 0 {
		return nil
	}
	for _, u := range out {
		if u.Idx == nil || u.StartSec == nil || u.EndSec == nil || u.Speaker == nil || u.Text == nil {
			return nil
		}
	}
	return out
}

// segments are the non-deleted segments; a legacy row (no or unreadable
// segments_json) is one segment holding transcript_text. Valid JSON of
// another shape has no text to fall back on and publishes [].
func (s *transcriptSource) segments(r transcriptRow) []segment {
	if r.segmentsJSON != nil {
		if us := decodeUtterances(*r.segmentsJSON); us != nil {
			out := make([]segment, 0, len(us))
			for _, u := range us {
				if u.Deleted != nil && *u.Deleted {
					continue
				}
				out = append(out, segment{*u.StartSec, *u.EndSec, *u.Speaker, *u.Text})
			}
			return out
		}
		if *r.segmentsJSON != "[]" {
			// Logged per build, i.e. once per change of the row.
			log.Printf("hub slices: unreadable segments_json of transcript %d; published from the flat text", r.id)
		}
	}
	if r.legacyText == nil || *r.legacyText == "" {
		return nil
	}
	return []segment{{0, float64(r.durationSec), "", *r.legacyText}}
}

// speakersOf is the display names in order of first appearance; "" (not
// diarized) is no speaker.
func speakersOf(segs []segment) []string {
	seen := map[string]bool{}
	var out []string
	for _, s := range segs {
		if s.Speaker != "" && !seen[s.Speaker] {
			seen[s.Speaker] = true
			out = append(out, s.Speaker)
		}
	}
	return out
}

// encodeSegments is the asset's JSON array, cut after the last whole segment
// that fits maxBytes (the closing bracket included). Assembled element by
// element: the same bytes as encoding the array.
func encodeSegments(segs []segment, maxBytes int) ([]byte, *bool) {
	data := []byte("[")
	var clipped *bool
	for i, sg := range segs {
		el, err := wire.Marshal(sg)
		if err != nil {
			continue // a float JSON cannot hold; never produced by a decoded row
		}
		sep := 0
		if i > 0 {
			sep = 1
		}
		if len(data)+sep+len(el)+1 > maxBytes {
			t := true
			clipped = &t
			break
		}
		if sep == 1 {
			data = append(data, ',')
		}
		data = append(data, el...)
	}
	return append(data, ']'), clipped
}

type recapContent struct {
	summary                              string
	keyDecisions, actions, openQuestions []string
}

// decodeRecap is MeetingRecap.Content's decode: nil for NULL or empty, and
// for a value missing a field or of another type (logged once, id only).
func (s *transcriptSource) decodeRecap(js, what string, id int64) *recapContent {
	if js == "" {
		return nil
	}
	var r struct {
		Summary       *string    `json:"summary"`
		KeyDecisions  *[]*string `json:"key_decisions"`
		ActionItems   *[]*string `json:"action_items"`
		OpenQuestions *[]*string `json:"open_questions"`
	}
	list := func(p *[]*string) ([]string, bool) {
		if p == nil {
			return nil, false
		}
		out := make([]string, 0, len(*p))
		for _, e := range *p {
			if e == nil {
				return nil, false
			}
			out = append(out, *e)
		}
		return out, true
	}
	if json.Unmarshal([]byte(js), &r) == nil && r.Summary != nil {
		d, ok1 := list(r.KeyDecisions)
		a, ok2 := list(r.ActionItems)
		q, ok3 := list(r.OpenQuestions)
		if ok1 && ok2 && ok3 {
			return &recapContent{*r.Summary, d, a, q}
		}
	}
	s.warns.warn(what, strconv.FormatInt(id, 10), "", js)
	return nil
}

func (s *transcriptSource) payload(r transcriptRow, recap *recapContent, phone *string, speakers []string, segClipped *bool) transcriptPayload {
	title, titleClipped := clipText(r.title, maxTranscriptTitle)
	sp, spMore := clipList(speakers, maxTranscriptSpeak)
	p := transcriptPayload{
		ID: r.id, EventID: r.eventID, Title: title, TitleClipped: titleClipped, DurationSec: r.durationSec,
		CreatedAt: r.createdAt, UpdatedAt: r.updatedAt, PhoneRecordingID: phone,
		Speakers: nonNil(sp), SpeakersMore: spMore, SegmentsClipped: segClipped,
		KeyDecisions: []string{}, ActionItems: []string{}, OpenQuestions: []string{},
	}
	if recap != nil {
		p.Summary = &recap.summary
		p.KeyDecisions, p.KeyDecisionsMore = recapList(recap.keyDecisions)
		p.ActionItems, p.ActionItemsMore = recapList(recap.actions)
		p.OpenQuestions, p.OpenQuestionsMore = recapList(recap.openQuestions)
	}
	if ov := s.overview(r); ov != "" {
		text, clipped := clipText(ov, maxOverview)
		p.Overview, p.OverviewClipped = &text, clipped
	}
	return p
}

// recapList is at most 50 entries of at most 500.
func recapList(entries []string) ([]string, *int) {
	kept, more := clipList(entries, maxRecapEntries)
	out := make([]string, 0, len(kept))
	for _, e := range kept {
		t, _ := clipText(e, maxRecapEntryLength)
		out = append(out, t)
	}
	return out, more
}

// overview is chapters_json.overall_summary; "" when absent, empty or
// unreadable (logged).
func (s *transcriptSource) overview(r transcriptRow) string {
	if r.chaptersJSON == nil || *r.chaptersJSON == "" {
		return ""
	}
	var ch struct {
		Overall  *string           `json:"overall_summary"`
		Chapters []json.RawMessage `json:"chapters"`
	}
	if json.Unmarshal([]byte(*r.chaptersJSON), &ch) != nil {
		log.Printf("hub slices: unreadable chapters_json of transcript %d; no overview", r.id)
		return ""
	}
	if ch.Overall == nil {
		return ""
	}
	return *ch.Overall
}

// sealAsset seals plain under a fresh key and stages it beside the others
// (0600, written to a temp file and renamed). The file name carries the
// plaintext digest, so a changed asset is a new file.
func (s *transcriptSource) sealAsset(id int64, plain []byte) (string, secure.AssetDescriptor, error) {
	var assetID secure.ID
	key := make([]byte, 32)
	defer clear(key)
	if _, err := rand.Read(assetID[:]); err != nil {
		return "", secure.AssetDescriptor{}, fmt.Errorf("hub slices: asset id: %w", err)
	}
	if _, err := rand.Read(key); err != nil {
		return "", secure.AssetDescriptor{}, fmt.Errorf("hub slices: asset key: %w", err)
	}
	sealed, desc, err := secure.EncryptAsset(plain, assetID, key, secure.ChunkSize)
	if err != nil {
		return "", secure.AssetDescriptor{}, fmt.Errorf("hub slices: sealing the segments: %w", err)
	}
	path := filepath.Join(s.o.AssetDir, strconv.FormatInt(id, 10)+"-"+hex.EncodeToString(desc.PlaintextDigest[:6])+".asset")
	tmp, err := os.CreateTemp(s.o.AssetDir, ".asset-*.tmp")
	if err != nil {
		return "", secure.AssetDescriptor{}, fmt.Errorf("hub slices: staging the segments: %w", err)
	}
	_, werr := tmp.Write(sealed)
	cerr := tmp.Close()
	if err := errors.Join(werr, cerr); err != nil {
		_ = os.Remove(tmp.Name())
		return "", secure.AssetDescriptor{}, fmt.Errorf("hub slices: staging the segments: %w", err)
	}
	if err := os.Rename(tmp.Name(), path); err != nil {
		_ = os.Remove(tmp.Name())
		return "", secure.AssetDescriptor{}, fmt.Errorf("hub slices: staging the segments: %w", err)
	}
	return path, desc, nil
}
