package meeting

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

const chaptersMockResponse = `{
	"overall_summary": "  Roadmap sync with two decisions.  ",
	"chapters": [
		{
			"title": "  Rollout plan  ",
			"start_sec": 0,
			"end_sec": 300,
			"participants": ["Я", "Speaker 1", "  "],
			"summary": " Agreed the rollout order. ",
			"decisions": ["Ship v2 on Friday", "  "],
			"action_items": [{"text": " Alice prepares the changelog "}, "Bob books the launch review", "   "],
			"open_questions": []
		},
		{
			"title": "Budget",
			"start_sec": 300,
			"end_sec": 900,
			"participants": ["Speaker 1"],
			"summary": "Budget carry-over.",
			"decisions": [],
			"action_items": [],
			"open_questions": ["Who signs off Q3?"]
		}
	]
}`

func chapterTestUtterances() []TranscriptUtterance {
	return []TranscriptUtterance{
		{Idx: 0, StartSec: 0, EndSec: 12, Speaker: "Я", Text: "привет, начнём"},
		{Idx: 1, StartSec: 12, EndSec: 40, Speaker: "Speaker 1", Text: "let's plan the rollout"},
		{Idx: 2, StartSec: 40, EndSec: 60, Speaker: "Я", Text: "deleted line", Deleted: true},
		{Idx: 3, StartSec: 3700, EndSec: 3720, Speaker: "Speaker 1", Text: "budget next"},
	}
}

func TestFormatTimecode(t *testing.T) {
	cases := []struct {
		sec  float64
		want string
	}{
		{0, "0:00"},
		{12.7, "0:12"},
		{65, "1:05"},
		{3599, "59:59"},
		{3700, "1:01:40"},
		{-5, "0:00"}, // degenerate: negative clamps to zero
	}
	for _, c := range cases {
		if got := FormatTimecode(c.sec); got != c.want {
			t.Errorf("FormatTimecode(%v) = %q, want %q", c.sec, got, c.want)
		}
	}
}

func TestRenderTimecodedTranscript(t *testing.T) {
	got := RenderTimecodedTranscript(chapterTestUtterances())
	want := "[0:00] [Я] привет, начнём\n[0:12] [Speaker 1] let's plan the rollout\n[1:01:40] [Speaker 1] budget next"
	if got != want {
		t.Errorf("RenderTimecodedTranscript = %q, want %q", got, want)
	}
	if strings.Contains(got, "deleted line") {
		t.Error("deleted utterances must be excluded from the timecoded transcript")
	}
}

func TestRenderTimecodedTranscriptAllDeleted(t *testing.T) {
	// Degenerate but valid: every utterance soft-deleted → empty transcript.
	utterances := []TranscriptUtterance{
		{Idx: 0, StartSec: 0, EndSec: 1, Speaker: "Я", Text: "a", Deleted: true},
	}
	if got := RenderTimecodedTranscript(utterances); got != "" {
		t.Errorf("all-deleted render = %q, want empty", got)
	}
}

func TestChapterActionItemUnmarshalBothForms(t *testing.T) {
	var items []ChapterActionItem
	payload := `["bare string item", {"text": "object item", "converted_target_id": 42}]`
	if err := json.Unmarshal([]byte(payload), &items); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if len(items) != 2 {
		t.Fatalf("len = %d, want 2", len(items))
	}
	if items[0].Text != "bare string item" || items[0].ConvertedTargetID != nil {
		t.Errorf("bare form = %+v, want text only", items[0])
	}
	if items[1].Text != "object item" || items[1].ConvertedTargetID == nil || *items[1].ConvertedTargetID != 42 {
		t.Errorf("object form = %+v, want text + converted_target_id 42", items[1])
	}
}

func TestParseChapters(t *testing.T) {
	res, err := ParseChapters([]byte(`{"overall_summary":"s","chapters":[{"title":"t","start_sec":0,"end_sec":5}]}`))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(res.Chapters) != 1 || res.Chapters[0].Title != "t" {
		t.Errorf("chapters = %+v", res.Chapters)
	}

	if _, err := ParseChapters([]byte(`{"overall_summary":"s","chapters":[]}`)); err == nil {
		t.Error("empty chapters array must be rejected")
	}
	if _, err := ParseChapters([]byte(`not json`)); err == nil {
		t.Error("malformed JSON must be rejected")
	}
}

