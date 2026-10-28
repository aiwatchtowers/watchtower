package cmd

import (
	"encoding/json"
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
	if private {
		if _, err := kb.DropPrivateRecording(cmd.Context(), database, id); err != nil {
			return fmt.Errorf("recording %d is private, but removing it from the knowledge index failed (the next index pass retries): %w", id, err)
		}
	}
	return json.NewEncoder(cmd.OutOrStdout()).Encode(map[string]any{"id": id, "private": private})
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
		ev, err := database.GetCalendarEventByID(tr.EventID.String)
		if err != nil {
			return fmt.Errorf("looking up calendar event %s: %w", tr.EventID.String, err)
		}
		if ev != nil {
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
	if err != nil {
		return err
	}
	if transcriptExportFlagOutput == "" {
		_, err = cmd.OutOrStdout().Write(out)
		return err
	}
	return fsutil.WriteFileAtomic(transcriptExportFlagOutput, out, 0o600)
}
