package db

import (
	"testing"
)

func TestInboxLearnedRules_Upsert(t *testing.T) {
	database := openTestDB(t)

	rule := InboxLearnedRule{
		RuleType:      "source_mute",
		ScopeKey:      "sender:U123",
		Weight:        -0.7,
		Source:        "implicit",
		EvidenceCount: 10,
	}
	if err := database.UpsertLearnedRule(rule); err != nil {
		t.Fatal(err)
	}

	got, err := database.GetLearnedRule("source_mute", "sender:U123")
	if err != nil {
		t.Fatal(err)
	}
	if got.Weight != -0.7 {
		t.Errorf("weight=%v want -0.7", got.Weight)
	}

	// Update
	rule.Weight = -0.9
	rule.EvidenceCount = 15
	if err := database.UpsertLearnedRule(rule); err != nil {
		t.Fatal(err)
	}
	got, _ = database.GetLearnedRule("source_mute", "sender:U123")
	if got.Weight != -0.9 {
		t.Errorf("updated weight=%v want -0.9", got.Weight)
	}
	if got.EvidenceCount != 15 {
		t.Errorf("evidence=%d want 15", got.EvidenceCount)
	}
}

func TestInboxLearnedRules_UserRuleProtected(t *testing.T) {
	database := openTestDB(t)

	// User-created rule
	_ = database.UpsertLearnedRule(InboxLearnedRule{
		RuleType: "source_mute", ScopeKey: "channel:C1", Weight: -0.9, Source: "user_rule", EvidenceCount: 0,
	})

	// Implicit should NOT overwrite a user_rule
	err := database.UpsertLearnedRuleImplicit(InboxLearnedRule{
		RuleType: "source_mute", ScopeKey: "channel:C1", Weight: -0.3, Source: "implicit", EvidenceCount: 5,
	})
	if err != nil {
		t.Fatal(err)
	}

	got, _ := database.GetLearnedRule("source_mute", "channel:C1")
	if got.Weight != -0.9 || got.Source != "user_rule" {
		t.Errorf("user_rule overwritten: %+v", got)
	}
}

func TestInboxLearnedRules_ListByRelevance(t *testing.T) {
	database := openTestDB(t)

	_ = database.UpsertLearnedRule(InboxLearnedRule{RuleType: "source_mute", ScopeKey: "sender:U1", Weight: -0.5, Source: "implicit"})
	_ = database.UpsertLearnedRule(InboxLearnedRule{RuleType: "source_boost", ScopeKey: "sender:U2", Weight: 0.8, Source: "explicit_feedback"})
	_ = database.UpsertLearnedRule(InboxLearnedRule{RuleType: "source_mute", ScopeKey: "channel:C1", Weight: -0.7, Source: "implicit"})

	got, err := database.ListLearnedRulesByScope([]string{"sender:U1", "channel:C99"}, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[0].ScopeKey != "sender:U1" {
		t.Errorf("expected only sender:U1 match, got %+v", got)
	}
}

func TestInboxLearnedRules_PipelineScope(t *testing.T) {
	database := openTestDB(t)

	// A rule addressed to the digest pipeline.
	if err := database.UpsertLearnedRule(InboxLearnedRule{
		RuleType: "source_mute", ScopeKey: "digest:channel:Cnoise", Weight: -1.0,
		Source: "explicit_feedback", Pipeline: "digest",
	}); err != nil {
		t.Fatal(err)
	}

	digestRules, err := database.ListLearnedRulesByPipeline("digest", 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(digestRules) != 1 || digestRules[0].ScopeKey != "digest:channel:Cnoise" {
		t.Fatalf("expected digest rule, got %+v", digestRules)
	}
	if digestRules[0].Pipeline != "digest" {
		t.Errorf("pipeline=%q want digest", digestRules[0].Pipeline)
	}

	inboxRules, err := database.ListLearnedRulesByPipeline("inbox", 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(inboxRules) != 0 {
		t.Errorf("expected no inbox rules, got %+v", inboxRules)
	}

	// Existing-style upsert with empty Pipeline defaults to "inbox".
	if err := database.UpsertLearnedRule(InboxLearnedRule{
		RuleType: "source_boost", ScopeKey: "sender:U9", Weight: 0.5, Source: "implicit",
	}); err != nil {
		t.Fatal(err)
	}
	got, err := database.GetLearnedRule("source_boost", "sender:U9")
	if err != nil {
		t.Fatal(err)
	}
	if got.Pipeline != "inbox" {
		t.Errorf("empty pipeline should default to inbox, got %q", got.Pipeline)
	}
	inboxRules, err = database.ListLearnedRulesByPipeline("inbox", 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(inboxRules) != 1 || inboxRules[0].ScopeKey != "sender:U9" {
		t.Errorf("expected inbox-defaulted rule, got %+v", inboxRules)
	}

	// ListLearnedRulesByScope scans pipeline too.
	scoped, err := database.ListLearnedRulesByScope([]string{"digest:channel:Cnoise"}, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(scoped) != 1 || scoped[0].Pipeline != "digest" {
		t.Errorf("ListLearnedRulesByScope should carry pipeline, got %+v", scoped)
	}
}

func TestInboxLearnedRules_Delete(t *testing.T) {
	database := openTestDB(t)
	_ = database.UpsertLearnedRule(InboxLearnedRule{RuleType: "source_mute", ScopeKey: "x", Weight: -1, Source: "user_rule"})
	if err := database.DeleteLearnedRule("source_mute", "x"); err != nil {
		t.Fatal(err)
	}
	_, err := database.GetLearnedRule("source_mute", "x")
	if err == nil {
		t.Error("expected error after delete")
	}
}
