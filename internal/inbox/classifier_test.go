package inbox

import "testing"

func TestInbox01_DefaultClassByTrigger(t *testing.T) {
	// BEHAVIOR INBOX-01 — see docs/inventory/inbox-pulse.md
	// Default class assignment per trigger_type. Do not weaken or remove
	// without explicit owner approval.
	cases := []struct {
		trig  string
		class string
	}{
		{"mention", "actionable"},
		{"dm", "actionable"},
		{"thread_reply", "actionable"},
		{"reaction", "ambient"},
		{"jira_assigned", "actionable"},
		{"jira_comment_mention", "actionable"},
		{"jira_comment_watching", "ambient"},
		{"jira_status_change", "ambient"},
		{"jira_priority_change", "ambient"},
		{"calendar_invite", "actionable"},
		{"calendar_time_change", "actionable"},
		{"calendar_cancelled", "ambient"},
		{"decision_made", "ambient"},
		{"briefing_ready", "ambient"},
		{"target_due", "actionable"},
		{"unknown_type", "ambient"}, // unknown → ambient fallback
	}
	for _, c := range cases {
		got := DefaultItemClass(c.trig)
		if got != c.class {
			t.Errorf("trigger=%s got=%s want=%s", c.trig, got, c.class)
		}
	}
}
