package specreview

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/sessionfeed"
)

type threadKeyCase struct {
	WorkbenchID int64  `json:"workbench_id"`
	RootAskID   int64  `json:"root_ask_id"`
	ItemKey     string `json:"item_key"`
	ContextID   string `json:"context_id"`
}

// The Swift twin reads the same fixture: both sides compute one key.
func TestThreadContextID_Fixture(t *testing.T) {
	data, err := os.ReadFile("testdata/thread_keys.json")
	require.NoError(t, err)
	var cases []threadKeyCase
	require.NoError(t, json.Unmarshal(data, &cases))
	require.NotEmpty(t, cases)
	for _, c := range cases {
		assert.Equal(t, c.ContextID, ThreadContextID(c.WorkbenchID, c.RootAskID, c.ItemKey))
		wb, root, key, ok := ParseThreadContextID(c.ContextID)
		require.True(t, ok, c.ContextID)
		assert.Equal(t, c.WorkbenchID, wb)
		assert.Equal(t, c.RootAskID, root)
		assert.Equal(t, c.ItemKey, key)
	}
}

func TestThreadContextID_ParseRefusesMalformed(t *testing.T) {
	for _, s := range []string{"", "1", "1:2", "1:2:", ":2:k", "1::k", "a:2:k", "1:b:k",
		"0:2:k", "1:0:k", "-1:2:k", "+1:2:k", "01:2:k", "1:02:k", "99999999999999999999:2:k"} {
		_, _, _, ok := ParseThreadContextID(s)
		assert.False(t, ok, "%q", s)
	}
}

func TestQuestionTimeout_IsAuthorTimeout(t *testing.T) {
	assert.Equal(t, AuthorTimeout, QuestionTimeout)
}

const threadDoc = "# Spec\n\nGoal: mute a channel for a day.\n\n## Behaviour\n\nMuting lasts twenty-four hours.\n\n## Storage\n\nThe mute is stored per channel.\n"

func TestValidateThreadFinding_DocumentQuote(t *testing.T) {
	f, err := ValidateThreadFinding(ThreadFindingInput{
		Kind: "differs", Severity: " Major ", Title: "  Day length  ", Text: "A day is not always 24 hours.",
		Quote: ThreadQuote{Source: "document", Text: "Muting   lasts twenty-four hours."},
	}, threadDoc, Spec, nil)
	require.NoError(t, err)
	assert.Equal(t, "differs", f.Kind)
	assert.Equal(t, SeverityMajor, f.Severity)
	assert.Equal(t, "Day length", f.Title)
	assert.Equal(t, SpeakerAgent, f.Speaker, "the document is the author's side")
	assert.Equal(t, "", f.Chapter, "no where-quote: Other")
	assert.Nil(t, f.Where)
	assert.Equal(t, itemKey("tf:", "A day is not always 24 hours.", ""), f.Key)
	assert.True(t, strings.HasPrefix(f.Key, "tf:"))
}

func TestValidateThreadFinding_OwnerThreadQuote(t *testing.T) {
	owner := []string{"why a day?", "I want the mute to end at midnight, not after 24 hours"}
	f, err := ValidateThreadFinding(ThreadFindingInput{
		Kind: "missing", Title: "Midnight", Text: "The owner wants the mute to end at midnight.",
		Quote: ThreadQuote{Source: "thread", Text: "end at midnight, not after 24 hours"},
	}, threadDoc, Spec, owner)
	require.NoError(t, err)
	assert.Equal(t, SpeakerOwner, f.Speaker)
	assert.Equal(t, "", f.Severity, "an unknown or empty severity stays empty")

	// The owner's words are not the document, and the document is not the
	// owner's words.
	_, err = ValidateThreadFinding(ThreadFindingInput{
		Kind: "missing", Title: "Midnight", Text: "x",
		Quote: ThreadQuote{Source: "document", Text: "end at midnight, not after 24 hours"},
	}, threadDoc, Spec, owner)
	assert.ErrorIs(t, err, ErrQuoteNotFound)
	_, err = ValidateThreadFinding(ThreadFindingInput{
		Kind: "missing", Title: "Midnight", Text: "x",
		Quote: ThreadQuote{Source: "thread", Text: "Muting lasts twenty-four hours."},
	}, threadDoc, Spec, owner)
	assert.ErrorIs(t, err, ErrQuoteNotFound)
}

// The caller hands only the owner's rows: the agent's own reply is not among
// them, so a quote of it is not found.
func TestValidateThreadFinding_AgentWordsRefused(t *testing.T) {
	owner := []string{"why a day?"}
	_, err := ValidateThreadFinding(ThreadFindingInput{
		Kind: "blind_spot", Title: "DST", Text: "Daylight saving makes a day 23 hours.",
		Quote: ThreadQuote{Source: "thread", Text: "daylight saving makes a day 23 hours"},
	}, threadDoc, Spec, owner)
	require.ErrorIs(t, err, ErrQuoteNotFound)
	assert.EqualError(t, err, "not added: quote not found")

	for _, q := range []ThreadQuote{
		{Source: "document", Text: "short"},                            // under the minimum
		{Source: "elsewhere", Text: "Muting lasts twenty-four hours."}, // unknown source
		{Source: "document", Text: ""},
	} {
		_, err := ValidateThreadFinding(ThreadFindingInput{Kind: "differs", Title: "t", Text: "x", Quote: q}, threadDoc, Spec, owner)
		assert.ErrorIs(t, err, ErrQuoteNotFound, "%+v", q)
	}
}

