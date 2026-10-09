package cmd

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"slices"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/meeting"
	"watchtower/internal/prompts"

	"github.com/spf13/cobra"
)

var (
	transcriptSaveFlagFile      string
	transcriptSaveFlagSegments  string
	transcriptSaveFlagSpeakers  string
	transcriptSaveFlagAudio     string
	transcriptSaveFlagEventID   string
	transcriptSaveFlagTitle     string
	transcriptSaveFlagLangStats string
	transcriptSaveFlagDuration  int
	transcriptListFlagEventID   string
	transcriptFollowupChapter   int
)

// minRecapTranscriptChars gates the automatic recap (and chapters) generation
// at save time: Whisper on near-silent audio hallucinates short phrases, and
// GenerateTranscriptRecap injects the calendar event's description into the
// prompt — so a near-empty transcript makes the model "recap" the event
// description instead of the meeting. The explicit `transcript recap <id>`
// retry command stays ungated (an explicit user request always generates).
const minRecapTranscriptChars = 200

// transcriptGeneratorFactory is the seam tests override to inject a mock
// generator (same pattern as newDayPlanPipelineFactory).
var transcriptGeneratorFactory = func(cfg *config.Config) digest.Generator {
	return cliGenerator(cfg)
}

// insertMeetingTranscript is the seam tests override to act between save's
// event lookup and its insert (the deleted-meanwhile window).
var insertMeetingTranscript = func(database *db.DB, tr db.MeetingTranscript) (int64, error) {
	return database.InsertMeetingTranscript(tr)
}

var meetingTranscriptCmd = &cobra.Command{
	Use:   "transcript",
	Short: "Manage meeting transcripts",
	Long:  "Persist locally-transcribed meeting recordings, generate AI recaps for them, and inspect saved transcripts.",
}

var transcriptSaveCmd = &cobra.Command{
	Use:   "save",
	Short: "Save a transcript and generate its recap",
	Long: "Reads the transcript text from --transcript-file, persists a meeting_transcripts row, then generates the AI recap. " +
		"Exits 0 whenever the transcript row was saved — even if the recap failed (recap_ok=false, recap_error set in the JSON envelope); exits 1 only when nothing was persisted.",
	RunE: runTranscriptSave,
}

var transcriptRecapCmd = &cobra.Command{
	Use:   "recap <id>",
	Short: "Regenerate the recap for a saved transcript",
	Long:  "Retry path for a transcript whose recap failed at save time. Prints the same JSON envelope as save.",
	Args:  cobra.ExactArgs(1),
	RunE:  runTranscriptRecap,
}

var transcriptListCmd = &cobra.Command{
	Use:   "list",
	Short: "List saved transcripts as JSON",
	RunE:  runTranscriptList,
}

var transcriptShowCmd = &cobra.Command{
	Use:   "show <id>",
	Short: "Show one transcript (including full text) as JSON",
	Args:  cobra.ExactArgs(1),
	RunE:  runTranscriptShow,
}

var transcriptNotesCmd = &cobra.Command{
	Use:   "notes <id>",
	Short: "Generate publishable markdown meeting notes for a saved transcript",
	Long: "Runs the meeting.notes AI prompt over the transcript text and stores the result in meeting_transcripts.notes_md. " +
		"Prints {transcript_id, notes_md} on success; exits 1 on any failure (nothing is persisted on failure).",
	Args: cobra.ExactArgs(1),
	RunE: runTranscriptNotes,
}

var transcriptChaptersCmd = &cobra.Command{
	Use:   "chapters <id>",
	Short: "Generate meeting chapters for a saved transcript",
	Long: "Runs the meeting.chapters AI prompt over the transcript's per-utterance segments (timecodes + speakers) and stores the result in meeting_transcripts.chapters_json. " +
		"Requires persisted segments. Prints {transcript_id, chapters_json} on success; exits 1 on any failure (nothing is persisted on failure).",
	Args: cobra.ExactArgs(1),
	RunE: runTranscriptChapters,
}

var transcriptFollowupCmd = &cobra.Command{
	Use:   "followup <id>",
	Short: "Draft a follow-up message from a transcript's chapters",
	Long: "Runs the meeting.followup AI prompt (owner's voice via the workspace style profile) over one chapter's — or, without --chapter, the whole meeting's — decisions, action items, and open questions. " +
		"Requires generated chapters. Prints {transcript_id, chapter, draft}; nothing is ever persisted or sent. Exits 1 on any failure.",
	Args: cobra.ExactArgs(1),
	RunE: runTranscriptFollowup,
}

