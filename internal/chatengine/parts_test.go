package chatengine

import (
	"context"
	"encoding/json"
	"flag"
	"net/url"
	"os"
	"slices"
	"testing"
	"testing/synctest"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/chat"
)

var updateParts = flag.Bool("update", false, "rewrite testdata/parts.json from the builder")

// partsCase is one sample of testdata/parts.json: the builder's inputs and
// the part it must yield. ChatWire (Swift) decodes the same file.
type partsCase struct {
	Kind string `json:"kind"`
	// ClientDerived: the kind is split out of the text part by the client
	// (D14); the engine emits no part of it and the text part is its fallback.
	ClientDerived bool             `json:"client_derived,omitempty"`
	TurnID        string           `json:"turn_id"`
	Message       FeedMessage      `json:"message"`
	Conversation  FeedConversation `json:"conversation"`
	Actions       []FeedAction     `json:"actions"`
	Part          *Part            `json:"part"`
}

func loadPartsCases(t *testing.T) []partsCase {
	t.Helper()
	raw, err := os.ReadFile("testdata/parts.json")
	require.NoError(t, err)
	var cases []partsCase
	require.NoError(t, json.Unmarshal(raw, &cases))
	for i := range cases {
		cases[i].Message.turnID = cases[i].TurnID
		for j := range cases[i].Actions {
			cases[i].Actions[j].TurnID = cases[i].TurnID
		}
	}
	return cases
}

func (c partsCase) build() []Part { return BuildParts(c.Message, c.Conversation, c.Actions) }

func (c partsCase) partOfKind() *Part {
	want := c.Kind
	if c.ClientDerived {
		want = PartText
	}
	for _, p := range c.build() {
		if p.Kind == want {
			return &p
		}
	}
	return nil
}

// TestParts_UpdateFixture rewrites the expected parts of the fixture with
// -update; review the diff like any golden.
func TestParts_UpdateFixture(t *testing.T) {
	if !*updateParts {
		t.Skip("run with -update")
	}
	cases := loadPartsCases(t)
	for i := range cases {
		cases[i].Part = cases[i].partOfKind()
		cases[i].Message.Parts = []Part{}
	}
	b, err := json.MarshalIndent(cases, "", "  ")
	require.NoError(t, err)
	require.NoError(t, os.WriteFile("testdata/parts.json", append(b, '\n'), 0o644))
}

func TestParts_FixtureCoversEveryKind(t *testing.T) {
	var kinds []string
	for _, c := range loadPartsCases(t) {
		kinds = append(kinds, c.Kind)
	}
	assert.ElementsMatch(t, PartKinds, kinds)
	assert.Len(t, PartKinds, 12)
	assert.Len(t, slices.Compact(slices.Sorted(slices.Values(kinds))), 12, "one sample per kind")
}

// TestCHAT06_EveryPartKindHasFallback: every kind the engine emits has a
// sample in parts.json, the builder yields exactly the sample's part, and it
// carries a non-empty fallback (BEHAVIOR CHAT-06 — see docs/inventory/chat.md).
func TestCHAT06_EveryPartKindHasFallback(t *testing.T) {
	cases := loadPartsCases(t)
	for _, kind := range PartKinds {
		i := slices.IndexFunc(cases, func(c partsCase) bool { return c.Kind == kind })
		require.GreaterOrEqual(t, i, 0, "parts.json has a sample of %s", kind)
		c := cases[i]
		got := c.partOfKind()
		require.NotNil(t, got, "BuildParts yields a %s part (the text part for a client-derived kind)", kind)
		if c.ClientDerived {
			for _, p := range c.build() {
				assert.NotEqual(t, kind, p.Kind, "the engine never emits a client-derived kind (D14)")
			}
		}
		assert.NotEmpty(t, got.Fallback.Text, kind)
		require.NotNil(t, c.Part, "the fixture holds the expected %s part", kind)
		want, _ := json.Marshal(c.Part)
		have, _ := json.Marshal(got)
		assert.JSONEq(t, string(want), string(have), kind)
	}
}

func TestParts_ApprovalFallbackText(t *testing.T) {
	a := FeedAction{ID: 1, Tool: "send_slack_message", Title: "Send slack message", Status: "pending",
		ArgsDisplay: `{"channel":"#general","text":"hi"}`, TurnID: "t1"}
	m := FeedMessage{ID: 2, Role: "assistant", turnID: "t1"}
	var found *Part
	for _, p := range BuildParts(m, FeedConversation{}, []FeedAction{a}) {
		if p.Kind == PartApproval {
			found = &p
		}
	}
	require.NotNil(t, found)
	assert.Equal(t, "Send a Slack message to #general — waiting for your approval", found.Fallback.Text)
	assert.Equal(t, []FallbackAction{{Label: "Open on the Mac", Action: ActionNone}}, found.Fallback.Actions)
}

