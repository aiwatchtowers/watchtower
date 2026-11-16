package inboxfeed

// ChangeTables are the tables the feed reads: a write to any of them may
// change it, so inbox.feed is re-read and inbox.watch streams a changed
// event (tower.Spec.ChangeTables).
var ChangeTables = []string{
	"automation_outputs", "automation_runs", "automations",
	"inbox_folders", "inbox_folder_state", "inbox_folder_routes",
	"inbox_items", "agent_actions", "reminders",
	"tracks", "track_events", "ideas",
	"briefings", "day_plans", "day_plan_items",
	"builtin_migrations",
	// db.OpenInboxClause drops an open Jira item whose issue was deleted at
	// the source: a deletion changes the counts.
	"jira_issues",
}