func init() {
	meetingPrepCmd.AddCommand(meetingTranscriptCmd)
	meetingTranscriptCmd.AddCommand(transcriptSaveCmd, transcriptRecapCmd, transcriptListCmd, transcriptShowCmd, transcriptNotesCmd, transcriptChaptersCmd, transcriptFollowupCmd)

	transcriptFollowupCmd.Flags().IntVar(&transcriptFollowupChapter, "chapter", -1, "0-based chapter index to draft for (omit for a whole-meeting draft)")

	transcriptSaveCmd.Flags().StringVar(&transcriptSaveFlagFile, "transcript-file", "", "path to the transcript text file (required)")
	transcriptSaveCmd.Flags().StringVar(&transcriptSaveFlagSegments, "segments-file", "", "path to the per-utterance segments JSON file (optional)")
	transcriptSaveCmd.Flags().StringVar(&transcriptSaveFlagSpeakers, "speakers-file", "", "path to the per-cluster speaker embeddings JSON file (optional)")
	transcriptSaveCmd.Flags().StringVar(&transcriptSaveFlagAudio, "audio", "", "path to the recorded audio file")
	transcriptSaveCmd.Flags().IntVar(&transcriptSaveFlagDuration, "duration", 0, "recording duration in seconds")
	transcriptSaveCmd.Flags().StringVar(&transcriptSaveFlagEventID, "event-id", "", "calendar event id to link the transcript to")
	transcriptSaveCmd.Flags().StringVar(&transcriptSaveFlagTitle, "title", "", "transcript title (defaults to the event title or a timestamp)")
	transcriptSaveCmd.Flags().StringVar(&transcriptSaveFlagLangStats, "lang-stats", "", "per-language duration stats JSON")

	transcriptListCmd.Flags().StringVar(&transcriptListFlagEventID, "event-id", "", "filter transcripts by calendar event id")
}

// transcriptEnv loads config and opens the workspace DB (runMeetingRecap boilerplate).
func transcriptEnv() (*config.Config, *db.DB, error) {
	cfg, err := config.Load(flagConfig)
	if err != nil {
		return nil, nil, fmt.Errorf("loading config: %w", err)
	}
	if flagWorkspace != "" {
		cfg.ActiveWorkspace = flagWorkspace
	}
	if err := cfg.ValidateWorkspace(); err != nil {
		return nil, nil, err
	}
	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return nil, nil, fmt.Errorf("opening database: %w", err)
	}
	return cfg, database, nil
}

func runTranscriptSave(cmd *cobra.Command, _ []string) error {
	if transcriptSaveFlagFile == "" {
		return fmt.Errorf("--transcript-file is required")
	}
	raw, err := os.ReadFile(transcriptSaveFlagFile)
	if err != nil {
		return fmt.Errorf("reading transcript file: %w", err)
	}
	text := strings.TrimSpace(string(raw))
	if text == "" {
		return fmt.Errorf("transcript file is empty")
	}

	cfg, database, err := transcriptEnv()
	if err != nil {
		return err
	}
	defer database.Close()

	// A queued recording can outlive its calendar event (calendar sync
	// deletes it while the job waits): a gone event is dropped with a
	// warning and the transcript saved as a plain recording, instead of
	// failing the event_id foreign key and losing it. A lookup error is
	// not "gone" and fails the save.
	title := transcriptSaveFlagTitle
	eventID := transcriptSaveFlagEventID
	if eventID != "" {
		ev, err := database.GetCalendarEventByID(eventID)
		if err != nil {
			return fmt.Errorf("looking up calendar event %s: %w", eventID, err)
		}
		if ev == nil {
			warnDroppedTranscriptEvent(cmd.ErrOrStderr(), eventID)
			eventID = ""
		} else if title == "" {
			title = ev.Title
		}
	}
	if title == "" {
		title = "Recording " + time.Now().Local().Format("2006-01-02 15:04")
	}

	segments, segmentsErr := loadTranscriptSegments(transcriptSaveFlagSegments, text, cmd.ErrOrStderr())
	speakers, speakersErr := loadTranscriptSpeakers(transcriptSaveFlagSpeakers, segments, cmd.ErrOrStderr())
	tr := db.MeetingTranscript{
		Title:          title,
		DurationSec:    transcriptSaveFlagDuration,
		LangStats:      transcriptSaveFlagLangStats,
		TranscriptText: text,
		SegmentsJSON:   segments,
		SpeakersJSON:   speakers,
	}
	if eventID != "" {
		tr.EventID = sql.NullString{String: eventID, Valid: true}
	}
	if transcriptSaveFlagAudio != "" {
		tr.AudioPath = sql.NullString{String: transcriptSaveFlagAudio, Valid: true}
	}
	id, err := insertMeetingTranscript(database, tr)
	if err != nil && tr.EventID.Valid && db.IsForeignKeyViolation(err) {
		// The event was deleted between the lookup and the insert: retry
		// once unlinked. The post-insert steps read the stored row's link.
		warnDroppedTranscriptEvent(cmd.ErrOrStderr(), eventID)
		tr.EventID = sql.NullString{}
		id, err = insertMeetingTranscript(database, tr)
	}
	if err != nil {
		return fmt.Errorf("persisting transcript: %w", err)
	}

	// The row is saved — from here on a recap failure must NOT flip the exit
	// code; it is reported inside the envelope instead.
	recapSkipped, chaptersOutcome, recapErr := runSaveGenerations(
		cmd.Context(), database, cfg, id, text, tr.SegmentsJSON.Valid, cmd.ErrOrStderr())
	return printTranscriptEnvelope(cmd, database, id, recapErr, segmentsErr, speakersErr, chaptersOutcome, recapSkipped)
}

