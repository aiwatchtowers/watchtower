package automations

import (
	"strings"
	"testing"
	"time"

	"watchtower/internal/db"
)

func TestManifest_SlackLiveParses(t *testing.T) {
	p, err := ParsePermission("Slack:LIVE")
	if err != nil {
		t.Fatalf("slack:live: %v", err)
	}
	if p.String() != EntrySlackLive || p.Scope != "" {
		t.Fatalf("slack:live = %+v (%s)", p, p.String())
	}
	if _, err := ParsePermission("slack:live@T1"); err == nil || !strings.Contains(err.Error(), "slack:live takes no @scope") {
		t.Fatalf("slack:live@T1: err = %v; want the no-scope refusal", err)
	}
	if _, err := ParsePermission("slack:read"); err == nil {
		t.Fatal("slack:read without a scope still needs one")
	}
	m, err := ParseManifest([]string{"slack:live", "llm:light"}, nil, personalScope)
	if err != nil {
		t.Fatal(err)
	}
	if !m.SlackLive() || !m.FeedsSourcesToLLM() {
		t.Fatalf("SlackLive=%v FeedsSourcesToLLM=%v; want both", m.SlackLive(), m.FeedsSourcesToLLM())
	}
	other, _ := ParseManifest([]string{"slack:read@*"}, nil, personalScope)
	if other.SlackLive() {
		t.Fatal("slack:read@* is not slack:live")
	}
	if got := Covers([]string{"slack:read@*", "slack:write@*"}, []string{"slack:live"}); len(got) != 1 || got[0] != EntrySlackLive {
		t.Fatalf("Covers = %v; slack:live is a widening of its own", got)
	}
}

func liveSchedule(cron string) []byte {
	return recipeWith("name: Live\ntrigger:\n  schedule: \""+cron+"\"\npermissions:\n  - slack:live\n  - agent:run\n  - llm:light\n", "x\n")
}

func TestSlackLiveSchedule_MinimumHourly(t *testing.T) {
	now := time.Date(2026, 11, 14, 12, 0, 0, 0, time.UTC)
	kyiv, err := time.LoadLocation("Europe/Kyiv")
	if err != nil {
		t.Skipf("zone database: %v", err)
	}
	berlin, err := time.LoadLocation("Europe/Berlin")
	if err != nil {
		t.Skipf("zone database: %v", err)
	}
	cases := []struct {
		cron string
		zone *time.Location
		ok   bool
	}{
		{"*/30 * * * *", time.UTC, false},
		{"0 * * * *", time.UTC, true},
		{"0 */2 * * *", time.UTC, true},
		{"15,45 9 * * *", time.UTC, false},
		{"0 * * * *", kyiv, true},       // both fall-back passes are an hour apart
		{"30 2 * * *", kyiv, true},      // across both DST changes
		{"30 1,2 * * *", berlin, false}, // 02:30 is skipped to 03:00 on spring-forward day: 30 min
		{"0 1,3 * * *", berlin, true},   // two wall hours, never less than one real hour
	}
	for _, c := range cases {
		SetLiveCadenceClock(t, c.zone, now)
		_, err := ParseRecipe("live", liveSchedule(c.cron), personalScope)
		if c.ok && err != nil {
			t.Errorf("%q in %s: %v; want accepted", c.cron, c.zone, err)
		}
		if !c.ok && (err == nil || !strings.Contains(err.Error(), "at most once an hour")) {
			t.Errorf("%q in %s: err = %v; want the hourly refusal", c.cron, c.zone, err)
		}
	}
	// Without slack:live the same schedule is fine.
	SetLiveCadenceClock(t, time.UTC, now)
	if _, err := ParseRecipe("x", recipeWith("name: X\ntrigger:\n  schedule: \"*/30 * * * *\"\n", "x\n"), personalScope); err != nil {
		t.Fatalf("a recipe without slack:live keeps its schedule: %v", err)
	}
}

func TestSlackLive_EventTriggerNeedsFull(t *testing.T) {
	d := db.OpenTestDB(t)
	event := func(typ, perms string) *Recipe {
		return mustParse(t, recipeWith("name: E\ntrigger:\n  event: {type: "+typ+"}\npermissions:\n"+perms, "x\n"), personalScope)
	}
	live := "  - slack:live\n  - agent:run\n  - llm:light\n"
	for _, typ := range []string{"slack.new_messages", SlackReactionAdded} {
		err := CheckRecipePolicy(d, event(typ, live))
		if err == nil || !strings.Contains(err.Error(), "needs a Slack workspace synced in Full") {
			t.Fatalf("%s on Live only: err = %v; want the Full refusal", typ, err)
		}
	}
	if err := CheckRecipePolicy(d, event("gmail.new_messages", live)); err != nil {
		t.Fatalf("a non-Slack event needs no Full: %v", err)
	}
	if err := CheckRecipePolicy(d, event("slack.new_messages", "  - slack:read@*\n")); err != nil {
		t.Fatalf("without slack:live the check does not apply: %v", err)
	}
	id, err := d.CreateSlackAccount(db.SlackAccount{TeamID: "T1", TeamName: "acme"})
	if err != nil {
		t.Fatal(err)
	}
	if err := d.SetSlackAccountAuthState(id, "error", "x"); err != nil {
		t.Fatal(err)
	}
	if err := CheckRecipePolicy(d, event("slack.new_messages", live)); err == nil {
		t.Fatal("an account in error is not Full")
	}
	if err := d.SetSlackAccountAuthState(id, "ok", ""); err != nil {
		t.Fatal(err)
	}
	if err := CheckRecipePolicy(d, event("slack.new_messages", live)); err != nil {
		t.Fatalf("with a Full account: %v", err)
	}
}