func TestValidateThreadFinding_BadKind(t *testing.T) {
	for _, k := range []string{"", "as_agreed", "check", "Differs"} {
		_, err := ValidateThreadFinding(ThreadFindingInput{
			Kind: k, Title: "t", Text: "x", Quote: ThreadQuote{Source: "document", Text: "Muting lasts twenty-four hours."},
		}, threadDoc, Spec, nil)
		require.Error(t, err, k)
		assert.Contains(t, err.Error(), "not added: ", k)
		assert.NotErrorIs(t, err, ErrQuoteNotFound)
	}
	for name, in := range map[string]ThreadFindingInput{
		"no text":  {Kind: "differs", Title: "t", Text: "  "},
		"no title": {Kind: "differs", Title: " ", Text: "x"},
	} {
		in.Quote = ThreadQuote{Source: "document", Text: "Muting lasts twenty-four hours."}
		_, err := ValidateThreadFinding(in, threadDoc, Spec, nil)
		assert.Error(t, err, name)
	}
}

func TestValidateThreadFinding_WhereChapter(t *testing.T) {
	in := ThreadFindingInput{
		Kind: "decided_alone", Severity: "blocker", Title: "Per channel", Text: "Storage per channel was never agreed.",
		Quote: ThreadQuote{Source: "document", Text: "stored per channel"},
		Where: &Anchor{Heading: "## storage", Quote: "The mute is stored per channel."},
	}
	f, err := ValidateThreadFinding(in, threadDoc, Spec, nil)
	require.NoError(t, err)
	chapters := Chapters(threadDoc, Spec)
	assert.Equal(t, chapters[2].Key, f.Chapter)
	require.NotNil(t, f.Where)
	assert.Equal(t, "Storage", f.Where.Heading, "the document's own heading")
	assert.Equal(t, itemKey("tf:", in.Text, in.Where.Quote), f.Key)
	assert.NotEqual(t, itemKey("tf:", in.Text, ""), f.Key, "the where-quote is part of the key")

	// A where-quote under the wrong heading, or nowhere, is refused.
	in.Where = &Anchor{Heading: "Behaviour", Quote: "The mute is stored per channel."}
	_, err = ValidateThreadFinding(in, threadDoc, Spec, nil)
	assert.ErrorIs(t, err, ErrQuoteNotFound)
	in.Where = &Anchor{Heading: "Storage", Quote: "The mute is stored per user."}
	_, err = ValidateThreadFinding(in, threadDoc, Spec, nil)
	assert.ErrorIs(t, err, ErrQuoteNotFound)
}

// threadBlockCase is one testdata/thread_blocks fixture: an agent reply and
// the blocks a parser takes from it (the last valid block of each fence
// wins; null when none). The Swift parser test reads the same files.
type threadBlockCase struct {
	Reply    string          `json:"reply"`
	Question *string         `json:"question"`
	Finding  json.RawMessage `json:"finding"`
}

func TestThreadBlockFixtures_DecodeAndValidateShape(t *testing.T) {
	files, err := filepath.Glob("testdata/thread_blocks/*.json")
	require.NoError(t, err)
	require.NotEmpty(t, files)
	var questions, findings int
	for _, file := range files {
		t.Run(filepath.Base(file), func(t *testing.T) {
			data, err := os.ReadFile(file)
			require.NoError(t, err)
			var c threadBlockCase
			dec := json.NewDecoder(bytes.NewReader(data))
			dec.DisallowUnknownFields()
			require.NoError(t, dec.Decode(&c))
			require.NotEmpty(t, c.Reply)
			if c.Question != nil {
				questions++
				assert.NotEmpty(t, strings.TrimSpace(*c.Question))
				assert.Contains(t, c.Reply, "```"+AskAuthorFence)
			}
			if len(c.Finding) == 0 || string(c.Finding) == "null" {
				return
			}
			findings++
			assert.Contains(t, c.Reply, "```"+FindingFence)
			var in ThreadFindingInput
			fd := json.NewDecoder(bytes.NewReader(c.Finding))
			fd.DisallowUnknownFields()
			require.NoError(t, fd.Decode(&in))
			assert.True(t, validThreadFindingKind(in.Kind), in.Kind)
			assert.Contains(t, []string{QuoteDocument, QuoteThread}, in.Quote.Source)
			assert.NotEmpty(t, in.Title)
			assert.NotEmpty(t, in.Text)
			assert.NotEmpty(t, in.Quote.Text)
		})
	}
	assert.Positive(t, questions, "some fixture holds a question")
	assert.Positive(t, findings, "some fixture holds a finding")
}