// warnDroppedTranscriptEvent is save's one stderr line for an --event-id
// whose calendar event no longer exists.
func warnDroppedTranscriptEvent(errOut io.Writer, eventID string) {
	fmt.Fprintf(errOut, "warning: calendar event %s no longer exists (saving the transcript as a plain recording)\n", eventID)
}

// runSaveGenerations runs save's post-insert AI steps: the recap (unless the
// transcript is under minRecapTranscriptChars — the too-short skip) and,
// when segments were persisted and the recap wasn't skipped, the chapters
// pass. Returned values feed printTranscriptEnvelope verbatim.
func runSaveGenerations(ctx context.Context, database *db.DB, cfg *config.Config, id int64, text string, hasSegments bool, errOut io.Writer) (recapSkipped bool, chaptersOutcome *error, recapErr error) {
	recapSkipped = utf8.RuneCountInString(text) < minRecapTranscriptChars
	if recapSkipped {
		recapErr = fmt.Errorf("transcript too short (<%d chars): recap skipped", minRecapTranscriptChars)
	} else {
		recapErr = generateAndStoreTranscriptRecap(ctx, database, cfg, id, errOut)
	}
	// Chapters are generated automatically only when segments exist (they
	// carry the timecodes the chapterizer needs) and the recap wasn't
	// skipped for being too short (the same near-empty transcript has no
	// chapters worth extracting either). A failure leaves chapters_json
	// NULL; retry via `transcript chapters <id>`.
	if !recapSkipped && hasSegments {
		_, chaptersErr := generateAndStoreTranscriptChapters(ctx, database, cfg, id, errOut)
		chaptersOutcome = &chaptersErr
	}
	return recapSkipped, chaptersOutcome, recapErr
}

// loadTranscriptSegments reads and validates the optional --segments-file for
// save. Any problem — unreadable file, malformed JSON, or a render that does
// not reproduce the transcript text (the transcript_text = render(segments)
// invariant) — yields a NULL column with a stderr warning AND a non-nil error
// surfaced through the envelope's segments_ok/segments_error (the recap_ok
// precedent: stderr alone is discarded by ProcessCLIRunner on exit 0, and a
// render-mismatch drift between the Go and Swift renderers must not degrade
// invisibly). A missing flag (old callers, batch fallback failures) is not an
// error — nothing was attempted. The transcript save itself always succeeds
// (exit-0 envelope semantics are preserved).
func loadTranscriptSegments(path, transcriptText string, errOut io.Writer) (sql.NullString, error) {
	if path == "" {
		return sql.NullString{}, nil
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		err = fmt.Errorf("reading segments file: %v", err)
		fmt.Fprintf(errOut, "warning: %v (saving transcript without segments)\n", err)
		return sql.NullString{}, err
	}
	utterances, err := meeting.ParseTranscriptSegments(raw)
	if err != nil {
		fmt.Fprintf(errOut, "warning: %v (saving transcript without segments)\n", err)
		return sql.NullString{}, err
	}
	if rendered := meeting.RenderTranscriptSegments(utterances); rendered != transcriptText {
		err = fmt.Errorf("segments do not render to the transcript text")
		fmt.Fprintf(errOut, "warning: %v (saving transcript without segments)\n", err)
		return sql.NullString{}, err
	}
	return sql.NullString{String: strings.TrimSpace(string(raw)), Valid: true}, nil
}