// TestChat05_FallbackActionsOnlyOpenCopyOrFixedTurn: whatever the builder
// makes, a fallback action opens a permitted link, sends one of the fixed
// texts the owner taps, or does nothing (CHAT-05).
func TestChat05_FallbackActionsOnlyOpenCopyOrFixedTurn(t *testing.T) {
	fixed := map[string]bool{}
	for _, text := range FallbackTurnTexts {
		fixed[text] = true
	}
	seen := 0
	for _, c := range loadPartsCases(t) {
		for _, p := range c.build() {
			for _, a := range p.Fallback.Actions {
				seen++
				assert.NotEmpty(t, a.Label)
				switch a.Action {
				case ActionNone:
					assert.Empty(t, a.URL+a.Text)
				case ActionOpenURL:
					assert.True(t, OpenURLPermitted(a.URL), a.URL)
					assert.Empty(t, a.Text)
				case ActionChatTurn:
					assert.True(t, fixed[a.Text], "%q is not in the fixed table", a.Text)
					assert.Empty(t, a.URL)
				default:
					t.Errorf("fallback action %q is none of chat_turn, open_url, none", a.Action)
				}
			}
		}
	}
	assert.GreaterOrEqual(t, seen, 3, "the fixture exercises all three actions")
}

func TestParts_OpenURLRules(t *testing.T) {
	for _, ok := range []string{"https://claude.ai/artifact/abc", "HTTPS://Claude.AI/doc/1?x=1"} {
		assert.True(t, OpenURLPermitted(ok), ok)
	}
	for _, bad := range []string{"", "http://claude.ai/artifact/abc", "https://claude.ai", "https://claude.ai/",
		"https://claude.ai.example.com/a", "https://claude%2Eai/a", "https://u:p" + "@claude.ai/a", "https://claude.ai:8443/a",
		"javascript:alert(1)", "https://example.com/a", "file:///etc/passwd"} {
		assert.False(t, OpenURLPermitted(bad), bad)
	}
	_, err := url.Parse("https://claude.ai/a")
	require.NoError(t, err)
}

// TestChatengine_UnlistedKindSendsFallbackOnly: D15 — a client that lists
// only `text` gets the approval's fallback and no payload.
func TestChatengine_UnlistedKindSendsFallbackOnly(t *testing.T) {
	var approval partsCase
	for _, c := range loadPartsCases(t) {
		if c.Kind == PartApproval {
			approval = c
		}
	}
	parts := approval.build()
	filtered := FilterParts(parts, Client{Kind: "phone", PartKinds: map[string]bool{PartText: true}})
	require.Len(t, filtered, len(parts))
	for i, p := range filtered {
		assert.Equal(t, parts[i].Fallback, p.Fallback)
		if p.Kind == PartText {
			assert.NotNil(t, p.Payload)
		} else {
			assert.Nil(t, p.Payload, p.Kind)
		}
	}
	require.NotEmpty(t, parts[slices.IndexFunc(parts, func(p Part) bool { return p.Kind == PartApproval })].Payload, "the input is untouched")
	same := FilterParts(parts, Client{Kind: "phone"})
	assert.Equal(t, parts, same, "a nil kind set lists everything (relay, D21)")
	out, err := json.Marshal(filtered[slices.IndexFunc(filtered, func(p Part) bool { return p.Kind == PartApproval })])
	require.NoError(t, err)
	assert.NotContains(t, string(out), `"payload"`)
}

// TestChatengine_FeedKeepsFlatFields: parts come beside the flat fields a
// client one version behind still reads.
func TestChatengine_FeedKeepsFlatFields(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := newRig(t, fakeOpts{block: true, text: "streaming now"})
		c := newConversation(t, g.d)
		_, err := g.r.Turn(context.Background(), turnReq(c, "hi", ""))
		require.NoError(t, err)
		synctest.Wait()
		f, err := g.r.Feed(context.Background(), c, 0)
		require.NoError(t, err)
		raw, err := json.Marshal(f)
		require.NoError(t, err)
		var top struct {
			Conversation map[string]json.RawMessage `json:"conversation"`
			Messages     []map[string]json.RawMessage
			Artifacts    json.RawMessage `json:"artifacts"`
			Actions      json.RawMessage `json:"actions"`
		}
		require.NoError(t, json.Unmarshal(raw, &top))
		assert.NotEmpty(t, top.Artifacts)
		assert.NotEmpty(t, top.Actions)
		require.Len(t, top.Messages, 2)
		for _, m := range top.Messages {
			for _, key := range []string{"text", "steps", "attachments", "parts"} {
				assert.Contains(t, m, key)
			}
			assert.NotEqual(t, "null", string(m["parts"]))
		}
		assert.Equal(t, "streaming now", f.Messages[1].Text)
		assert.Equal(t, PartText, f.Messages[1].Parts[0].Kind)
	})
}

