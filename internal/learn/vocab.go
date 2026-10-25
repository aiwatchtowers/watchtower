package learn

// The vocabularies a card is checked against (design 2026-10-19 §9.2, §9.3,
// §9.6; plan 2026-10-25-home-learn.md D2).

// areas in the Desktop's display order (§9.3).
var areas = []string{
	"communication", "meetings", "tasks", "development", "assistant",
	"planning", "automations", "iphone", "setup",
}

// levels and kinds (§9.3).
var (
	levels = []string{"basics", "next", "power"}
	kinds  = []string{"feature", "tip", "shortcut"}
)

// Signals is the done_when vocabulary (plan D2). Dual path: the Desktop's
// LearnSignal reads the same list, and a test on each side pins it.
var Signals = []string{
	"meeting.recorded", "chat.used", "workbench.bound", "reaction.used",
	"automation.created", "memory.on", "calendar.connected", "jira.connected",
	"linear.connected", "confluence.connected", "iphone.paired", "dictation.used",
}

// navScreens are the screens a nav:<screen> action may open: the raw values
// of the Desktop's SidebarDestination
// (WatchtowerDesktop/Sources/App/SidebarDestination.swift) — a dual path, keep
// both in step — plus the old screen names watchtower-nav:// still accepts
// for the Inbox's filters (InboxRoute.aliasHosts in
// WatchtowerDesktop/Sources/WatchtowerCore/Services/Inbox/InboxRoute.swift).
var navScreens = []string{
	"home", "chat", "catchUp", "inbox", "calendar", "targets", "projects",
	"automations", "digests", "people", "memory", "workload", "blockers",
	"projectMap", "releases", "statistics", "search", "boards", "usage",
	"mcpServer",
	// InboxRoute.aliasHosts
	"briefings", "dayPlan", "day-plan", "tracks", "ideas",
}

// sources a connect:<source> action or a source:<name> requirement names.
var sources = []string{"slack", "google", "jira", "linear", "confluence", "imap", "calendar"}

// hotkeys maps a hotkey:<name> action to the key it shows. The labels follow
// docs/guide/reference/keyboard-shortcuts.md (the Desktop's
// KeyboardShortcutCatalog).
var hotkeys = map[string]string{
	"help":              "⌘/",
	"sidebar":           "⌘B",
	"quick-run":         "⌃⌘R",
	"quick-capture":     "⌃⌥D",
	"settings":          "⌘,",
	"new-chat":          "⌘N",
	"search-chats":      "⌘K",
	"new-target":        "⌘N",
	"new-session":       "⌘T",
	"go-to":             "⌘K",
	"sessions-panel":    "⌥⌘S",
	"waiting-for-you":   "⌃⌘A",
	"workchat":          "⌃`",
	"open-quickly":      "⇧⌘O",
	"find-in-workbench": "⇧⌘F",
	"go-to-definition":  "⌃⌘J",
	"show-usages":       "⇧⌘U",
	"ask-ai":            "⌘I",
}