// loadTranscriptSpeakers reads and validates the optional --speakers-file for
// save: the per-cluster voice embeddings the Desktop rename flow later folds
// into voice_prints. A whole-file problem — unreadable/malformed file or a
// segment-less save (labels would dangle) — yields a NULL column with a
// stderr warning AND a non-nil error surfaced through the envelope's
// speakers_ok/speakers_error (the segments_ok precedent: stderr alone is
// discarded by ProcessCLIRunner on exit 0). A label that matches no persisted
// utterance drops ONLY that orphan entry — the remaining embeddings are kept
// so one empty cluster never disables voice-print learning for the whole
// recording; the partial drop is still reported as speakers_ok=false. A
// missing flag (non-FluidAudio diarizers, old callers) is not an error —
// nothing was attempted. The transcript save itself always succeeds (the
// loadTranscriptSegments contract).
func loadTranscriptSpeakers(path string, segmentsJSON sql.NullString, errOut io.Writer) (sql.NullString, error) {
	if path == "" {
		return sql.NullString{}, nil
	}
	if !segmentsJSON.Valid {
		err := fmt.Errorf("speakers file without persisted segments")
		fmt.Fprintf(errOut, "warning: %v (saving transcript without speaker embeddings)\n", err)
		return sql.NullString{}, err
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		err = fmt.Errorf("reading speakers file: %v", err)
		fmt.Fprintf(errOut, "warning: %v (saving transcript without speaker embeddings)\n", err)
		return sql.NullString{}, err
	}
	speakers, rawEntries, err := meeting.ParseSpeakerEmbeddingsRaw(raw)
	if err != nil {
		fmt.Fprintf(errOut, "warning: %v (saving transcript without speaker embeddings)\n", err)
		return sql.NullString{}, err
	}
	utterances, err := meeting.ParseTranscriptSegments([]byte(segmentsJSON.String))
	if err != nil {
		fmt.Fprintf(errOut, "warning: %v (saving transcript without speaker embeddings)\n", err)
		return sql.NullString{}, err
	}
	labels := make(map[string]bool, len(utterances))
	for _, u := range utterances {
		labels[u.Speaker] = true
	}
	var keptRaw []json.RawMessage
	var dropped []string
	for i, s := range speakers {
		if !labels[s.Speaker] {
			dropped = append(dropped, s.Speaker)
			continue
		}
		keptRaw = append(keptRaw, rawEntries[i])
	}
	if len(dropped) == 0 {
		return sql.NullString{String: strings.TrimSpace(string(raw)), Valid: true}, nil
	}
	err = fmt.Errorf("dropped speaker embeddings matching no transcript utterance: %s", strings.Join(dropped, ", "))
	fmt.Fprintf(errOut, "warning: %v\n", err)
	if len(keptRaw) == 0 {
		fmt.Fprintf(errOut, "warning: no speaker embeddings left (saving transcript without speaker embeddings)\n")
		return sql.NullString{}, err
	}
	reencoded, encErr := json.Marshal(keptRaw)
	if encErr != nil {
		fmt.Fprintf(errOut, "warning: re-encoding speaker embeddings: %v (saving transcript without speaker embeddings)\n", encErr)
		return sql.NullString{}, err
	}
	return sql.NullString{String: string(reencoded), Valid: true}, err
}

func runTranscriptRecap(cmd *cobra.Command, args []string) error {
	id, err := strconv.ParseInt(args[0], 10, 64)
	if err != nil {
		return fmt.Errorf("invalid transcript id %q: %w", args[0], err)
	}

	cfg, database, err := transcriptEnv()
	if err != nil {
		return err
	}
	defer database.Close()

	if tr, err := database.GetMeetingTranscript(id); err != nil {
		return err
	} else if tr == nil {
		return fmt.Errorf("transcript %d not found", id)
	}

	// The recap retry is never gated by minRecapTranscriptChars — an explicit
	// user request always generates, regardless of transcript length.
	recapErr := generateAndStoreTranscriptRecap(cmd.Context(), database, cfg, id, cmd.ErrOrStderr())
	// The recap retry never touches segments or speakers — nothing attempted,
	// nothing dropped, so segments_ok/speakers_ok are honestly true. Chapters
	// are likewise not attempted here (nil ⇒ no chapters keys in the envelope).
	return printTranscriptEnvelope(cmd, database, id, recapErr, nil, nil, nil, false)
}

// generateAndStoreTranscriptRecap runs the AI recap for a saved transcript and
// stores it (see storeTranscriptRecap for where it lands). Shared by save
// and the `recap <id>` retry command. Bookkeeping failures (pipeline_runs)
// are logged to errOut and never affect the result.
func generateAndStoreTranscriptRecap(ctx context.Context, database *db.DB, cfg *config.Config, id int64, errOut io.Writer) error {
	if ctx == nil { // RunE invoked outside cobra's Execute (tests)
		ctx = context.Background()
	}
	tr, err := database.GetMeetingTranscript(id)
	if err != nil {
		return err
	}
	if tr == nil {
		return fmt.Errorf("transcript %d not found", id)
	}

	runID, err := database.CreatePipelineRun("meeting_transcript", "cli", "auto")
	if err != nil {
		fmt.Fprintf(errOut, "warning: recording meeting_transcript pipeline run: %v\n", err)
	}
	completeRun := func(items, in, out, api int, errMsg string) {
		if err := database.CompletePipelineRun(runID, items, in, out, 0, api, nil, nil, errMsg); err != nil {
			fmt.Fprintf(errOut, "warning: completing meeting_transcript pipeline run %d: %v\n", runID, err)
		}
	}
	pipe := meeting.New(database, cfg, transcriptGeneratorFactory(cfg), nil)
	pipe.SetPromptStore(prompts.New(database, nil))

	eventID := ""
	if tr.EventID.Valid {
		eventID = tr.EventID.String
	}
	res, usage, err := pipe.GenerateTranscriptRecap(ctx, eventID, tr.TranscriptText)
	if err != nil {
		completeRun(0, 0, 0, 0, err.Error())
		return err
	}

	recapJSON, err := json.Marshal(res)
	if err != nil {
		completeRun(0, 0, 0, 0, err.Error())
		return fmt.Errorf("marshalling recap: %w", err)
	}
	err = storeTranscriptRecap(database, tr, eventID, string(recapJSON), errOut)

	in, out, api := 0, 0, 0
	if usage != nil {
		in, out, api = usage.InputTokens, usage.OutputTokens, usage.TotalAPITokens
	}
	storeErrMsg := ""
	if err != nil {
		storeErrMsg = err.Error()
	}
	completeRun(1, in, out, api, storeErrMsg)
	return err
}