// TestParts_RefitAfterACapCut: a cut text and emptied steps reach the parts;
// the approvals stay.
func TestParts_RefitAfterACapCut(t *testing.T) {
	var c partsCase
	for _, k := range loadPartsCases(t) {
		if k.Kind == PartApproval {
			c = k
		}
	}
	m := c.Message
	m.Steps = []FeedStep{{Name: "list_messages", Summary: "Searched", Sources: []chat.Source{{Kind: "slack", Title: "t", Ref: "r"}}}}
	m.Parts = BuildParts(m, c.Conversation, c.Actions)
	kinds := func() []string {
		var out []string
		for _, p := range m.Parts {
			out = append(out, p.Kind)
		}
		return out
	}
	require.Equal(t, []string{PartText, PartSteps, PartSources, PartApproval}, kinds())

	m.Text, m.TextCut, m.Steps = "I propose…", true, []FeedStep{}
	m.RefitParts()
	assert.Equal(t, []string{PartText, PartApproval}, kinds())
	assert.Equal(t, "I propose…", m.Parts[0].Fallback.Text)
	assert.JSONEq(t, `{"text":"I propose…","text_cut":true}`, string(m.Parts[0].Payload))
}

func kindsOf(parts []Part) []string {
	var out []string
	for _, p := range parts {
		out = append(out, p.Kind)
	}
	return out
}

// TestParts_LiveSlackSuppressesMarksPerMessage: LIVE-01 holds from the
// first Live Slack message on, not for the whole conversation.
func TestParts_LiveSlackSuppressesMarksPerMessage(t *testing.T) {
	since := int64(5)
	conv := FeedConversation{LiveSlackSince: &since}
	before := FeedMessage{ID: 4, Role: "user", Text: "decided: ship it"}
	after := FeedMessage{ID: 5, Role: "user", Text: "decided: ship it"}
	rem := FeedMessage{ID: 6, Role: "user", Text: "remember: short answers"}
	assert.Equal(t, []string{PartText, PartKnowledgeMark}, kindsOf(BuildParts(before, conv, nil)))
	assert.Equal(t, []string{PartText}, kindsOf(BuildParts(after, conv, nil)))
	assert.Equal(t, []string{PartText}, kindsOf(BuildParts(rem, conv, nil)), "no remember promise in a Live Slack chat")
	assert.Equal(t, []string{PartText, PartRememberMark}, kindsOf(BuildParts(
		FeedMessage{ID: 3, Role: "user", Text: rem.Text}, conv, nil)))

	// The refit after a hub cut builds the same way.
	after.liveSince, before.liveSince = &since, &since
	for _, m := range []*FeedMessage{&after, &before} {
		m.Parts = BuildParts(*m, conv, nil)
		m.Text += " (cut)"
		m.RefitParts()
	}
	assert.Equal(t, []string{PartText}, kindsOf(after.Parts))
	assert.Equal(t, []string{PartText, PartKnowledgeMark}, kindsOf(before.Parts))
}

// TestParts_LiveSlackHoldsOnTheOlderPagePath: a page read has no conversation
// meta of its own; the Live Slack mark rule still applies per message.
func TestParts_LiveSlackHoldsOnTheOlderPagePath(t *testing.T) {
	d := openDB(t)
	conv := newConversation(t, d)
	var ids []int64
	var parent any
	for range 3 {
		res, err := d.Exec(`INSERT INTO chat_messages (conversation_id, parent_id, role, text, created_at, turn_id)
			VALUES (?, ?, 'user', 'decided: ship it', 1, '')`, conv, parent)
		require.NoError(t, err)
		id, _ := res.LastInsertId()
		ids, parent = append(ids, id), id
	}
	_, err := d.Exec(`UPDATE chat_conversations SET active_leaf_message_id = ?, live_slack_since = ? WHERE id = ?`, ids[2], ids[1], conv)
	require.NoError(t, err)
	page, err := ReadFeed(context.Background(), d, conv, ids[2], time.Unix(10, 0), nil)
	require.NoError(t, err)
	require.Len(t, page.Messages, 2)
	assert.Equal(t, []string{PartText, PartKnowledgeMark}, kindsOf(page.Messages[0].Parts))
	assert.Equal(t, []string{PartText}, kindsOf(page.Messages[1].Parts))
}

func TestParts_SignInHintFollowsTheRegistry(t *testing.T) {
	assert.Equal(t, "Open Terminal and run: claude login", signInHint(""))
	assert.Equal(t, "Open Terminal and run: claude login", signInHint("claude"))
	assert.Equal(t, "Open Terminal and run: codex login", signInHint("codex"))
	assert.Equal(t, "Check its settings in Settings → AI.", signInHint("ollama"))
	assert.Equal(t, "Check its settings in Settings → AI.", signInHint("nope"))
}
