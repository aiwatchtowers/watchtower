package api

import (
	"bytes"
	"encoding/json"
	"os"
	"testing"
)

// The pre-redesign shapes of Card and the records it carries, as a client
// built before the feed gained its redesign fields decodes them. They are
// copies, frozen here on purpose: a new field must never break them.
type (
	oldFeed struct {
		V       int       `json:"v"`
		BuiltAt string    `json:"built_at"`
		Folders []Folder  `json:"folders"`
		Cards   []oldCard `json:"cards"`
	}
	oldCard struct {
		ID          string            `json:"id"`
		FolderID    int64             `json:"folder_id"`
		CardKind    string            `json:"card_kind"`
		Title       string            `json:"title"`
		SourceLine  string            `json:"source_line"`
		Preview     string            `json:"preview"`
		Stamp       string            `json:"stamp"`
		Living      bool              `json:"living"`
		Unread      bool              `json:"unread"`
		Priority    string            `json:"priority"`
		Pinned      bool              `json:"pinned"`
		Automation  *CardAutomation   `json:"automation,omitempty"`
		Blocks      string            `json:"blocks"`
		Body        string            `json:"body"`
		BodyClipped bool              `json:"body_clipped"`
		Link        string            `json:"link"`
		ContentHash string            `json:"content_hash"`
		Actions     []CardAction      `json:"actions"`
		RefFacts    []oldRefFacts     `json:"ref_facts"`
		Approval    *oldApproval      `json:"approval,omitempty"`
		Legacy      *oldLegacySection `json:"legacy,omitempty"`
	}
	oldRefFacts struct {
		Kind           string `json:"kind"`
		ID             int64  `json:"id"`
		Open           bool   `json:"open"`
		Waits          bool   `json:"waits"`
		Reply          bool   `json:"reply"`
		ReplyWaiting   bool   `json:"reply_waiting"`
		Link           string `json:"link"`
		TriggerType    string `json:"trigger_type"`
		Custom         bool   `json:"custom"`
		LinkedTargetID int64  `json:"linked_target_id"`
		IdeaKind       string `json:"idea_kind"`
		IdeaStatus     string `json:"idea_status"`
	}
	oldApproval struct {
		Tool       string `json:"tool"`
		Title      string `json:"title"`
		ArgsSHA256 string `json:"args_sha256"`
		Status     string `json:"status"`
		External   bool   `json:"external,omitempty"`
	}
	oldLegacySection struct {
		Kind  string          `json:"kind"`
		Items []oldLegacyItem `json:"items"`
	}
	oldLegacyItem struct {
		RefKind string `json:"ref_kind"`
		ID      int64  `json:"id"`
		Title   string `json:"title"`
		Stamp   string `json:"stamp"`
		Unread  bool   `json:"unread"`
		Stopped bool   `json:"stopped"`
	}
)

// newShapeFeed is a feed with every redesign field set.
func newShapeFeed() Feed {
	return Feed{
		V: FeedVersion, BuiltAt: "2026-11-20T12:00:00Z", Folders: []Folder{},
		Cards: []Card{
			{
				ID: "o1", FolderID: 1, CardKind: CardArtifact, Title: "Mail waiting", Stamp: "2026-11-20T09:00:00Z",
				Priority: "medium", Actions: []CardAction{},
				RefFacts: []RefFacts{
					{Kind: RefMailSender, ID: 0, Open: true, Waits: true, Key: "colleague-a@example.com"},
					{Kind: RefWaitingOlder, ID: 0, Open: true, Key: "people"},
				},
				Section: SectionNeedsYou,
				Mail:    &MailFacts{Open: 12, Today: 3, Senders: 5, TopTenShare: 80, Stale: MailStaleLastRunFailed},
				People:  &PeopleFacts{Today: 2, Older: 7},
				SlackToday: &SlackTodayFacts{
					Status: "ok", State: `{"items":[]}`,
				},
			},
			{
				ID: "a7", FolderID: 2, CardKind: CardApprovalNative, Title: "Send", Priority: "high",
				Actions: []CardAction{}, RefFacts: []RefFacts{}, Section: SectionToday,
				Approval: &Approval{
					Tool: "slack_send", Title: "Send", ArgsSHA256: "abc", Status: "pending", External: true,
					Group: "messages", Bulk: true,
				},
			},
			{
				ID: "tracks", FolderID: 1, CardKind: CardLegacy, Title: "Track my threads", Priority: "medium",
				Actions: []CardAction{}, RefFacts: []RefFacts{}, Section: SectionRunning,
				Legacy: &LegacySection{Kind: LegacyTracks, Items: []LegacyItem{
					{RefKind: RefTrack, ID: 4, Title: "Release", Stamp: "2026-11-19T10:00:00Z", Unread: true,
						News: true, Quiet: true, CreatedAt: "2026-11-01T08:00:00Z"},
				}, Attention: []LegacyAttention{}},
			},
		},
	}
}

