package meeting

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"strings"
)

// ErrNoTimedSegments is RenderTranscriptExport's answer for an srt export of
// a recording without segments: subtitles need each utterance's times.
var ErrNoTimedSegments = errors.New("no timed segments")

// TranscriptExport is what `transcript export` renders: one recording with
// its utterances (nil for a legacy row without segments, whose flat Text is
// then exported instead). Deleted utterances are skipped by the renderer.
type TranscriptExport struct {
	ID          int64
	Title       string
	EventID     string
	EventTitle  string // "" when not linked or the event is gone
	CreatedAt   string
	DurationSec int
	Private     bool
	Text        string
	Segments    []TranscriptUtterance
}

// RenderTranscriptExport renders e in format txt, md, srt or json
// (docs/features/private-meetings.md). Export never involves a model, so it
// is allowed for a private recording too (MEETPRIV-05).
func RenderTranscriptExport(e TranscriptExport, format string) ([]byte, error) {
	kept := make([]TranscriptUtterance, 0, len(e.Segments))
	for _, u := range e.Segments {
		if !u.Deleted {
			kept = append(kept, u)
		}
	}
	switch format {
	case "txt":
		return []byte(exportTxt(e, kept)), nil
	case "md":
		return []byte(exportMarkdown(e, kept)), nil
	case "srt":
		if len(kept) == 0 {
			return nil, ErrNoTimedSegments
		}
		return []byte(exportSRT(kept)), nil
	case "json":
		return exportJSON(e, kept)
	default:
		return nil, fmt.Errorf("unknown export format %q (txt, md, srt or json)", format)
	}
}

func exportTxt(e TranscriptExport, kept []TranscriptUtterance) string {
	if e.Segments == nil {
		return withTrailingNewline(e.Text)
	}
	var b strings.Builder
	for _, u := range kept {
		fmt.Fprintf(&b, "[%s] %s\n", clock(u.StartSec), speakerLine(u))
	}
	return b.String()
}

func exportMarkdown(e TranscriptExport, kept []TranscriptUtterance) string {
	var b strings.Builder
	fmt.Fprintf(&b, "# %s\n\n", e.Title)
	var meta []string
	if len(e.CreatedAt) >= 10 {
		meta = append(meta, "Date: "+e.CreatedAt[:10])
	}
	if e.DurationSec > 0 {
		meta = append(meta, "Duration: "+clock(float64(e.DurationSec)))
	}
	if e.EventTitle != "" {
		meta = append(meta, "Event: "+e.EventTitle)
	}
	if len(meta) > 0 {
		b.WriteString(strings.Join(meta, " · ") + "\n\n")
	}
	if e.Segments == nil {
		b.WriteString(withTrailingNewline(e.Text))
		return b.String()
	}
	for i, u := range kept {
		if i > 0 {
			b.WriteString("\n")
		}
		if u.Speaker != "" {
			fmt.Fprintf(&b, "**%s** · %s\n", u.Speaker, clock(u.StartSec))
		} else {
			b.WriteString(clock(u.StartSec) + "\n")
		}
		b.WriteString(u.Text + "\n")
	}
	return b.String()
}

func exportSRT(kept []TranscriptUtterance) string {
	var b strings.Builder
	for i, u := range kept {
		end := max(u.EndSec, u.StartSec)
		fmt.Fprintf(&b, "%d\n%s --> %s\n%s\n\n", i+1, srtTime(u.StartSec), srtTime(end), speakerLine(u))
	}
	return b.String()
}

type exportSegment struct {
	StartSec float64 `json:"start_sec"`
	EndSec   float64 `json:"end_sec"`
	Speaker  string  `json:"speaker"`
	Text     string  `json:"text"`
}

func exportJSON(e TranscriptExport, kept []TranscriptUtterance) ([]byte, error) {
	segments := make([]exportSegment, 0, len(kept))
	for _, u := range kept {
		segments = append(segments, exportSegment{StartSec: u.StartSec, EndSec: u.EndSec, Speaker: u.Speaker, Text: u.Text})
	}
	out, err := json.MarshalIndent(struct {
		ID             int64           `json:"id"`
		Title          string          `json:"title"`
		EventID        string          `json:"event_id"`
		CreatedAt      string          `json:"created_at"`
		DurationSec    int             `json:"duration_sec"`
		Private        bool            `json:"private"`
		Segments       []exportSegment `json:"segments"`
		TranscriptText string          `json:"transcript_text"`
	}{e.ID, e.Title, e.EventID, e.CreatedAt, e.DurationSec, e.Private, segments, e.Text}, "", "  ")
	if err != nil {
		return nil, fmt.Errorf("encoding transcript export: %w", err)
	}
	return append(out, '\n'), nil
}

// speakerLine is "Speaker: text", or the bare text for an unnamed speaker.
func speakerLine(u TranscriptUtterance) string {
	if u.Speaker == "" {
		return u.Text
	}
	return u.Speaker + ": " + u.Text
}

// clock formats seconds as hh:mm:ss (fractions dropped).
func clock(sec float64) string {
	s := int64(math.Max(sec, 0))
	return fmt.Sprintf("%02d:%02d:%02d", s/3600, s%3600/60, s%60)
}

// srtTime formats seconds as the SubRip hh:mm:ss,mmm, rounded to the
// millisecond.
func srtTime(sec float64) string {
	ms := int64(math.Round(math.Max(sec, 0) * 1000))
	return fmt.Sprintf("%02d:%02d:%02d,%03d", ms/3_600_000, ms%3_600_000/60_000, ms%60_000/1000, ms%1000)
}

func withTrailingNewline(s string) string {
	if s == "" || strings.HasSuffix(s, "\n") {
		return s
	}
	return s + "\n"
}
