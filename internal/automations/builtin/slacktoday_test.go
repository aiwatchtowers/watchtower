package builtin

import (
	"bytes"
	"cmp"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	"watchtower/internal/automations"
	"watchtower/internal/automations/blocks"
	"watchtower/internal/db"
	"watchtower/internal/prompts"
)

// The default window fixture's message ids.
const (
	stReleaseAsk   = "1:C0ACME/1792656600.000001"
	stReleaseYes   = "1:C0ACME/1792656720.000002"
	stReleaseNotes = "1:C0ACME/1792657200.000003"
	stReleaseToMe  = "1:C0ACME/1792657800.000004"
	stIcons        = "1:C0DESIGN/1792658400.000005"
	stPalette      = "1:C0DESIGN/1792658700.000006"
)

// slackTodayReply is the model's answer to the default window fixture.
const slackTodayReply = `{"lines": [
  {"ids": ["` + stReleaseAsk + `", "` + stReleaseYes + `"], "label": "decided", "text": "Release 2.4 goes out on Thursday."},
  {"ids": ["` + stReleaseNotes + `"], "label": "needs_someone", "text": "Colleague B asks who can review the release notes."},
  {"ids": ["` + stPalette + `"], "label": "asks_you", "text": "Colleague C asks the team to pick the dark palette."},
  {"ids": ["` + stIcons + `"], "label": "fyi", "text": "The new icons are in the shared folder."}
]}`

// slackTodayWindow is a done slack.window result read from the window
// fixture at path ("" = testdata/slack_today_window.json).
func slackTodayWindow(t *testing.T, path string) automations.PrimitiveResult {
	t.Helper()
	data, err := os.ReadFile(cmp.Or(path, filepath.Join("testdata", "slack_today_window.json")))
	if err != nil {
		t.Fatal(err)
	}
	var fields map[string]any
	if err := json.Unmarshal(data, &fields); err != nil {
		t.Fatal(err)
	}
	return automations.PrimitiveResult{Status: "done", Fields: fields}
}

// stMsg is one window row; the channel's id is "1:<chan>", its name
// "#<name>".
type stMsg struct {
	chan_, name, ts, text string
	at                    time.Time
	toOwner               bool
}

func (m stMsg) id() string { return "1:" + m.chan_ + "/" + m.ts }

func (m stMsg) row() map[string]any {
	return map[string]any{
		"id": m.id(), "channel_id": "1:" + m.chan_, "channel": "#" + m.name, "author": "Colleague A",
		"at": m.at.UTC().Format(time.RFC3339), "time": m.at.Format("15:04"), "text": m.text, "thread_id": "",
		"permalink": "https://acme.slack.com/archives/" + m.chan_ + "/p" + strings.ReplaceAll(m.ts, ".", ""),
		"by_owner":  false, "to_owner": m.toOwner, "bot": false,
	}
}

// stWindow is a done window of day with msgs and below_floor.
func stWindow(day string, belowFloor int, msgs ...stMsg) automations.PrimitiveResult {
	rows := make([]any, 0, len(msgs))
	for _, m := range msgs {
		rows = append(rows, m.row())
	}
	return automations.PrimitiveResult{Status: "done", Fields: map[string]any{
		"day": day, "owner": map[string]any{"name": "Owner A"}, "messages": rows, "count": len(rows),
		"truncated": false, "skipped_older": 0, "below_floor": belowFloor,
	}}
}

// stLine is one line of a model reply.
type stLine struct {
	IDs   []string `json:"ids"`
	Label string   `json:"label"`
	Text  string   `json:"text"`
}

