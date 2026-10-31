package handlers

import "watchtower/internal/hub/slices"

// The board kinds (BoardHandlers.kinds).
var boardKinds = []string{
	"board_target_status", "board_target_priority", "board_comment_add", "board_comment_reply", "board_target_create",
}

// boardSlices are the records a board write changes: its targets and
// comments, and the workbench's counts (BoardHandlers.publishedKinds).
var boardSlices = []slices.Kind{"workbench", "workbench_target", "workbench_comment"}

// NudgeTable maps each action kind to the slice kinds the runtime refreshes
// after it is applied (spec §9: one table, nudge after every applied action).
// Every registered kind has an entry; Tasks 3–5 add theirs here.
var NudgeTable = map[string][]slices.Kind{
	"ask_answer":            {"owner_ask", slices.KindAskAlert},
	"board_target_status":   boardSlices,
	"board_target_priority": boardSlices,
	"board_comment_add":     boardSlices,
	"board_comment_reply":   boardSlices,
	"board_target_create":   boardSlices,
	// The workbench record carries the automation buttons and their runs
	// (AutomationRunHandler's publishSoon([.workbench])).
	"automation_run": {"workbench"},
}