// storeTranscriptRecap writes a generated recap where the recording's Recap
// tab reads it (Swift RecordingDetailView resolves meeting_recaps by
// transcript_id, then by event_id, then falls back to summary_json):
//   - the recording's OWN meeting_recaps row (transcript_id = tr.ID, written by
//     an earlier save or copied from summary_json by Swift linkToEvent) is
//     refreshed in place. It is this recording's recap, never one the user
//     pasted (a paste rewrites transcript_id to NULL), so an explicit
//     `transcript recap <id>` — the recap-refresh hint's Regenerate — must
//     replace what is shown rather than hide the result in summary_json;
//   - otherwise the collision guard, mirroring Swift linkToEvent: a recap-less
//     event gets a new meeting_recaps row, while an event that already has one
//     (pasted, or another recording's) keeps it and the recap lands in
//     summary_json. On save the row is brand new, so only this branch applies.
//
// When the recap lands in meeting_recaps and the recording also holds its own
// summary_json copy, that copy (and its summary_updated_at stamp, which the
// Swift hint reads for such a row) is refreshed in the same transaction
// (db.WriteTranscriptRecap), so the two never diverge.
// A failed lookup falls back to summary_json with a warning — never an
// overwrite.
func storeTranscriptRecap(database *db.DB, tr *db.MeetingTranscript, eventID, recapJSON string, errOut io.Writer) error {
	own, err := database.GetMeetingRecapByTranscript(tr.ID)
	if err != nil {
		fmt.Fprintf(errOut, "warning: checking transcript %d's own recap (falling back to summary_json): %v\n", tr.ID, err)
		return database.SetMeetingTranscriptSummary(tr.ID, recapJSON)
	}
	row := db.TranscriptRecapRow{
		EventID: eventID, TranscriptID: tr.ID, SourceText: tr.TranscriptText,
		RecapJSON: recapJSON, SyncSummary: tr.SummaryJSON.Valid,
	}
	if own != nil {
		row.OwnRecapID = own.ID
	} else if eventID == "" || !eventHasNoRecap(database, eventID, errOut) {
		return database.SetMeetingTranscriptSummary(tr.ID, recapJSON)
	}
	return database.WriteTranscriptRecap(row)
}

// eventHasNoRecap reports whether the event has no meeting_recaps row yet. A
// lookup error counts as "has one" (logged), so the guard errs toward
// summary_json and never overwrites.
func eventHasNoRecap(database *db.DB, eventID string, errOut io.Writer) bool {
	existing, err := database.GetMeetingRecap(eventID)
	if err != nil {
		fmt.Fprintf(errOut, "warning: checking existing recap for %s (falling back to summary_json): %v\n", eventID, err)
		return false
	}
	return existing == nil
}