func TestGenerateTranscriptChapters(t *testing.T) {
	mock := &recordingMockGenerator{response: chaptersMockResponse}
	pipe := &Pipeline{generator: mock}

	res, usage, err := pipe.GenerateTranscriptChapters(context.Background(), "", chapterTestUtterances(), 3720)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if usage == nil {
		t.Error("usage is nil, want non-nil")
	}
	if res.OverallSummary != "Roadmap sync with two decisions." {
		t.Errorf("overall_summary = %q, want trimmed", res.OverallSummary)
	}
	if len(res.Chapters) != 2 {
		t.Fatalf("chapters = %d, want 2", len(res.Chapters))
	}
	first := res.Chapters[0]
	if first.Title != "Rollout plan" {
		t.Errorf("title = %q, want trimmed %q", first.Title, "Rollout plan")
	}
	if len(first.Participants) != 2 {
		t.Errorf("participants = %v, want empty entries dropped", first.Participants)
	}
	if len(first.Decisions) != 1 || first.Decisions[0] != "Ship v2 on Friday" {
		t.Errorf("decisions = %v", first.Decisions)
	}
	// Action items accept both the object and bare-string forms; empties dropped.
	if len(first.ActionItems) != 2 {
		t.Fatalf("action_items = %+v, want 2", first.ActionItems)
	}
	if first.ActionItems[0].Text != "Alice prepares the changelog" || first.ActionItems[1].Text != "Bob books the launch review" {
		t.Errorf("action_items = %+v", first.ActionItems)
	}

	// The timecoded transcript travels in the USER message, not the system prompt.
	if !strings.Contains(mock.lastUserMessage, "[0:12] [Speaker 1] let's plan the rollout") {
		t.Errorf("user message should contain the timecoded transcript, got: %q", mock.lastUserMessage)
	}
	if strings.Contains(mock.lastSystemPrompt, "let's plan the rollout") {
		t.Error("system prompt must NOT contain the transcript")
	}
	if !strings.Contains(mock.lastSystemPrompt, "(ad-hoc recording)") {
		t.Errorf("system prompt should contain the ad-hoc title slot, got: %.300s", mock.lastSystemPrompt)
	}
}

func TestGenerateTranscriptChaptersValidation(t *testing.T) {
	cases := map[string]string{
		"empty title":           `{"overall_summary":"s","chapters":[{"title":"  ","start_sec":0,"end_sec":10}]}`,
		"no chapters":           `{"overall_summary":"s","chapters":[]}`,
		"negative start":        `{"overall_summary":"s","chapters":[{"title":"t","start_sec":-1,"end_sec":10}]}`,
		"end before start":      `{"overall_summary":"s","chapters":[{"title":"t","start_sec":20,"end_sec":10}]}`,
		"start beyond duration": `{"overall_summary":"s","chapters":[{"title":"t","start_sec":5000,"end_sec":5100}]}`,
		"not json":              `oops`,
	}
	for name, response := range cases {
		t.Run(name, func(t *testing.T) {
			mock := &recordingMockGenerator{response: response}
			pipe := &Pipeline{generator: mock}
			_, _, err := pipe.GenerateTranscriptChapters(context.Background(), "", chapterTestUtterances(), 3720)
			if err == nil {
				t.Errorf("response %q must fail validation", response)
			}
		})
	}
}

func TestGenerateTranscriptChaptersClampsEndToDuration(t *testing.T) {
	response := `{"overall_summary":"s","chapters":[{"title":"t","start_sec":0,"end_sec":4000}]}`
	pipe := &Pipeline{generator: &recordingMockGenerator{response: response}}
	res, _, err := pipe.GenerateTranscriptChapters(context.Background(), "", chapterTestUtterances(), 3720)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if res.Chapters[0].EndSec != 3720 {
		t.Errorf("end_sec = %v, want clamped to 3720", res.Chapters[0].EndSec)
	}
}

func TestGenerateTranscriptChaptersUnknownDurationSkipsBounds(t *testing.T) {
	// durationSec 0 = unknown — timecode bounds are not enforced.
	response := `{"overall_summary":"s","chapters":[{"title":"t","start_sec":0,"end_sec":4000}]}`
	pipe := &Pipeline{generator: &recordingMockGenerator{response: response}}
	res, _, err := pipe.GenerateTranscriptChapters(context.Background(), "", chapterTestUtterances(), 0)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if res.Chapters[0].EndSec != 4000 {
		t.Errorf("end_sec = %v, want unclamped 4000", res.Chapters[0].EndSec)
	}
}

func TestGenerateTranscriptChaptersAllDeletedFailsBeforeAI(t *testing.T) {
	mock := &recordingMockGenerator{response: chaptersMockResponse}
	pipe := &Pipeline{generator: mock}
	utterances := []TranscriptUtterance{
		{Idx: 0, StartSec: 0, EndSec: 1, Speaker: "Я", Text: "a", Deleted: true},
	}
	_, _, err := pipe.GenerateTranscriptChapters(context.Background(), "", utterances, 60)
	if err == nil {
		t.Fatal("all-deleted utterances must fail")
	}
	if mock.lastUserMessage != "" {
		t.Error("the AI must not be called for an empty transcript")
	}
}

func TestGenerateTranscriptChaptersAIError(t *testing.T) {
	pipe := &Pipeline{generator: &recordingMockGenerator{err: errors.New("boom")}}
	_, _, err := pipe.GenerateTranscriptChapters(context.Background(), "", chapterTestUtterances(), 3720)
	if err == nil || !strings.Contains(err.Error(), "boom") {
		t.Errorf("err = %v, want the AI error surfaced", err)
	}
}

