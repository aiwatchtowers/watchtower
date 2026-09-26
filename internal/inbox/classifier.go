package inbox

var defaultClasses = map[string]string{
	"mention":               "actionable",
	"dm":                    "actionable",
	"thread_reply":          "actionable",
	"reaction":              "ambient",
	"jira_assigned":         "actionable",
	"jira_comment_mention":  "actionable",
	"jira_comment_watching": "ambient",
	"jira_status_change":    "ambient",
	"jira_priority_change":  "ambient",
	"calendar_invite":       "actionable",
	"calendar_time_change":  "actionable",
	"calendar_cancelled":    "ambient",
	"decision_made":         "ambient",
	"briefing_ready":        "ambient",
	"target_due":            "actionable",
	"email_received":        "actionable",
	"email_cc":              "ambient",
}

// DefaultItemClass returns 'actionable' or 'ambient' for a known trigger type, defaulting to 'ambient' for unknown.
// This is the source of truth for the per-source detectors (Jira, Calendar,
// Watchtower-internal), which set ItemClass explicitly at creation time.
// Nothing rewrites the class afterwards — the AI triage stage that used to is
// gone (see docs/superpowers/specs/2026-09-14-inbox-demolition-design.md).
func DefaultItemClass(trig string) string {
	if c, ok := defaultClasses[trig]; ok {
		return c
	}
	return "ambient"
}