// printTranscriptEnvelope emits the frozen stdout contract consumed by the
// Swift TranscriptSaveService: transcript_id / recap_ok / recap_error /
// segments_ok / segments_error / speakers_ok / speakers_error (plus event_id
// and title for display). segments_ok=false means a provided --segments-file
// was dropped (the column stayed NULL) — the caller-visible tripwire for
// Go↔Swift renderer drift; speakers_ok=false means a provided --speakers-file
// was dropped or partially dropped (orphan labels). A
// failed post-save refetch must NOT flip the exit code — the row IS persisted
// (exit 1 only when nothing was persisted) — so it degrades to a minimal
// envelope built from what is known, logging the refetch problem to stderr.
// chaptersErr is nil when chapter generation was not attempted (no segments,
// a skipped recap, or the recap-only retry command); when non-nil the
// envelope additionally reports chapters_ok / chapters_error — additive
// keys, safe for the frozen Swift decoder. recapSkipped is true only when
// runTranscriptSave skipped recap generation for a too-short transcript
// (minRecapTranscriptChars); it adds the additive recap_skipped=true key —
// the `transcript recap <id>` retry (never gated) always passes false, so
// the key never appears in that envelope.
func printTranscriptEnvelope(cmd *cobra.Command, database *db.DB, id int64, recapErr, segmentsErr, speakersErr error, chaptersErr *error, recapSkipped bool) error {
	recapErrMsg := ""
	if recapErr != nil {
		recapErrMsg = recapErr.Error()
	}
	segmentsErrMsg := ""
	if segmentsErr != nil {
		segmentsErrMsg = segmentsErr.Error()
	}
	speakersErrMsg := ""
	if speakersErr != nil {
		speakersErrMsg = speakersErr.Error()
	}
	envelope := map[string]any{
		"transcript_id":  id,
		"recap_ok":       recapErr == nil,
		"recap_error":    recapErrMsg,
		"segments_ok":    segmentsErr == nil,
		"segments_error": segmentsErrMsg,
		"speakers_ok":    speakersErr == nil,
		"speakers_error": speakersErrMsg,
	}
	if recapSkipped {
		envelope["recap_skipped"] = true
	}
	if chaptersErr != nil {
		chaptersErrMsg := ""
		if *chaptersErr != nil {
			chaptersErrMsg = (*chaptersErr).Error()
		}
		envelope["chapters_ok"] = *chaptersErr == nil
		envelope["chapters_error"] = chaptersErrMsg
	}

	tr, err := database.GetMeetingTranscript(id)
	switch {
	case err != nil:
		fmt.Fprintf(cmd.ErrOrStderr(), "warning: re-loading transcript %d after save: %v\n", id, err)
	case tr == nil:
		fmt.Fprintf(cmd.ErrOrStderr(), "warning: transcript %d not found after save\n", id)
	default:
		eventID := ""
		if tr.EventID.Valid {
			eventID = tr.EventID.String
		}
		envelope["event_id"] = eventID
		envelope["title"] = tr.Title
	}

	enc := json.NewEncoder(cmd.OutOrStdout())
	enc.SetIndent("", "  ")
	return enc.Encode(envelope)
}

func runTranscriptList(cmd *cobra.Command, _ []string) error {
	_, database, err := transcriptEnv()
	if err != nil {
		return err
	}
	defer database.Close()

	rows, err := database.ListMeetingTranscripts(db.MeetingTranscriptFilter{EventID: transcriptListFlagEventID})
	if err != nil {
		return err
	}

	out := make([]map[string]any, 0, len(rows))
	for _, tr := range rows {
		eventID := ""
		if tr.EventID.Valid {
			eventID = tr.EventID.String
		}
		snippet := []rune(tr.TranscriptText)
		if len(snippet) > 200 {
			snippet = snippet[:200]
		}
		out = append(out, map[string]any{
			"id":           tr.ID,
			"event_id":     eventID,
			"title":        tr.Title,
			"duration_sec": tr.DurationSec,
			"created_at":   tr.CreatedAt,
			"has_summary":  tr.SummaryJSON.Valid,
			"snippet":      string(snippet),
		})
	}

	enc := json.NewEncoder(cmd.OutOrStdout())
	enc.SetIndent("", "  ")
	return enc.Encode(out)
}

func runTranscriptShow(cmd *cobra.Command, args []string) error {
	id, err := strconv.ParseInt(args[0], 10, 64)
	if err != nil {
		return fmt.Errorf("invalid transcript id %q: %w", args[0], err)
	}

	_, database, err := transcriptEnv()
	if err != nil {
		return err
	}
	defer database.Close()

	tr, err := database.GetMeetingTranscript(id)
	if err != nil {
		return err
	}
	if tr == nil {
		return fmt.Errorf("transcript %d not found", id)
	}

	eventID := ""
	if tr.EventID.Valid {
		eventID = tr.EventID.String
	}
	var audioPath, summaryJSON any
	if tr.AudioPath.Valid {
		audioPath = tr.AudioPath.String
	}
	if tr.SummaryJSON.Valid {
		summaryJSON = tr.SummaryJSON.String
	}
	envelope := map[string]any{
		"id":              tr.ID,
		"event_id":        eventID,
		"title":           tr.Title,
		"audio_path":      audioPath,
		"duration_sec":    tr.DurationSec,
		"lang_stats":      tr.LangStats,
		"transcript_text": tr.TranscriptText,
		"summary_json":    summaryJSON,
		"created_at":      tr.CreatedAt,
		"updated_at":      tr.UpdatedAt,
	}
	enc := json.NewEncoder(cmd.OutOrStdout())
	enc.SetIndent("", "  ")
	return enc.Encode(envelope)
}