func TestGenerateTranscriptChaptersWithEvent(t *testing.T) {
	database := openTestDB(t)
	seedTestEvent(t, database)
	mock := &recordingMockGenerator{response: chaptersMockResponse}
	pipe := New(database, nil, mock, nil)

	_, _, err := pipe.GenerateTranscriptChapters(context.Background(), "evt1", chapterTestUtterances(), 3720)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(mock.lastSystemPrompt, "1:1 with Alice") {
		t.Errorf("system prompt should contain the event title, got: %.300s", mock.lastSystemPrompt)
	}
}

func TestChaptersJSONRoundTripPreservesConvertedTargetID(t *testing.T) {
	id := int64(7)
	res := ChaptersResult{
		OverallSummary: "s",
		Chapters: []MeetingChapter{{
			Title: "t", StartSec: 0, EndSec: 10,
			ActionItems: []ChapterActionItem{{Text: "do it", ConvertedTargetID: &id}},
		}},
	}
	data, err := json.Marshal(res)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	back, err := ParseChapters(data)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	got := back.Chapters[0].ActionItems[0]
	if got.ConvertedTargetID == nil || *got.ConvertedTargetID != 7 {
		t.Errorf("converted_target_id lost in round trip: %+v", got)
	}
}

func TestCarryConvertedTargetsReKeysByText(t *testing.T) {
	id1, id2 := int64(101), int64(202)
	old := &ChaptersResult{Chapters: []MeetingChapter{
		{Title: "A", ActionItems: []ChapterActionItem{
			{Text: "Ship the release", ConvertedTargetID: &id1},
			{Text: "unconverted item"},
		}},
		{Title: "B", ActionItems: []ChapterActionItem{
			{Text: "  book the review  ", ConvertedTargetID: &id2},
		}},
	}}
	// Regenerated chapters: different split, shifted indices, case/space
	// drift in the texts.
	fresh := &ChaptersResult{Chapters: []MeetingChapter{
		{Title: "Merged", ActionItems: []ChapterActionItem{
			{Text: "Book the review"},
			{Text: "a brand new item"},
			{Text: "ship the release"},
		}},
	}}
	CarryConvertedTargets(old, fresh)

	items := fresh.Chapters[0].ActionItems
	if items[0].ConvertedTargetID == nil || *items[0].ConvertedTargetID != id2 {
		t.Errorf("'Book the review' stamp not carried: %+v", items[0])
	}
	if items[1].ConvertedTargetID != nil {
		t.Errorf("new item must not inherit a stamp: %+v", items[1])
	}
	if items[2].ConvertedTargetID == nil || *items[2].ConvertedTargetID != id1 {
		t.Errorf("'ship the release' stamp not carried: %+v", items[2])
	}
}

func TestCarryConvertedTargetsDuplicateTextsConsumeInOrder(t *testing.T) {
	id1, id2 := int64(1), int64(2)
	old := &ChaptersResult{Chapters: []MeetingChapter{
		{Title: "A", ActionItems: []ChapterActionItem{
			{Text: "follow up", ConvertedTargetID: &id1},
			{Text: "follow up", ConvertedTargetID: &id2},
		}},
	}}
	fresh := &ChaptersResult{Chapters: []MeetingChapter{
		{Title: "A", ActionItems: []ChapterActionItem{
			{Text: "follow up"},
			{Text: "follow up"},
			{Text: "follow up"},
		}},
	}}
	CarryConvertedTargets(old, fresh)
	items := fresh.Chapters[0].ActionItems
	if items[0].ConvertedTargetID == nil || *items[0].ConvertedTargetID != id1 {
		t.Errorf("first duplicate must take the first stamp: %+v", items[0])
	}
	if items[1].ConvertedTargetID == nil || *items[1].ConvertedTargetID != id2 {
		t.Errorf("second duplicate must take the second stamp: %+v", items[1])
	}
	if items[2].ConvertedTargetID != nil {
		t.Errorf("third duplicate must stay unstamped (each stamp consumed once): %+v", items[2])
	}
}

func TestCarryConvertedTargetsDegenerateInputs(t *testing.T) {
	// Degenerate but valid: nils and no stamps at all must be no-ops.
	CarryConvertedTargets(nil, nil)
	id := int64(5)
	fresh := &ChaptersResult{Chapters: []MeetingChapter{
		{Title: "A", ActionItems: []ChapterActionItem{{Text: "x", ConvertedTargetID: &id}}},
	}}
	CarryConvertedTargets(nil, fresh)
	CarryConvertedTargets(&ChaptersResult{}, fresh)
	if *fresh.Chapters[0].ActionItems[0].ConvertedTargetID != 5 {
		t.Errorf("pre-existing fresh stamp must never be overwritten")
	}

	// Old stamps with no textual match in the new chapters are dropped —
	// the Target row survives; only the marker has nothing to attach to.
	old := &ChaptersResult{Chapters: []MeetingChapter{
		{Title: "A", ActionItems: []ChapterActionItem{{Text: "vanished item", ConvertedTargetID: &id}}},
	}}
	target := &ChaptersResult{Chapters: []MeetingChapter{
		{Title: "A", ActionItems: []ChapterActionItem{{Text: "different"}}},
	}}
	CarryConvertedTargets(old, target)
	if target.Chapters[0].ActionItems[0].ConvertedTargetID != nil {
		t.Errorf("non-matching text must not be stamped")
	}
}