func TestFeed_OldClientDecodesNewFields(t *testing.T) {
	b, err := json.Marshal(newShapeFeed())
	if err != nil {
		t.Fatal(err)
	}
	var old oldFeed
	if err := json.Unmarshal(b, &old); err != nil {
		t.Fatalf("a pre-redesign client cannot decode the new feed: %v\n%s", err, b)
	}
	if len(old.Cards) != 3 {
		t.Fatalf("cards = %d, want 3", len(old.Cards))
	}
	mail := old.Cards[0]
	if mail.ID != "o1" || mail.Title != "Mail waiting" || len(mail.RefFacts) != 2 {
		t.Fatalf("mail card = %+v", mail)
	}
	// An old client keeps the unknown kind as its raw string (Swift: .unknown).
	if mail.RefFacts[0].Kind != "mail_sender" || !mail.RefFacts[0].Waits || mail.RefFacts[1].Kind != "waiting_older" {
		t.Fatalf("ref facts = %+v", mail.RefFacts)
	}
	if ap := old.Cards[1].Approval; ap == nil || ap.Tool != "slack_send" || ap.Status != "pending" || !ap.External {
		t.Fatalf("approval = %+v", old.Cards[1].Approval)
	}
	lg := old.Cards[2].Legacy
	if lg == nil || lg.Kind != "tracks" || len(lg.Items) != 1 || lg.Items[0].ID != 4 || !lg.Items[0].Unread {
		t.Fatalf("legacy = %+v", lg)
	}
}

// newKeys are the redesign's JSON keys; a feed without the fields must not
// write any of them.
var newKeys = []string{
	`"section"`, `"mail"`, `"people"`, `"slack_today"`, `"key"`, `"news"`, `"quiet"`, `"created_at"`,
	`"group"`, `"bulk"`,
}

func TestFeed_NewFieldsOmittedWhenEmpty(t *testing.T) {
	raw, err := os.ReadFile("../../inboxfeed/testdata/inbox_feed_cases.json")
	if err != nil {
		t.Fatal(err)
	}
	var cases []struct {
		Name   string          `json:"name"`
		Expect json.RawMessage `json:"expect"`
		Steps  []struct {
			Name   string          `json:"name"`
			Expect json.RawMessage `json:"expect"`
		} `json:"steps"`
	}
	if err := json.Unmarshal(raw, &cases); err != nil {
		t.Fatal(err)
	}
	if len(cases) == 0 {
		t.Fatal("no cases")
	}
	check := func(name string, expect json.RawMessage) {
		t.Helper()
		var want bytes.Buffer
		if err := json.Compact(&want, expect); err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		var feed Feed
		if err := json.Unmarshal(expect, &feed); err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		var got bytes.Buffer
		enc := json.NewEncoder(&got)
		enc.SetEscapeHTML(false)
		if err := enc.Encode(feed); err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if g := bytes.TrimSuffix(got.Bytes(), []byte("\n")); !bytes.Equal(g, want.Bytes()) {
			t.Fatalf("%s: re-encoded feed differs from the fixture\n got: %s\nwant: %s", name, g, want.Bytes())
		}
		for _, k := range newKeys {
			if bytes.Contains(want.Bytes(), []byte(k+":")) {
				t.Fatalf("%s: the fixture already has %s; this test needs a feed without the new fields", name, k)
			}
		}
	}
	for _, c := range cases {
		check(c.Name, c.Expect)
		for _, s := range c.Steps {
			check(c.Name+"/"+s.Name, s.Expect)
		}
	}
}
