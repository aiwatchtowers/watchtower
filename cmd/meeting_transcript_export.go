package cmd

import (
	"encoding/json"
	"errors"
	"fmt"
	"strconv"

	"watchtower/internal/fsutil"
	"watchtower/internal/kb"
	"watchtower/internal/meeting"

	"github.com/spf13/cobra"
)

// runTranscriptPrivate sets a recording's private flag (MEETPRIV-04). Turning
// it on also drops the recording's knowledge documents now, so search stops
// serving them at once; the indexer's next pass restores them once it is
// off. Nothing is generated or unmined.
//
// The flag is the primary effect: once it is written the command exits 0
// even if the drop fails (the flip's kb_dirty marks and the indexer's next
// pass are the backstop), reporting the failure as `kb_drop_error` plus a
// stderr warning — so a caller never takes a recording that is private for a
// public one.
func runTranscriptPrivate(cmd *cobra.Command, args []string) error {
	id, err := strconv.ParseInt(args[0], 10, 64)
	if err != nil {
		return fmt.Errorf("invalid transcript id %q: %w", args[0], err)
	}
	var private bool
	switch args[1] {
	case "on":
		private = true
	case "off":
	default:
		return fmt.Errorf("invalid value %q: use on or off", args[1])
	}

	_, database, err := transcriptEnv()
	if err != nil {
		return err
	}
	defer database.Close()

	found, err := database.SetMeetingTranscriptPrivate(id, private)
	if err != nil {
		return err
	}
	if !found {
		return fmt.Errorf("transcript %d not found", id)
	}
	out := map[string]any{"id": id, "private": private}
	if private {
		if _, err := kb.DropPrivateRecording(cmd.Context(), database, id); err != nil {
			fmt.Fprintf(cmd.ErrOrStderr(), "warning: recording %d is private, but removing it from the knowledge index failed (the next index pass retries): %v\n", id, err)
			out["kb_drop_error"] = err.Error()
		}
	}
	return json.NewEncoder(cmd.OutOrStdout()).Encode(out)
}

// runTranscriptExport renders one recording through
// meeting.RenderTranscriptExport — private or not (MEETPRIV-05) — to stdout
// or, with --output, to a 0600 file.
func runTranscriptExport(cmd *cobra.Command, args []string) error {
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
	e := meeting.TranscriptExport{
		ID: tr.ID, Title: tr.Title, EventID: tr.EventID.String, CreatedAt: tr.CreatedAt,
		DurationSec: tr.DurationSec, Private: tr.Private, Text: tr.TranscriptText,
	}
	if tr.EventID.Valid {
		// The event title only labels the md header: a failed lookup leaves
		// it out instead of failing the export.
		ev, err := database.GetCalendarEventByID(tr.EventID.String)
		if err != nil {
			fmt.Fprintf(cmd.ErrOrStderr(), "warning: looking up calendar event %s (%v); exporting without its title\n", tr.EventID.String, err)
		} else if ev != nil {
			e.EventTitle = ev.Title
		}
	}
	if tr.SegmentsJSON.Valid {
		// The column is validated on every write; a row that still fails to
		// parse exports its flat text (srt then has no timed segments).
		if e.Segments, err = meeting.ParseTranscriptSegments([]byte(tr.SegmentsJSON.String)); err != nil {
			fmt.Fprintf(cmd.ErrOrStderr(), "warning: transcript %d segments unreadable (%v); exporting the plain text\n", id, err)
			e.Segments = nil
		}
	}
	out, err := meeting.RenderTranscriptExport(e, transcriptExportFlagFormat)
	if errors.Is(err, meeting.ErrNoTimedSegments) {
		return fmt.Errorf("transcript %d: %w", id, err)
	}
	if err != nil {
		return err
	}
	if transcriptExportFlagOutput == "" {
		_, err = cmd.OutOrStdout().Write(out)
		return err
	}
	return fsutil.WriteFileAtomic(transcriptExportFlagOutput, out, 0o600)
}