func runTranscriptNotes(cmd *cobra.Command, args []string) error {
	id, err := strconv.ParseInt(args[0], 10, 64)
	if err != nil {
		return fmt.Errorf("invalid transcript id %q: %w", args[0], err)
	}

	cfg, database, err := transcriptEnv()
	if err != nil {
		return err
	}
	defer database.Close()

	tr, err := database.GetMeetingTranscript(id)
	if err != nil {
		return err
	}
	if tr == nil {
		return fmt.Errorf("transcript %d not found", id)
	}

	runID, err := database.CreatePipelineRun("meeting_notes", "cli", "auto")
	if err != nil {
		fmt.Fprintf(cmd.ErrOrStderr(), "warning: recording meeting_notes pipeline run: %v\n", err)
	}
	completeRun := func(items, in, out, api int, errMsg string) {
		if err := database.CompletePipelineRun(runID, items, in, out, 0, api, nil, nil, errMsg); err != nil {
			fmt.Fprintf(cmd.ErrOrStderr(), "warning: completing meeting_notes pipeline run %d: %v\n", runID, err)
		}
	}

	pipe := meeting.New(database, cfg, transcriptGeneratorFactory(cfg), nil)
	pipe.SetPromptStore(prompts.New(database, nil))

	eventID := ""
	if tr.EventID.Valid {
		eventID = tr.EventID.String
	}
	ctx := cmd.Context()
	if ctx == nil { // RunE invoked outside cobra's Execute (tests)
		ctx = context.Background()
	}
	notes, usage, err := pipe.GenerateTranscriptNotes(ctx, eventID, tr.TranscriptText)
	if err != nil {
		completeRun(0, 0, 0, 0, err.Error())
		return err
	}
	if err := database.SetMeetingTranscriptNotes(id, notes); err != nil {
		completeRun(0, 0, 0, 0, err.Error())
		return err
	}

	in, out, api := 0, 0, 0
	if usage != nil {
		in, out, api = usage.InputTokens, usage.OutputTokens, usage.TotalAPITokens
	}
	completeRun(1, in, out, api, "")

	enc := json.NewEncoder(cmd.OutOrStdout())
	enc.SetIndent("", "  ")
	return enc.Encode(map[string]any{
		"transcript_id": id,
		"notes_md":      notes,
	})
}

func generateAndStoreTranscriptChapters(ctx context.Context, database *db.DB, cfg *config.Config, id int64, errOut io.Writer) (string, error) {
	if ctx == nil { // RunE invoked outside cobra's Execute (tests)
		ctx = context.Background()
	}
	tr, err := database.GetMeetingTranscript(id)
	if err != nil {
		return "", err
	}
	if tr == nil {
		return "", fmt.Errorf("transcript %d not found", id)
	}
	if !tr.SegmentsJSON.Valid {
		return "", fmt.Errorf("transcript %d has no segments — chapters need per-utterance timecodes", id)
	}
	utterances, err := meeting.ParseTranscriptSegments([]byte(tr.SegmentsJSON.String))
	if err != nil {
		return "", err
	}

	runID, err := database.CreatePipelineRun("meeting_chapters", "cli", "auto")
	if err != nil {
		fmt.Fprintf(errOut, "warning: recording meeting_chapters pipeline run: %v\n", err)
	}
	completeRun := func(items, in, out, api int, errMsg string) {
		if err := database.CompletePipelineRun(runID, items, in, out, 0, api, nil, nil, errMsg); err != nil {
			fmt.Fprintf(errOut, "warning: completing meeting_chapters pipeline run %d: %v\n", runID, err)
		}
	}
	pipe := meeting.New(database, cfg, transcriptGeneratorFactory(cfg), nil)
	pipe.SetPromptStore(prompts.New(database, nil))

	eventID := ""
	if tr.EventID.Valid {
		eventID = tr.EventID.String
	}
	res, usage, err := pipe.GenerateTranscriptChapters(ctx, eventID, utterances, tr.DurationSec)
	if err != nil {
		completeRun(0, 0, 0, 0, err.Error())
		return "", err
	}
	// Regeneration must not silently wipe Action-item→Target links: stamps
	// from the previous chapters are re-keyed onto matching items in the new
	// ones (the Target rows themselves always survive).
	if tr.ChaptersJSON.Valid {
		if old, parseErr := meeting.ParseChapters([]byte(tr.ChaptersJSON.String)); parseErr == nil {
			meeting.CarryConvertedTargets(old, res)
		}
	}
	chaptersJSON, err := json.Marshal(res)
	if err != nil {
		completeRun(0, 0, 0, 0, err.Error())
		return "", fmt.Errorf("marshalling chapters: %w", err)
	}
	if err := database.SetMeetingTranscriptChapters(id, string(chaptersJSON)); err != nil {
		completeRun(0, 0, 0, 0, err.Error())
		return "", err
	}

	in, out, api := 0, 0, 0
	if usage != nil {
		in, out, api = usage.InputTokens, usage.OutputTokens, usage.TotalAPITokens
	}
	completeRun(1, in, out, api, "")
	return string(chaptersJSON), nil
}