func TestThreadContext_BlocksAndLookup(t *testing.T) {
	f := newFixture(t)
	f.feed = []sessionfeed.Entry{
		{ID: "e1", Kind: sessionfeed.KindOwner, At: runNow, Text: "Mute it for one calendar day"},
		{ID: "e2", Kind: sessionfeed.KindAgent, At: runNow, Text: "Writing the spec now"},
	}
	var qid int64
	require.NoError(t, f.d.WithTx(func(tx *sql.Tx) error {
		var err error
		qid, _, err = f.d.InsertOwnerAsk(tx, db.OwnerAsk{WorkbenchID: f.wb, SessionID: sql.NullInt64{Int64: f.session, Valid: true},
			Kind: "question", Title: "Scope?", Payload: `{"questions":[{"id":"q1","question":"How long?","options":[{"label":"One day"},{"label":"A week"}]}]}`})
		return err
	}))
	_, err := f.d.Exec(`UPDATE owner_asks SET status = 'answered', answer = ? WHERE id = ?`,
		`{"answers":[{"id":"q1","labels":["One day"],"other":""}],"checklist":[],"comments":[],"note":"","verdict":""}`, qid)
	require.NoError(t, err)
	a := f.ask(t, "spec", threadDoc)

	res, err := Parse(`{"summary":"s","decided_alone":[{"text":"Stored per channel","where":{"heading":"Storage","quote":"The mute is stored per channel."}}],`+
		`"theses":[{"kind":"goal","text":"Mute a channel for a day","where":{"heading":"","quote":"Goal: mute a channel for a day."}}]}`,
		Sources{Doc: threadDoc}, Spec)
	require.NoError(t, err)
	require.Len(t, res.DecidedAlone, 1)
	require.Len(t, res.Theses, 1)
	js, err := json.Marshal(res)
	require.NoError(t, err)
	ledger := `[{"key":"bs:aaaaaaaaaaaa","kind":"blind_spot","text":"Settled one","note":"","round":1,"verdict":"resolved","verdict_note":"fixed","settled":2}]`
	_, err = f.d.Exec(`UPDATE spec_reviews SET status = 'done', result = ?, ledger = ?, replies = '[{"key":"bs:aaaaaaaaaaaa","reply":"fixed","note":"done"}]' WHERE ask_id = ?`,
		string(js), ledger, a.ID)
	require.NoError(t, err)
	tf, err := ValidateThreadFinding(ThreadFindingInput{Kind: "differs", Title: "Day", Text: "A day differs",
		Quote: ThreadQuote{Source: QuoteDocument, Text: "Muting lasts twenty-four hours."}}, threadDoc, Spec, nil)
	require.NoError(t, err)
	tfJS, err := json.Marshal(tf)
	require.NoError(t, err)
	require.NoError(t, f.d.InsertSpecReviewThreadFinding(db.SpecReviewThreadFinding{AskID: a.ID, ItemKey: tf.Key,
		Thread: "1:1:x", Finding: string(tfJS), CreatedAt: runNow.Format(time.RFC3339)}))

	_, user, _, err := BuildInputs(context.Background(), f.deps(nil), a, f.folder)
	require.NoError(t, err)
	for key, kind := range map[string]string{
		res.DecidedAlone[0].Key: KindDecidedAlone,
		res.Theses[0].Key:       "thesis",
		"bs:aaaaaaaaaaaa":       "ledger",
		tf.Key:                  "thread_finding",
	} {
		out, err := ThreadContext(context.Background(), f.deps(nil), a.ID, key)
		require.NoError(t, err, key)
		require.True(t, strings.HasPrefix(out, dataLine+"\n"), out)
		assert.Contains(t, between(t, out, "<<<document", ">>>"), "Muting lasts twenty-four hours.")
		item := between(t, out, "<<<item", ">>>")
		assert.Contains(t, item, "kind: "+kind, key)
		assert.Contains(t, item, key)
		assert.Contains(t, between(t, out, "<<<result", ">>>"), res.Theses[0].Key)
		assert.Contains(t, between(t, out, "<<<ledger", ">>>"), "Settled one")
		assert.Contains(t, between(t, out, "<<<replies", ">>>"), `"reply":"fixed"`)
		// The reviewer's own conversation and asks blocks, byte for byte.
		assert.Equal(t, between(t, user, "<<<conversation", ">>>"), between(t, out, "<<<conversation", ">>>"))
		assert.Equal(t, between(t, user, "<<<asks", ">>>"), between(t, out, "<<<asks", ">>>"))
	}
	// The item carries its quotes.
	out, err := ThreadContext(context.Background(), f.deps(nil), a.ID, res.DecidedAlone[0].Key)
	require.NoError(t, err)
	assert.Contains(t, between(t, out, "<<<item", ">>>"), "The mute is stored per channel.")

	_, err = ThreadContext(context.Background(), f.deps(nil), a.ID, "ag:000000000000")
	assert.ErrorIs(t, err, ErrNoSuchItem)
}
