package link

import (
	"encoding/json"
	"os"
	"testing"

	"watchtower/internal/hub/wire"
)

// TestChatGrant_InDeviceGrantRecord: a linked phone's device_grant carries
// chat, on by default (ask #1340) and off once the owner turns it off; the
// Kit's DeviceGrant decodes the same key (the chat_off fixture case).
func TestChatGrant_InDeviceGrantRecord(t *testing.T) {
	r := newRig(t)
	a := newPhone(t)
	r.confirmLinked(a)
	g := r.mustKeybox(a).Grant
	if g.Chat == nil || !*g.Chat {
		t.Fatalf("a new phone's chat grant: %v, want on", g.Chat)
	}
	if err := r.c.Allow(a.id.String(), GrantChat, false); err != nil {
		t.Fatal(err)
	}
	g = r.mustKeybox(a).Grant
	if g.Chat == nil || *g.Chat {
		t.Fatalf("after the owner turned chat off: %v", g.Chat)
	}
	out, err := wire.Marshal(g)
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err := json.Unmarshal(out, &m); err != nil {
		t.Fatal(err)
	}
	if v, ok := m["chat"]; !ok || v != false {
		t.Fatalf("encoded chat %v (present %v): false must be written", v, ok)
	}

	raw, err := os.ReadFile("../../../WatchtowerKit/Tests/Fixtures/link/hub_contract_cases.json")
	if err != nil {
		t.Fatal(err)
	}
	var f struct {
		DeviceGrant []struct {
			Name string          `json:"name"`
			JSON json.RawMessage `json:"json"`
			Kit  map[string]any  `json:"kit"`
		} `json:"device_grant"`
	}
	if err := json.Unmarshal(raw, &f); err != nil {
		t.Fatal(err)
	}
	seen := 0
	for _, c := range f.DeviceGrant {
		var fg wire.DeviceGrant
		if err := json.Unmarshal(c.JSON, &fg); err != nil {
			t.Fatal(err)
		}
		want := fg.Chat == nil || *fg.Chat
		if c.Kit["chat_allowed"] != want {
			t.Errorf("%s: kit chat_allowed %v, the Go read %v", c.Name, c.Kit["chat_allowed"], want)
		}
		if c.Name == "chat_off" {
			seen++
		}
	}
	if seen != 1 {
		t.Fatal("the fixture has no chat_off case")
	}
}

// TestChatGrant_SurvivesRelink: the owner turns Chat off, the phone links
// again with a new code (no unlink in between): Chat is still off.
func TestChatGrant_SurvivesRelink(t *testing.T) {
	r := newRig(t)
	a := newPhone(t)
	r.confirmLinked(a)
	if err := r.c.Allow(a.id.String(), GrantChat, false); err != nil {
		t.Fatal(err)
	}
	r.confirmLinked(a)
	if g := r.mustKeybox(a).Grant; g.Chat == nil || *g.Chat {
		t.Fatalf("after a re-link: %v, want still off", g.Chat)
	}
	d, ok, err := r.st.Device(a.id.String())
	if err != nil || !ok || d.ChatAllowed {
		t.Fatalf("stored grant %+v %v %v", d.ChatAllowed, ok, err)
	}
}
