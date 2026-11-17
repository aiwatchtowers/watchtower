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
	// PROJ-21: an answer changes the request and the session's state; an
	// Esc changes the state the hooks report next. The request kinds feed
	// the runner-fed slices (the runner publishes them itself).
	"permission_answer":      {"permission_request", "terminal_session"},
	"session_interrupt":      {"terminal_session"},
	"session_report_request": {"session_report"},
	"session_chat_request":   {"session_chat"},
	// A phone line, its cancel, a start or a stop moves the session's row
	// and its timeline.
	"session_input":          sessionSlices,
	"session_finish_request": sessionSlices,
	"session_input_cancel":   sessionSlices,
	"session_start":          sessionSlices,
	"session_stop":           sessionSlices,
	// The AI chat from the phone (iPhone chat §4.5): a write moves the list
	// and the open feed; a request publishes what it asked for (a
	// chat_feed_request for conversation 0 is the list's Retry).
	"chat_new":           {slices.KindChatList},
	"chat_turn":          chatSlices,
	"chat_cancel":        chatSlices,
	"chat_feed_request":  chatSlices,
	"chat_page":          {slices.KindChatPage},
	"chat_search":        {slices.KindChatSearch},
	"chat_read":          {slices.KindChatList},
	"chat_branch_select": chatSlices,
	"chat_manage":        chatSlices,
	"chat_action_answer": chatSlices,
	// The phone Inbox (mobile Inbox spec §6): a write moves its cards and
	// its folders' counts.
	"inbox_act": {slices.KindInboxCard, slices.KindInboxFolder},
}

// chatSlices are the records a chat write changes: the conversation's feed
// and the chat list's row.
var chatSlices = []slices.Kind{slices.KindChatFeed, slices.KindChatList}

// sessionSlices are the records a session action changes.
var sessionSlices = []slices.Kind{"terminal_session", "session_timeline"}
