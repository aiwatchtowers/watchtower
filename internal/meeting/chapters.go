package meeting

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"watchtower/internal/digest"
	"watchtower/internal/prompts"
)

// ChaptersResult is the persisted shape of meeting_transcripts.chapters_json
// (snake_case keys, shared with the Swift MeetingChapters model).
type ChaptersResult struct {
	OverallSummary string           `json:"overall_summary"`
	Chapters       []MeetingChapter `json:"chapters"`
}

// MeetingChapter is one chapter of a meeting: a contiguous time range with
// per-chapter extractions (decisions / action items / open questions).
type MeetingChapter struct {
	Title         string              `json:"title"`
	StartSec      float64             `json:"start_sec"`
	EndSec        float64             `json:"end_sec"`
	Participants  []string            `json:"participants"`
	Summary       string              `json:"summary"`
	Decisions     []string            `json:"decisions"`
	ActionItems   []ChapterActionItem `json:"action_items"`
	OpenQuestions []string            `json:"open_questions"`
}

// ChapterActionItem is one action item inside a chapter. ConvertedTargetID is
// set by the Desktop app when the item is converted into a Target — a link,
// not a delete (DASH-03 spirit); the AI never emits it.
type ChapterActionItem struct {
	Text              string `json:"text"`
	ConvertedTargetID *int64 `json:"converted_target_id,omitempty"`
}

// UnmarshalJSON accepts both the persisted object form
// ({"text": ..., "converted_target_id": ...}) and the bare-string form the
// model may emit (the meeting.recap action_items precedent), so a slightly
// off-schema AI response degrades gracefully instead of failing the parse.
func (a *ChapterActionItem) UnmarshalJSON(data []byte) error {
	trimmed := bytes.TrimSpace(data)
	if len(trimmed) > 0 && trimmed[0] == '"' {
		var s string
		if err := json.Unmarshal(trimmed, &s); err != nil {
			return err
		}
		*a = ChapterActionItem{Text: s}
		return nil
	}
	type alias ChapterActionItem // drop methods to avoid recursion
	var v alias
	if err := json.Unmarshal(data, &v); err != nil {
		return err
	}
	*a = ChapterActionItem(v)
	return nil
}

// ParseChapters decodes a chapters_json payload. It rejects anything without
// at least one chapter — callers treat an error as "no chapters".
func ParseChapters(data []byte) (*ChaptersResult, error) {
	var res ChaptersResult
	if err := json.Unmarshal(data, &res); err != nil {
		return nil, fmt.Errorf("decoding meeting chapters: %w", err)
	}
	if len(res.Chapters) == 0 {
		return nil, fmt.Errorf("meeting chapters array is empty")
	}
	return &res, nil
}

// FormatTimecode renders seconds as m:ss (or h:mm:ss past an hour) — the same
// display format as the Swift TranscriptFormatting.formatTimecode.
func FormatTimecode(sec float64) string {
	if sec < 0 {
		sec = 0
	}
	total := int(sec)
	h, m, s := total/3600, (total%3600)/60, total%60
	if h > 0 {
		return fmt.Sprintf("%d:%02d:%02d", h, m, s)
	}
	return fmt.Sprintf("%d:%02d", m, s)
}

// RenderTimecodedTranscript renders the non-deleted utterances as
// "[m:ss] [speaker] text" lines — the user-message input of the
// meeting.chapters prompt (timecodes let the model anchor chapter
// boundaries to real positions in the recording).
func RenderTimecodedTranscript(utterances []TranscriptUtterance) string {
	var lines []string
	for _, u := range utterances {
		if u.Deleted {
			continue
		}
		lines = append(lines, fmt.Sprintf("[%s] [%s] %s", FormatTimecode(u.StartSec), u.Speaker, u.Text))
	}
	return strings.Join(lines, "\n")
}

// GenerateTranscriptChapters chapterizes a meeting from its per-utterance
// segments. Like the recap/notes generators, the (timecoded) transcript
// travels in the USER message so the generators' stdin path keeps hour-long
// transcripts clear of ARG_MAX. eventID may be "" for ad-hoc recordings.
// durationSec bounds the chapter timecodes (0 = unknown, no bound). The
// pipeline does NOT persist — the CLI caller writes chapters_json.
func (p *Pipeline) GenerateTranscriptChapters(ctx context.Context, eventID string, utterances []TranscriptUtterance, durationSec int) (*ChaptersResult, *digest.Usage, error) {
	timecoded := RenderTimecodedTranscript(utterances)
	if timecoded == "" {
		return nil, nil, fmt.Errorf("no non-deleted utterances to chapterize")
	}

	title, startTime, endTime, attendees, description := "(ad-hoc recording)", "", "", "", ""
	if eventID != "" && p.db != nil {
		if ev, err := p.db.GetCalendarEventByID(eventID); err == nil && ev != nil {
			title, startTime, endTime = ev.Title, ev.StartTime, ev.EndTime
			attendees, description = ev.Attendees, ev.Description
		}
	}

	lang := ""
	if p.cfg != nil {
		lang = p.cfg.Digest.Language
	}

	tmpl := p.loadChaptersPrompt()
	systemPrompt := fmt.Sprintf(tmpl,
		title, startTime, endTime, attendees, description,
		prompts.Directive(lang),
	)
	userMessage := "Below is the full meeting transcript with [m:ss] timecodes and speaker labels. " +
		"Generate the chapters JSON exactly per the system prompt.\n\n=== TRANSCRIPT ===\n" + timecoded

	aiResponse, usage, _, err := p.generator.Generate(
		digest.WithSource(ctx, "meeting.chapters"), systemPrompt, userMessage, "")
	if err != nil {
		return nil, nil, fmt.Errorf("AI generation: %w", err)
	}
	var raw ChaptersResult
	if err := json.Unmarshal([]byte(cleanJSON(aiResponse)), &raw); err != nil {
		return nil, nil, fmt.Errorf("parsing AI response: %w (raw: %.300s)", err, aiResponse)
	}
	if err := normalizeChapters(&raw, durationSec); err != nil {
		return nil, nil, err
	}
	return &raw, usage, nil
}