func runTranscriptChapters(cmd *cobra.Command, args []string) error {
	id, err := strconv.ParseInt(args[0], 10, 64)
	if err != nil {
		return fmt.Errorf("invalid transcript id %q: %w", args[0], err)
	}

	cfg, database, err := transcriptEnv()
	if err != nil {
		return err
	}
	defer database.Close()

	chaptersJSON, err := generateAndStoreTranscriptChapters(cmd.Context(), database, cfg, id, cmd.ErrOrStderr())
	if err != nil {
		return err
	}

	enc := json.NewEncoder(cmd.OutOrStdout())
	enc.SetIndent("", "  ")
	return enc.Encode(map[string]any{
		"transcript_id": id,
		"chapters_json": chaptersJSON,
	})
}

func runTranscriptFollowup(cmd *cobra.Command, args []string) error {
	id, err := strconv.ParseInt(args[0], 10, 64)
	if err != nil {
		return fmt.Errorf("invalid transcript id %q: %w", args[0], err)
	}
	// -1 is the "whole meeting" sentinel (flag default); any other negative
	// is a caller bug, not a request for a whole-meeting draft.
	if transcriptFollowupChapter < -1 {
		return fmt.Errorf("invalid --chapter %d: use a 0-based chapter index, or omit the flag for a whole-meeting draft", transcriptFollowupChapter)
	}

	cfg, database, err := transcriptEnv()
	if err != nil {
		return err
	}
	defer database.Close()

	tr, err := database.GetMeetingTranscript(id)
	if err != nil {
		return err
	}
	if tr == nil {
		return fmt.Errorf("transcript %d not found", id)
	}
	if !tr.ChaptersJSON.Valid {
		return fmt.Errorf("transcript %d has no chapters — generate them first (transcript chapters %d)", id, id)
	}
	chapters, err := meeting.ParseChapters([]byte(tr.ChaptersJSON.String))
	if err != nil {
		return err
	}

	input, err := followupInput(tr, chapters, transcriptFollowupChapter)
	if err != nil {
		return err
	}

	runID, err := database.CreatePipelineRun("meeting_followup", "cli", "auto")
	if err != nil {
		fmt.Fprintf(cmd.ErrOrStderr(), "warning: recording meeting_followup pipeline run: %v\n", err)
	}
	completeRun := func(items, in, out, api int, errMsg string) {
		if err := database.CompletePipelineRun(runID, items, in, out, 0, api, nil, nil, errMsg); err != nil {
			fmt.Fprintf(cmd.ErrOrStderr(), "warning: completing meeting_followup pipeline run %d: %v\n", runID, err)
		}
	}
	pipe := meeting.New(database, cfg, transcriptGeneratorFactory(cfg), nil)
	pipe.SetPromptStore(prompts.New(database, nil))

	ctx := cmd.Context()
	if ctx == nil { // RunE invoked outside cobra's Execute (tests)
		ctx = context.Background()
	}
	draft, usage, err := pipe.GenerateFollowupDraft(ctx, input)
	if err != nil {
		completeRun(0, 0, 0, 0, err.Error())
		return err
	}
	in, out, api := 0, 0, 0
	if usage != nil {
		in, out, api = usage.InputTokens, usage.OutputTokens, usage.TotalAPITokens
	}
	completeRun(1, in, out, api, "")

	var chapter any
	if transcriptFollowupChapter >= 0 {
		chapter = transcriptFollowupChapter
	}
	enc := json.NewEncoder(cmd.OutOrStdout())
	enc.SetIndent("", "  ")
	return enc.Encode(map[string]any{
		"transcript_id": id,
		"chapter":       chapter,
		"draft":         draft,
	})
}

// followupInput builds the stated-content input for one chapter (chapterIdx
// >= 0) or the whole meeting (chapterIdx < 0 — the union of every chapter's
// extractions, deduplicated participant labels). The meeting date comes from
// the transcript's created_at (its date part).
func followupInput(tr *db.MeetingTranscript, chapters *meeting.ChaptersResult, chapterIdx int) (meeting.FollowupInput, error) {
	input := meeting.FollowupInput{
		MeetingTitle: tr.Title,
		MeetingDate:  tr.CreatedAt,
	}
	if len(tr.CreatedAt) >= 10 {
		input.MeetingDate = tr.CreatedAt[:10]
	}

	appendChapter := func(ch meeting.MeetingChapter) {
		for _, p := range ch.Participants {
			if !slices.Contains(input.Participants, p) {
				input.Participants = append(input.Participants, p)
			}
		}
		input.Decisions = append(input.Decisions, ch.Decisions...)
		for _, it := range ch.ActionItems {
			input.ActionItems = append(input.ActionItems, it.Text)
		}
		input.OpenQuestions = append(input.OpenQuestions, ch.OpenQuestions...)
	}

	if chapterIdx >= 0 {
		if chapterIdx >= len(chapters.Chapters) {
			return input, fmt.Errorf("chapter %d out of range (transcript has %d chapters)", chapterIdx, len(chapters.Chapters))
		}
		appendChapter(chapters.Chapters[chapterIdx])
		return input, nil
	}
	for _, ch := range chapters.Chapters {
		appendChapter(ch)
	}
	return input, nil
}