func stReply(t *testing.T, lines ...stLine) string {
	t.Helper()
	data, err := json.Marshal(map[string]any{"lines": append([]stLine{}, lines...)})
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

// todayState is the state's "today" value (shape v1).
type todayState struct {
	V               int                     `json:"v"`
	Day             string                  `json:"day"`
	Messages        int                     `json:"messages"`
	MissedYesterday int                     `json:"missed_yesterday"`
	Channels        map[string]todayChannel `json:"channels"`
	QuietRest       struct {
		Channels int `json:"channels"`
		Messages int `json:"messages"`
	} `json:"quiet_rest"`
}

type todayChannel struct {
	Name  string      `json:"name"`
	N     int         `json:"n"`
	More  int         `json:"more"`
	Lines []todayLine `json:"lines"`
}

type todayLine struct {
	Label string `json:"label"`
	Text  string `json:"text"`
	At    string `json:"at"`
	Link  string `json:"link"`
}

// stRun runs Slack today once with the window res and the model replies
// (nil keeps the generator's).
func (f *fixture) stRun(t *testing.T, res automations.PrimitiveResult, replies ...string) *db.AutomationRun {
	t.Helper()
	f.window.mu.Lock()
	f.window.res = res
	f.window.mu.Unlock()
	if replies != nil {
		f.gen.Replies = append(f.gen.Replies[:0:0], replies...)
	}
	return f.runOnce(t, SlackTodayID)
}

// stOK is stRun that must succeed.
func (f *fixture) stOK(t *testing.T, res automations.PrimitiveResult, replies ...string) {
	t.Helper()
	if run := f.stRun(t, res, replies...); run.Status != db.RunSucceeded {
		t.Fatalf("run = %s (%s); want succeeded", run.Status, run.Error)
	}
}

// stRawState is Slack today's committed state.
func (f *fixture) stRawState(t *testing.T) map[string]json.RawMessage {
	t.Helper()
	raw, err := f.d.GetAutomationState(f.rowOf(t, SlackTodayID).ID)
	if err != nil {
		t.Fatal(err)
	}
	all := map[string]json.RawMessage{}
	if len(raw) > 0 {
		if err := json.Unmarshal(raw, &all); err != nil {
			t.Fatal(err)
		}
	}
	return all
}

func (f *fixture) stState(t *testing.T) todayState {
	t.Helper()
	raw, ok := f.stRawState(t)["today"]
	if !ok {
		t.Fatal(`no "today" in the state`)
	}
	var s todayState
	if err := json.Unmarshal(raw, &s); err != nil {
		t.Fatal(err)
	}
	return s
}

// stCard is the Slack today artifact.
type stCard struct {
	title, hash string
	readAt      *string
	doc         *blocks.Document
}

func (f *fixture) stCard(t *testing.T) stCard {
	t.Helper()
	rows, err := f.d.Query(`SELECT title, blocks_json, content_hash, read_at FROM automation_outputs
		WHERE automation_id = ? AND kind = 'inbox'`, f.rowOf(t, SlackTodayID).ID)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var cards []stCard
	for rows.Next() {
		var c stCard
		var stored string
		if err := rows.Scan(&c.title, &stored, &c.hash, &c.readAt); err != nil {
			t.Fatal(err)
		}
		if c.doc, err = blocks.Decode(stored); err != nil {
			t.Fatalf("blocks %s: %v", stored, err)
		}
		cards = append(cards, c)
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	if len(cards) != 1 || cards[0].title != "Slack today" {
		t.Fatalf("artifacts = %+v; want one Slack today", cards)
	}
	return cards[0]
}

// modelInput is the JSON input of the generator's call i.
func (f *fixture) modelInput(t *testing.T, i int) map[string]any {
	t.Helper()
	calls := f.gen.Snapshot()
	if i >= len(calls) {
		t.Fatalf("generator call %d of %d", i, len(calls))
	}
	msg := calls[i].UserMessage
	start := strings.Index(msg, "<data>\n")
	end := strings.Index(msg, "\n</data>")
	if start < 0 || end < start {
		t.Fatalf("no fenced input in %q", msg)
	}
	var in map[string]any
	if err := json.Unmarshal([]byte(msg[start+len("<data>\n"):end]), &in); err != nil {
		t.Fatal(err)
	}
	return in
}

func inputIDs(in map[string]any) []string {
	var ids []string
	for _, m := range in["messages"].([]any) {
		ids = append(ids, m.(map[string]any)["id"].(string))
	}
	return ids
}

// cardText is every block of the card as one line each, for compact checks.
func cardText(doc *blocks.Document) []string {
	var out []string
	for _, b := range doc.Blocks {
		switch {
		case b.List != nil:
			var rows []string
			for _, r := range b.List.Rows {
				badge := ""
				if r.Badge != nil {
					badge = r.Badge.Text + "/" + r.Badge.Tone + " "
				}
				rows = append(rows, badge+r.Title+" <"+r.Link+">")
			}
			out = append(out, fmt.Sprintf("list %q empty %q: %s", b.List.Title, b.List.Empty, strings.Join(rows, " | ")))
		case b.Link != nil:
			out = append(out, "link "+b.Link.Title+" <"+b.Link.URL+">")
		case b.Text != nil:
			out = append(out, "text "+b.Text.Markdown)
		default:
			out = append(out, "other "+b.Type)
		}
	}
	return out
}

func TestSlackToday_ShippedRecipeShape(t *testing.T) {
	e, ok := Lookup(SlackTodayID)
	if !ok {
		t.Fatal("no slack-today built-in")
	}
	r, err := ParseShipped(e)
	if err != nil {
		t.Fatal(err)
	}
	if r.Trigger.Kind != automations.TriggerSync || r.Trigger.Sync != string(SlotSlackToday) ||
		r.Artifacts != automations.ArtifactsLiving || r.Concurrency != 1 {
		t.Errorf("recipe = trigger %+v, artifacts %q, concurrency %d", r.Trigger, r.Artifacts, r.Concurrency)
	}
	if got := slices.Sorted(slices.Values(r.Permissions)); !slices.Equal(got, []string{"builtin:slack.window", "llm:light"}) {
		t.Errorf("permissions = %v", got)
	}
	if n := automations.LLMCallSites(r.Script); n != 1 {
		t.Errorf("LLMCallSites = %d, want 1", n)
	}
	if !strings.Contains(r.Script, `tier: "light"`) {
		t.Error(`the llm() call names no tier: "light"`)
	}
	if r.Budget.Tokens != 150000 || r.Budget.Minutes != 5 {
		t.Errorf("budget = %+v", r.Budget)
	}
	f := newFixture(t)
	f.sync(t)
	f.stOK(t, slackTodayWindow(t, ""))
	if calls := f.gen.Snapshot(); len(calls) != 1 || calls[0].Source != automations.SourceLLMLight {
		t.Errorf("generator calls = %+v; want one under %s", calls, automations.SourceLLMLight)
	}
}

func TestSlackToday_GroupsLinesByChannel(t *testing.T) {
	f := newFixture(t)
	f.sync(t)
	f.stOK(t, slackTodayWindow(t, ""))
	const link = "https://acme.slack.com/archives/"
	want := []string{
		`list "#acme-design" empty "Nothing here": ` +
			"asks you/warning Colleague C asks the team to pick the dark palette. <" + link + "C0DESIGN/p1792658700000006> | " +
			"fyi/neutral The new icons are in the shared folder. <" + link + "C0DESIGN/p1792658400000005>",
		"link Open in Slack <" + link + "C0DESIGN/p1792658700000006>",
		`list "#acme-release" empty "Nothing here": ` +
			"needs someone/info Colleague B asks who can review the release notes. <" + link + "C0ACME/p1792657200000003> | " +
			"decided/success Release 2.4 goes out on Thursday. <" + link + "C0ACME/p1792656600000001>",
		"link Open in Slack <" + link + "C0ACME/p1792657200000003>",
	}
	if got := cardText(f.stCard(t).doc); !slices.Equal(got, want) {
		t.Errorf("card =\n%s\nwant\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
}

// The golden holds news channels, compact quiet ones and a non-zero
// quiet_rest: the fixture plus 201 quiet channels of one message each, so
// two of them (the last by name) are folded.
func TestSlackToday_StateGolden(t *testing.T) {
	f := newFixture(t)
	f.sync(t)
	w := slackTodayWindow(t, "")
	rows := w.Fields["messages"].([]any)
	for _, m := range quietMsgs(201, func(int) int { return 1 }) {
		rows = append(rows, m.row())
	}
	w.Fields["messages"] = rows
	f.stOK(t, w)
	var got bytes.Buffer
	if err := json.Indent(&got, f.stRawState(t)["today"], "", "  "); err != nil {
		t.Fatal(err)
	}
	got.WriteByte('\n')
	path := filepath.Join("testdata", "slack_today_state.json")
	if *update {
		if err := os.WriteFile(path, got.Bytes(), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("%v (run with -update)", err)
	}
	if !bytes.Equal(got.Bytes(), want) {
		t.Errorf("state differs from %s (run with -update):\n%s", path, got.Bytes())
	}
}

// The prompt names every key the recipe sends to the model and every key
// and label of the reply schema, so the two cannot drift.
func TestSlackToday_ModelKeysNamedByPrompt(t *testing.T) {
	f := newFixture(t)
	f.sync(t)
	f.stOK(t, slackTodayWindow(t, ""))
	tmpl := prompts.Defaults[prompts.InboxSlackToday]
	in := f.modelInput(t, 0)
	var keys []string
	for k := range in {
		keys = append(keys, k)
	}
	if slices.Sort(keys); !slices.Equal(keys, []string{"messages", "owner"}) {
		t.Errorf("input keys = %v", keys)
	}
	keys = keys[:0]
	for k := range in["messages"].([]any)[0].(map[string]any) {
		keys = append(keys, k)
	}
	slices.Sort(keys)
	if want := []string{"author", "bot", "by_owner", "channel", "id", "text", "thread_id", "time"}; !slices.Equal(keys, want) {
		t.Errorf("message keys = %v, want %v", keys, want)
	}
	msg := f.gen.Snapshot()[0].UserMessage
	schemaAt := strings.Index(msg, "JSON Schema:\n")
	if schemaAt < 0 {
		t.Fatal("no schema in the user message")
	}
	var schema struct {
		Properties map[string]struct {
			Items struct {
				Properties map[string]struct {
					Enum []string `json:"enum"`
				} `json:"properties"`
			} `json:"items"`
		} `json:"properties"`
	}
	if err := json.Unmarshal([]byte(msg[schemaAt+len("JSON Schema:\n"):]), &schema); err != nil {
		t.Fatal(err)
	}
	named := append([]string{"owner", "messages"}, keys...)
	for k, p := range schema.Properties {
		named = append(named, k)
		for ik, ip := range p.Items.Properties {
			named = append(named, ik)
			named = append(named, ip.Enum...)
		}
	}
	if len(named) != 2+len(keys)+1+3+4 {
		t.Errorf("schema names %v; want lines{ids, label (four labels), text}", named)
	}
	for _, k := range named {
		if !strings.Contains(tmpl, `"`+k+`"`) {
			t.Errorf("the prompt does not name %q", k)
		}
	}
}

func TestSlackToday_ToOwnerNeverSentToModel(t *testing.T) {
	f := newFixture(t)
	f.sync(t)
	f.stOK(t, slackTodayWindow(t, ""))
	if ids := inputIDs(f.modelInput(t, 0)); slices.Contains(ids, stReleaseToMe) || len(ids) != 8 {
		t.Errorf("model input ids = %v; want the 8 not addressed to the owner", ids)
	}
	s := f.stState(t)
	if s.Messages != 9 || s.Channels["1:C0ACME"].N != 4 || s.Channels["1:C0RANDOM"].N != 2 {
		t.Errorf("state counts = %d, %+v; want 9 with the to-owner message counted", s.Messages, s.Channels)
	}
}

func TestSlackToday_NoModelCallWithoutInput(t *testing.T) {
	f := newFixture(t)
	f.sync(t)
	at := testStart.Add(-time.Hour)
	f.stOK(t, stWindow("2026-10-22", 0,
		stMsg{"C0ACME", "acme-release", "1792656600.000001", "<@U0OWNER> ping", at, true},
		stMsg{"C0ACME", "acme-release", "1792656601.000002", "<@U0OWNER> again", at, true}))
	if n := f.gen.CallCount(); n != 0 {
		t.Errorf("generator calls = %d; want 0", n)
	}
	if s := f.stState(t); s.Messages != 2 || s.Channels["1:C0ACME"].N != 2 || len(s.Channels["1:C0ACME"].Lines) != 0 {
		t.Errorf("state = %+v", s)
	}
	if got := cardText(f.stCard(t).doc); !slices.Equal(got, []string{`list "" empty "Nothing for you in your channels yet today": `}) {
		t.Errorf("card = %v", got)
	}
}

func TestSlackToday_UnknownIDsDropped(t *testing.T) {
	f := newFixture(t)
	f.sync(t)
	f.stOK(t, slackTodayWindow(t, ""), stReply(t,
		stLine{IDs: []string{stReleaseNotes, "1:C0ACME/1000.000000"}, Label: "asks_you", Text: "Made up."},
		stLine{IDs: []string{stReleaseToMe}, Label: "asks_you", Text: "Addressed to the owner."},
		stLine{IDs: []string{stIcons}, Label: "fyi", Text: "The new icons are in."}))
	s := f.stState(t)
	if l := s.Channels["1:C0ACME"].Lines; len(l) != 0 {
		t.Errorf("#acme-release lines = %+v; want none", l)
	}
	if l := s.Channels["1:C0DESIGN"].Lines; len(l) != 1 || l[0].Text != "The new icons are in." {
		t.Errorf("#acme-design lines = %+v", l)
	}
	for _, line := range cardText(f.stCard(t).doc) {
		if strings.Contains(line, "Made up") || strings.Contains(line, "Addressed") {
			t.Errorf("card line %q holds a dropped line", line)
		}
	}
}

func TestSlackToday_SecondRunMerges(t *testing.T) {
	f := newFixture(t)
	f.sync(t)
	f.stOK(t, slackTodayWindow(t, ""))
	m := stMsg{"C0ACME", "acme-release", "1792660000.000010", "The build is green.", testStart, false}
	f.stOK(t, stWindow("2026-10-22", 0, m), stReply(t, stLine{IDs: []string{m.id()}, Label: "fyi", Text: "The build is green."}))
	if ids := inputIDs(f.modelInput(t, 1)); !slices.Equal(ids, []string{m.id()}) {
		t.Errorf("run 2 model input = %v; want only run 2's message", ids)
	}
	s := f.stState(t)
	var texts []string
	for _, l := range s.Channels["1:C0ACME"].Lines {
		texts = append(texts, l.Text)
	}
	if want := []string{"Colleague B asks who can review the release notes.", "Release 2.4 goes out on Thursday.", "The build is green."}; !slices.Equal(texts, want) {
		t.Errorf("#acme-release lines = %v, want %v", texts, want)
	}
	if s.Messages != 10 || s.Channels["1:C0ACME"].N != 5 || len(s.Channels["1:C0DESIGN"].Lines) != 2 {
		t.Errorf("state = %+v", s)
	}
}

func TestSlackToday_DayChangeResetsState(t *testing.T) {
	f := newFixture(t)
	f.sync(t)
	yesterday := slackTodayWindow(t, "")
	yesterday.Fields["day"] = "2026-10-21"
	f.stOK(t, yesterday)
	m := stMsg{"C0OPS", "acme-ops", "1792660000.000010", "Deploy at noon.", testStart, false}
	f.stOK(t, stWindow("2026-10-22", 0, m), stReply(t, stLine{IDs: []string{m.id()}, Label: "fyi", Text: "Deploy at noon."}))
	s := f.stState(t)
	if s.Day != "2026-10-22" || s.Messages != 1 || len(s.Channels) != 1 || len(s.Channels["1:C0OPS"].Lines) != 1 {
		t.Errorf("state = %+v; want only today's channel", s)
	}
}

func TestSlackToday_QuietMessagesKeepContentHash(t *testing.T) {
	f := newFixture(t)
	f.sync(t)
	f.stOK(t, slackTodayWindow(t, ""))
	before := f.stCard(t)
	if _, err := f.d.Exec(`UPDATE automation_outputs SET read_at = '2026-10-22T09:01:00Z' WHERE output_key = 'slack-today'`); err != nil {
		t.Fatal(err)
	}
	quiet := stMsg{"C0RANDOM", "acme-random", "1792660000.000010", "Coffee?", testStart, false}
	f.stOK(t, stWindow("2026-10-22", 0, quiet), `{"lines": []}`)
	after := f.stCard(t)
	if after.hash != before.hash || after.readAt == nil {
		t.Errorf("hash %s → %s, read_at %v; want the same hash and the card still read", before.hash, after.hash, after.readAt)
	}
	if s := f.stState(t); s.Messages != 10 {
		t.Errorf("messages = %d; want 10", s.Messages)
	}
}

func TestSlackToday_LineCaps(t *testing.T) {
	t.Run("one channel", func(t *testing.T) {
		f := newFixture(t)
		f.sync(t)
		labels := []string{"fyi", "decided", "asks_you", "fyi", "needs_someone", "decided", "fyi", "asks_you", "decided", "needs_someone"}
		var msgs []stMsg
		var lines []stLine
		for i, label := range labels {
			m := stMsg{"C0ACME", "acme-release", fmt.Sprintf("17926566%02d.0000%02d", i, i), "x", testStart.Add(time.Duration(i-20) * time.Minute), false}
			msgs = append(msgs, m)
			lines = append(lines, stLine{IDs: []string{m.id()}, Label: label, Text: fmt.Sprintf("%s %d", label, i)})
		}
		f.stOK(t, stWindow("2026-10-22", 0, msgs...), stReply(t, lines...))
		c := f.stState(t).Channels["1:C0ACME"]
		var got []string
		for _, l := range c.Lines {
			got = append(got, l.Text)
		}
		if want := []string{"asks_you 7", "asks_you 2", "needs_someone 9", "needs_someone 4", "decided 8", "decided 5"}; !slices.Equal(got, want) || c.More != 4 {
			t.Errorf("lines %v more %d; want %v more 4", got, c.More, want)
		}
		list := f.stCard(t).doc.Blocks[0].List
		last := list.Rows[len(list.Rows)-1]
		if len(list.Rows) != 7 || last.Title != "4 more lines — open the channel to read them" || last.Badge != nil ||
			last.Link != msgs[9].row()["permalink"] {
			t.Errorf("rows = %+v; want 6 lines and the more row linking the newest line", list.Rows)
		}
	})
	t.Run("day", func(t *testing.T) {
		f := newFixture(t)
		f.sync(t)
		var msgs []stMsg
		var lines []stLine
		for i := range 200 {
			ch := fmt.Sprintf("C0CH%04d", i%40)
			m := stMsg{ch, fmt.Sprintf("acme-%02d", i%40), fmt.Sprintf("1792650000.%06d", i), "x", testStart.Add(time.Duration(i-300) * time.Minute), false}
			msgs = append(msgs, m)
			lines = append(lines, stLine{IDs: []string{m.id()}, Label: "fyi", Text: fmt.Sprintf("line %d", i)})
		}
		f.stOK(t, stWindow("2026-10-22", 0, msgs...), stReply(t, lines...))
		kept, more := 0, 0
		for _, c := range f.stState(t).Channels {
			kept += len(c.Lines)
			more += c.More
			for _, l := range c.Lines {
				var i int
				if _, err := fmt.Sscanf(l.Text, "line %d", &i); err != nil || i < 110 {
					t.Errorf("kept %q; want only the newest 90", l.Text)
				}
			}
		}
		doc := f.stCard(t).doc
		if kept != 90 || more != 110 || len(doc.Blocks) > 39 {
			t.Errorf("kept %d more %d blocks %d; want 90, 110, at most 39", kept, more, len(doc.Blocks))
		}
	})
	t.Run("channels", func(t *testing.T) {
		f := newFixture(t)
		f.sync(t)
		var msgs []stMsg
		var lines []stLine
		for i := range 25 {
			m := stMsg{fmt.Sprintf("C0CH%04d", i), fmt.Sprintf("acme-%02d", i), fmt.Sprintf("1792650000.%06d", i), "x", testStart.Add(-time.Duration(i) * time.Minute), false}
			msgs = append(msgs, m)
			lines = append(lines, stLine{IDs: []string{m.id()}, Label: "fyi", Text: fmt.Sprintf("line %d", i)})
		}
		f.stOK(t, stWindow("2026-10-22", 0, msgs...), stReply(t, lines...))
		got := cardText(f.stCard(t).doc)
		if len(got) != 37 || got[36] != "text 7 more channels with news: #acme-18, #acme-19, #acme-20, #acme-21, #acme-22, #acme-23, #acme-24" {
			t.Errorf("%d blocks, last %q; want 18 channels (36 blocks) and the more-channels line", len(got), got[len(got)-1])
		}
	})
}

func TestSlackToday_MissedTailNamedAfterMidnight(t *testing.T) {
	f := newFixture(t)
	f.sync(t)
	w := slackTodayWindow(t, "")
	w.Fields["below_floor"] = 12
	f.stOK(t, w)
	if s := f.stState(t); s.MissedYesterday != 12 {
		t.Errorf("missed_yesterday = %d; want 12", s.MissedYesterday)
	}
	first := f.stCard(t)
	got := cardText(first.doc)
	if got[len(got)-1] != "text 12 messages from late yesterday were not read." {
		t.Errorf("card = %v", got)
	}
	f.stOK(t, stWindow("2026-10-22", 0), `{"lines": []}`)
	if f.stCard(t).hash != first.hash || f.stState(t).MissedYesterday != 12 {
		t.Error("the next run moved the hash or the missed count")
	}
}

func TestSlackToday_EmptyDay(t *testing.T) {
	f := newFixture(t)
	f.sync(t)
	f.stOK(t, stWindow("2026-10-22", 0))
	if n := f.gen.CallCount(); n != 0 {
		t.Errorf("generator calls = %d", n)
	}
	if got := cardText(f.stCard(t).doc); !slices.Equal(got, []string{`list "" empty "Nothing for you in your channels yet today": `}) {
		t.Errorf("card = %v", got)
	}
	if s := f.stState(t); s.V != 1 || s.Day != "2026-10-22" || s.Messages != 0 || len(s.Channels) != 0 {
		t.Errorf("state = %+v", s)
	}
}

// quietChan is quiet channel i's id (not Slack-id-shaped, for leak-check).
func quietChan(i int) string { return fmt.Sprintf("CQ%04d", i) }

// quietMsgs is n messages addressed to the owner (so never sent to the
// model), in n channels "acme-quiet-NNNN", count(i) messages in channel i.
func quietMsgs(n int, count func(int) int) []stMsg {
	var msgs []stMsg
	for i := range n {
		for j := range count(i) {
			msgs = append(msgs, stMsg{quietChan(i), fmt.Sprintf("acme-quiet-%04d", i),
				fmt.Sprintf("1792640000.%06d", i*100+j), "x", testStart.Add(-time.Duration(i) * time.Second), true})
		}
	}
	return msgs
}

// A heavy day — 400 or 2000 channels, 90 of them with one line of 160
// Cyrillic characters each — stays under the state cap, read in windows of
// at most 500 messages.
func TestSlackToday_HeavyDayStateUnderLimit(t *testing.T) {
	for _, channels := range []int{400, 2000} {
		t.Run(fmt.Sprint(channels), func(t *testing.T) {
			f := newFixture(t)
			f.sync(t)
			text := strings.Repeat("Ж", 200)
			msgs := quietMsgs(channels-90, func(int) int { return 1 })
			var lines []stLine
			for i := range 90 {
				m := stMsg{fmt.Sprintf("D%010d", i), fmt.Sprintf("acme-team-%03d-room", i), fmt.Sprintf("1792650000.%06d", i), "x",
					testStart.Add(-time.Duration(i) * time.Second), false}
				msgs = append(msgs, m)
				lines = append(lines, stLine{IDs: []string{m.id()}, Label: "needs_someone", Text: text})
			}
			// A real window holds at most 500 messages: the day comes in runs
			// of 500, the lines in the last.
			for start := 0; start < len(msgs); start += db.SlackWindowMaxMessages {
				f.stOK(t, stWindow("2026-10-22", 0, msgs[start:min(start+db.SlackWindowMaxMessages, len(msgs))]...), stReply(t, lines...))
			}
			raw, err := f.d.GetAutomationState(f.rowOf(t, SlackTodayID).ID)
			if err != nil {
				t.Fatal(err)
			}
			t.Logf("heavy-day state, %d channels: %d bytes (limit %d)", channels, len(raw), automations.MaxStateBytes)
			if len(raw) > automations.MaxStateBytes {
				t.Errorf("state is %d bytes; the limit is %d", len(raw), automations.MaxStateBytes)
			}
			s := f.stState(t)
			kept, news := len(s.Channels), 0
			for _, c := range s.Channels {
				if len(c.Lines) > 0 {
					news++
				}
				for _, l := range c.Lines {
					if n := utf8.RuneCountInString(l.Text); n != 160 {
						t.Fatalf("line of %d characters; want cut to 160", n)
					}
				}
			}
			wantQuiet := min(channels-90, QuietKeepForTest)
			if news != 90 || kept != 90+wantQuiet || s.QuietRest.Channels != channels-90-wantQuiet ||
				s.Messages != channels {
				t.Errorf("news %d kept %d quiet_rest %+v messages %d", news, kept, s.QuietRest, s.Messages)
			}
		})
	}
}

// QuietKeepForTest is the recipe's QUIET_KEEP.
const QuietKeepForTest = 200

// 250 quiet channels: the 200 busiest are kept, compact; the other 50 are
// folded into quiet_rest with their messages.
func TestSlackToday_QuietChannelsFoldPast200(t *testing.T) {
	f := newFixture(t)
	f.sync(t)
	count := func(i int) int { return 1 + (250-i)/50 } // channel 0 busiest: 6, …, channels 200–249: 1
	f.stOK(t, stWindow("2026-10-22", 0, quietMsgs(250, count)...))
	s := f.stState(t)
	folded := 0
	for i := 200; i < 250; i++ {
		folded += count(i)
	}
	if len(s.Channels) != 200 || s.QuietRest.Channels != 50 || s.QuietRest.Messages != folded {
		t.Errorf("%d kept, quiet_rest %+v; want 200 and {50 %d}", len(s.Channels), s.QuietRest, folded)
	}
	for i := range 200 {
		if _, ok := s.Channels["1:"+quietChan(i)]; !ok {
			t.Fatalf("channel %d (of the 200 busiest) was folded", i)
		}
	}
	var raw map[string]map[string]json.RawMessage
	if err := json.Unmarshal(f.stRawState(t)["today"], &struct {
		Channels *map[string]map[string]json.RawMessage `json:"channels"`
	}{&raw}); err != nil {
		t.Fatal(err)
	}
	for id, c := range raw {
		if len(c) != 2 || c["name"] == nil || c["n"] == nil {
			t.Fatalf("quiet channel %s = %v; want only name and n", id, c)
		}
	}
	// A second run adds to quiet_rest.messages only through a new fold.
	f.stOK(t, stWindow("2026-10-22", 0, quietMsgs(1, func(int) int { return 1 })...))
	if s2 := f.stState(t); s2.Channels["1:"+quietChan(0)].N != 7 || s2.QuietRest != s.QuietRest {
		t.Errorf("second run: busiest n %d, quiet_rest %+v", s2.Channels["1:"+quietChan(0)].N, s2.QuietRest)
	}
}

// A window cut at its caps by the real primitive still fits llm()'s input.
func TestSlackToday_FullWindowFitsLLMInput(t *testing.T) {
	for name, text := range map[string]string{
		"short texts":        "ok",
		"escape-heavy texts": strings.Repeat(`<&> "Ж" \ `, 100),
	} {
		t.Run(name, func(t *testing.T) {
			f := newFixture(t)
			now := time.Date(2026, 10, 22, 12, 0, 0, 0, time.Local)
			f.clock.Set(now)
			f.sync(t)
			seedSlackToday(t, f.d, 600, text, now)
			res, err := SlackWindowPrimitives(f.d, f.clock.Now)[automations.PrimitiveSlackWindow](context.Background(),
				automations.PrimitiveCall{Name: automations.PrimitiveSlackWindow, BuiltinID: SlackTodayID, Floor: "today"})
			if err != nil || res.Fields["truncated"] != true {
				t.Fatalf("window = %v truncated, %v; want a cut window", res.Fields["truncated"], err)
			}
			t.Logf("window of %d messages", res.Fields["count"])
			run := f.stRun(t, res, `{"lines": []}`)
			if run.Status != db.RunSucceeded || f.gen.CallCount() != 1 {
				t.Fatalf("run = %s (%s), %d generator calls; want succeeded with one call", run.Status, run.Error, f.gen.CallCount())
			}
		})
	}
}

// seedSlackToday adds account 1 (owner 1:U0OWNER) with the member channel
// 1:C0ACME and n messages from Colleague A with text, the last a minute
// before now.
func seedSlackToday(t *testing.T, d *db.DB, n int, text string, now time.Time) {
	t.Helper()
	if _, err := d.CreateSlackAccount(db.SlackAccount{TeamID: "T1", TeamName: "acme", TeamDomain: "acme",
		CurrentUserID: "1:U0OWNER"}); err != nil {
		t.Fatal(err)
	}
	for _, q := range []string{
		`INSERT INTO users (id, name, display_name) VALUES ('1:U0OWNER', 'owner', 'Owner A'), ('1:U0COLA', 'cola', 'Colleague A')`,
		`INSERT INTO channels (id, name, type, is_member) VALUES ('1:C0ACME', 'acme-release', 'public', 1)`,
	} {
		if _, err := d.Exec(q); err != nil {
			t.Fatal(err)
		}
	}
	for i := range n {
		at := now.Add(-time.Minute - time.Duration(n-i)*time.Second)
		ts := fmt.Sprintf("%d.%06d", at.Unix(), i)
		if _, err := d.Exec(`INSERT INTO messages (channel_id, ts, user_id, text, permalink) VALUES ('1:C0ACME', ?, '1:U0COLA', ?, ?)`,
			ts, fmt.Sprintf("%s %d", text, i), "https://acme.slack.com/archives/C0ACME/p"+strings.ReplaceAll(ts, ".", "")); err != nil {
			t.Fatal(err)
		}
	}
}

func TestSlackToday_FailedLLMKeepsCursorAndArtifact(t *testing.T) {
	f := newFixture(t)
	f.sync(t)
	w := slackTodayWindow(t, "")
	w.NextCursor = 42
	f.stOK(t, w)
	stateBefore, outputsBefore := f.stRawState(t), f.outputsSnapshot(t)
	boom := errors.New("model down")
	f.gen.Errors = []error{nil, boom, boom, boom, boom}
	m := stMsg{"C0ACME", "acme-release", "1792660000.000010", "News.", testStart, false}
	next := stWindow("2026-10-22", 0, m)
	next.NextCursor = 99
	if run := f.stRun(t, next); run.Status != db.RunFailed {
		t.Fatalf("run = %s (%s); want failed", run.Status, run.Error)
	}
	stateAfter := f.stRawState(t)
	for _, k := range []string{"today", automations.WindowStateKeyPrefix + "slack"} {
		if !bytes.Equal(stateAfter[k], stateBefore[k]) {
			t.Errorf("state %q: %s → %s; want unchanged", k, stateBefore[k], stateAfter[k])
		}
	}
	if after := f.outputsSnapshot(t); after != outputsBefore {
		t.Errorf("outputs changed by a failed run:\nbefore %s\nafter  %s", outputsBefore, after)
	}
}

func TestSlackToday_SkippedPrimitiveWritesNothingNew(t *testing.T) {
	skipped := automations.PrimitiveResult{Status: "skipped", Fields: map[string]any{"reason": "source_off", "messages": []any{}}}
	t.Run("after a run", func(t *testing.T) {
		f := newFixture(t)
		f.sync(t)
		f.stOK(t, slackTodayWindow(t, ""))
		state, card := f.stRawState(t)["today"], f.stCard(t)
		f.stOK(t, skipped)
		if n := f.gen.CallCount(); n != 1 {
			t.Errorf("generator calls = %d; want only run 1's", n)
		}
		if after := f.stRawState(t)["today"]; !bytes.Equal(after, state) {
			t.Errorf("today: %s → %s", state, after)
		}
		if after := f.stCard(t); after.hash != card.hash {
			t.Error("the card changed")
		}
	})
	t.Run("first run", func(t *testing.T) {
		f := newFixture(t)
		f.sync(t)
		f.stOK(t, skipped)
		if _, has := f.stRawState(t)["today"]; has || f.gen.CallCount() != 0 {
			t.Errorf("state %v, %d calls; want no today and no call", f.stRawState(t), f.gen.CallCount())
		}
		if got := cardText(f.stCard(t).doc); !slices.Equal(got, []string{`list "" empty "Nothing for you in your channels yet today": `}) {
			t.Errorf("card = %v", got)
		}
	})
}

// A DM and a group DM keep their own headings; a channel name's markdown
// characters are escaped in the more-channels line.
func TestSlackToday_HeadingsOfDMsAndGroups(t *testing.T) {
	f := newFixture(t)
	f.sync(t)
	var msgs []stMsg
	var lines []stLine
	for i := range 20 {
		m := stMsg{fmt.Sprintf("C0CH%04d", i), fmt.Sprintf("acme_%02d", i), fmt.Sprintf("1792650000.%06d", i), "x", testStart.Add(-time.Duration(i) * time.Minute), false}
		msgs = append(msgs, m)
		lines = append(lines, stLine{IDs: []string{m.id()}, Label: "fyi", Text: fmt.Sprintf("line %d", i)})
	}
	w := stWindow("2026-10-22", 0, msgs...)
	rows := w.Fields["messages"].([]any)
	rows[0].(map[string]any)["channel"] = "@Colleague B"
	rows[1].(map[string]any)["channel"] = "Colleague B, Colleague C"
	f.stOK(t, w, stReply(t, lines...))
	got := cardText(f.stCard(t).doc)
	if !strings.HasPrefix(got[0], `list "@Colleague B"`) || !strings.HasPrefix(got[2], `list "Colleague B, Colleague C"`) ||
		!strings.HasPrefix(got[4], `list "#acme_02"`) {
		t.Errorf("headings = %v", got)
	}
	if last := got[len(got)-1]; last != `text 2 more channels with news: #acme\_18, #acme\_19` {
		t.Errorf("last = %q", last)
	}
	if s := f.stState(t); s.Channels["1:C0CH0000"].Name != "@Colleague B" || s.Channels["1:C0CH0002"].Name != "acme_02" {
		t.Errorf("names = %+v", s.Channels)
	}
}

func TestRegistry_SlackTodayEntry(t *testing.T) {
	e, ok := Lookup(SlackTodayID)
	if !ok {
		t.Fatal("no slack-today built-in")
	}
	if e.Name != "Slack today" || e.Slot != SlotSlackToday || !slices.Equal(e.FeatureIDs, []string{"slack-today"}) ||
		!slices.Equal(e.Primitives, []string{automations.PrimitiveSlackWindow}) ||
		!slices.Equal(e.Prompts, []PromptRef{{Name: "label", PromptID: prompts.InboxSlackToday}}) ||
		len(e.Parameters) != 0 || len(e.Pipelines) != 0 || e.WindowScope != db.WindowScopeMemberChannels ||
		e.DefaultFolder != RootFolder || !e.RunNow || e.NoRunNowNote != "" {
		t.Errorf("entry = %+v", e)
	}
	if !slices.Equal(e.Reads, []string{"Today's messages in the Slack channels you are a member of, except channels muted for AI"}) ||
		!slices.Equal(e.Does, []string{
			"Reads the new messages in your channels since its last run, today only",
			"Marks each line decided, asks you, needs someone or fyi, and leaves out what is addressed to you personally",
			"Keeps one Slack today list in your Inbox, updated at most once an hour",
		}) || !slices.Equal(e.Sends, []string{"One Slack today list in your Inbox"}) ||
		e.When(nil) != "After a sync, at most once an hour" {
		t.Errorf("card copy = %+v / %+v / %+v / %q", e.Reads, e.Does, e.Sends, e.When(nil))
	}
	ids := allIDs()
	if i := slices.Index(ids, SlackTodayID); i < 1 || ids[i-1] != waitingID {
		t.Errorf("card order = %v; want slack-today right after waiting-for-me", ids)
	}
	if !slices.Contains(automations.SyncSlots, string(SlotSlackToday)) {
		t.Errorf("SyncSlots = %v", automations.SyncSlots)
	}
}

func TestCardGolden_SlackToday(t *testing.T) {
	f := newFixture(t)
	f.sync(t)
	e, _ := Lookup(SlackTodayID)
	checkCardGolden(t, f, e)
}