// normalizeChapters trims/validates an AI-produced ChaptersResult in place.
// Titles must be non-empty and timecodes must stay within the recording
// (start beyond the duration is an error; an end slightly past it — the model
// rounding up — is clamped). A validation error fails the whole generation:
// nothing partial is ever persisted.
func normalizeChapters(res *ChaptersResult, durationSec int) error {
	res.OverallSummary = strings.TrimSpace(res.OverallSummary)
	if len(res.Chapters) == 0 {
		return fmt.Errorf("AI returned no chapters")
	}
	for i := range res.Chapters {
		ch := &res.Chapters[i]
		ch.Title = strings.TrimSpace(ch.Title)
		if ch.Title == "" {
			return fmt.Errorf("chapter %d has an empty title", i)
		}
		if ch.StartSec < 0 || ch.EndSec < ch.StartSec {
			return fmt.Errorf("chapter %d has an invalid time range %.1f-%.1f", i, ch.StartSec, ch.EndSec)
		}
		if durationSec > 0 {
			if ch.StartSec > float64(durationSec) {
				return fmt.Errorf("chapter %d starts at %.1fs, beyond the %ds recording", i, ch.StartSec, durationSec)
			}
			if ch.EndSec > float64(durationSec) {
				ch.EndSec = float64(durationSec)
			}
		}
		ch.Summary = strings.TrimSpace(ch.Summary)
		ch.Participants = trimNonEmpty(ch.Participants)
		ch.Decisions = trimNonEmpty(ch.Decisions)
		ch.OpenQuestions = trimNonEmpty(ch.OpenQuestions)
		items := ch.ActionItems[:0]
		for _, it := range ch.ActionItems {
			it.Text = strings.TrimSpace(it.Text)
			if it.Text != "" {
				items = append(items, it)
			}
		}
		ch.ActionItems = items
	}
	return nil
}

// CarryConvertedTargets re-keys converted_target_id stamps from a previous
// ChaptersResult onto a freshly generated one, so regenerating chapters never
// silently wipes Action-item→Target links (the Target rows always survive —
// regeneration never deletes Targets). Chapter/item indices shift across
// regenerations, so items are matched by normalized (trimmed, case-folded)
// action-item text, in document order; each old stamp is consumed at most
// once. A converted item whose text no longer appears in the new chapters
// loses its stamp — the link has nothing left to attach to.
func CarryConvertedTargets(old, fresh *ChaptersResult) {
	if old == nil || fresh == nil {
		return
	}
	normalize := func(s string) string { return strings.ToLower(strings.TrimSpace(s)) }
	stamps := make(map[string][]*int64)
	for _, ch := range old.Chapters {
		for _, it := range ch.ActionItems {
			if it.ConvertedTargetID != nil {
				key := normalize(it.Text)
				stamps[key] = append(stamps[key], it.ConvertedTargetID)
			}
		}
	}
	if len(stamps) == 0 {
		return
	}
	for ci := range fresh.Chapters {
		items := fresh.Chapters[ci].ActionItems
		for ii := range items {
			if items[ii].ConvertedTargetID != nil {
				continue
			}
			key := normalize(items[ii].Text)
			queue := stamps[key]
			if len(queue) == 0 {
				continue
			}
			items[ii].ConvertedTargetID = queue[0]
			stamps[key] = queue[1:]
		}
	}
}

func (p *Pipeline) loadChaptersPrompt() string {
	if p.promptStore != nil {
		if tmpl, _, err := p.promptStore.Get(prompts.MeetingChapters); err == nil && tmpl != "" {
			return tmpl
		}
	}
	if tmpl, ok := prompts.Defaults[prompts.MeetingChapters]; ok && tmpl != "" {
		return tmpl
	}
	return defaultChaptersPromptFallback
}

const defaultChaptersPromptFallback = `Segment the meeting into chapters. Event: %s (%s-%s, attendees: %s, description: %s). %s
Return ONLY JSON: {"overall_summary": "...", "chapters": [{"title", "start_sec", "end_sec", "participants", "summary", "decisions", "action_items", "open_questions"}]}.`
