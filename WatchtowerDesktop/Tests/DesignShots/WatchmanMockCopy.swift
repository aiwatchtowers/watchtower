import Foundation

/// Design-only string table of the Watchman spec
/// (`docs/superpowers/specs/2026-11-16-watchman-design.md` §2, §10, §11).
/// The implementation moves each group into the view model that owns the
/// screen (the journal, the Home row, the arming controls, Settings →
/// Watchman) and pins it there; `WatchmanMockCopyTests` pins this table so
/// the mockups and the spec cannot drift apart. Sample data only: `acme`,
/// made-up ids.
enum WatchmanMockCopy {
    /// One category's line of the backtest table.
    struct BacktestRow {
        let category: String
        let agreement: String
        let wrongHigh: String
        let rating: String
    }

    // MARK: Inbox → Watchman: the reading list

    static let journalTitle = "Watchman"
    static let scopeAll = "All workbenches"
    static let scopeOne = "acme-api"
    static let nightTonight = "Tonight"
    static let nightTonightLine = "In progress · 3 decided so far"
    static let night16 = "Night of 16 Nov"
    static let night16Line = "14 decided · 2 unsure · 1 waiting"
    static let night15 = "Night of 15 Nov"
    static let night15Line = "9 decided · all sure"
    static let night13 = "Night of 13 Nov"
    static let night13Line = "4 decided · 1 unsure"

    // MARK: The night

    static let nightSpan = "01:40–07:30 · the Mac stayed awake"
    static let busySpan = "Since 01:40 · Watchman is on"
    static let busySummary = "1 unsure · 2 sure"
    static let waitingTitle = "Waiting for you"
    static let decidedTitle = "Decided"
    static let decidedSummary = "2 unsure · 12 sure"
    static let parkedTitle = "#1830 Merge feature/store-window → main"
    static let parkedReason = "Parked: merging to main is yours"
    static let parkedSession = "acme-api · session 4 · 05:12"
    static let openSession = "Open session"

    static let unsureBadge = "Unsure"
    static let choseLabel = "Chose"
    static let leanedOn = "Leaned on"

    static let unsure1Session = "acme-api · session 3 · 02:14"
    static let unsure1Question = "#1826 Store the window per workbench or global?"
    static let unsure1Choice = "Per workbench"
    static let unsure1Rationale = "You split settings per workbench in #1201, #1288 and kept global only "
        + "what every workbench shares. A window's place differs per folder."
    static let unsure1Precedents = ["#1201 Sidebar width per workbench", "#1288 Terminal font per workbench"]
    static let unsure1Meta = "confidence low · design · strong 84 %"
    static let unsure1Outcome = "Merged into feature/store-window · PR #912"

    static let unsure2Session = "acme-web · session 7 · 03:40"
    static let unsure2Question = "#1829 Rename the \"Hold\" button to \"Pause\"?"
    static let unsure2Choice = "Keep \"Hold\""
    static let unsure2Rationale = "You turned down renames of shipped buttons in #1144 unless the guide "
        + "page changed in the same PR. This one doesn't."
    static let unsure2Precedents = ["#1144 Keep \"Archive\" on the board"]
    static let unsure2Meta = "confidence low · ux_text · weak 61 %"
    static let unsure2Outcome = "Session continued · not merged yet"

    static let sureRows: [(title: String, meta: String)] = [
        ("#1827 Allow go test ./internal/watchman", "permission · high"),
        ("#1826 Review round 2: Approve", "review_code · high"),
        ("#1828 Plan: split the store into two tasks", "scope · high"),
        ("#1826 Finish: accept as done", "finish · medium")
    ]
    static let moreSure = "8 more sure decisions"
    static let skippedTitle = "#1831 Check the tray menu on a second display"
    static let skippedLine = "Not run by you — Watchman continued"
    static let skippedMeta = "check · skipped"

    static let ok = "OK"
    static let correct = "Correct…"

    // MARK: Journal states

    static let emptyTitle = "No night yet"
    static let emptyBody = "When you hand a session to Watchman and leave, the decisions it takes for you "
        + "land here: what was asked, what it chose, why, and how sure it was."
    static let emptyHint = "Use Hand to Watchman on a session strip, or Hand all running sessions to Watchman "
        + "in the menu bar."
    static let loading = "Reading the journal…"
    static let readFailed = "Couldn't read the journal. The decisions are stored; nothing was lost."
    static let retry = "Retry"
    static let deciding = "Deciding: #1826 'Store window per workbench?' …"

    // MARK: Correct… sheet

    static let correctTitle = "Correct this decision"
    static let correctQuestion = "What would you have decided?"
    static let correctDraft = "Global. One window position for every workbench is enough here; "
        + "per-workbench settings are for things that differ by folder."
    static let correctSessionEnded = "Session 3 has ended, so a new session starts on #1826 with your "
        + "correction. Your answer also teaches Watchman."
    static let cancel = "Cancel"
    static let sendCorrection = "Send Correction"

    // MARK: Home

    static let homeRow = "Overnight Watchman decided 14 — 2 unsure, 1 waiting for you"

    // MARK: Arming

    static let stripSession = "#1826 Store window"
    static let stripPlace = "acme-api"
    static let stripBranch = "feature/store-window"
    static let armedChip = "Watchman · Sleep since 01:40"
    static let takeBack = "Take back"
    static let handTo = "Hand to Watchman"
    static let workchat = "Workchat"
    static let report = "Report"

    static let armTitle = "Hand acme-api to Watchman?"
    static let armBody = "Watchman answers for you in this workbench's sessions while you sleep or are away. "
        + "Every decision lands in the morning journal with its reason."
    static let armAnalytics = "Agent analytics turned on — Watchman learns from your sessions"
    static let armHistory = "Learning from your history: ~1 850 decisions, est. 1.6 M tokens"
    static let armNoProtection = "main has no branch protection. Watchman never merges to main, "
        + "but an agent with allow rules could push there. Turn protection on first."
    static let armLimits = "Merging to main, messages to people and releases stay yours: Watchman parks them."
    static let notNow = "Not now"
    static let start = "Start"

    // MARK: Settings → Watchman

    static let sleepTitle = "Sleep window"
    static let sleepCaption = "Learned from when you stop and start working on workbenches. Recomputed weekly."
    static let sleepValue = "00:30–07:45"
    static let sleepLearned = "Learned"
    static let sleepNotLearned = "Not learned yet: Watchman needs a week of your activity."
    static let edit = "Edit"

    static let limitsTitle = "Your hard limits"
    static let limitsCaption = "Watchman parks these for you in every mode. "
        + "The six built-in limits (merge to main, messages, releases…) can't be removed."
    static let extraLimits = ["Change files under migrations/", "Bump a dependency version"]
    static let remove = "Remove"
    static let addLimit = "Add a Limit…"

    static let budgetTitle = "Night budget"
    static let budgetValue = "400 k tokens a night"

    static let backtestTitle = "Backtest"
    static let backtestCaption = "Last run 15 Nov, 03:12 · your latest 30 decisions per category, hidden and "
        + "decided again by Watchman."
    static let columnCategory = "Category"
    static let columnAgreement = "Agreement"
    static let columnWrongHigh = "Wrong while sure"
    static let columnRating = "Rating"
    static let strong = "Strong"
    static let weak = "Weak"
    static let notMeasured = "Not measured"
    static let backtestRows: [BacktestRow] = [
        BacktestRow(category: "design", agreement: "84 %", wrongHigh: "3 %", rating: strong),
        BacktestRow(category: "scope", agreement: "81 %", wrongHigh: "4 %", rating: strong),
        BacktestRow(category: "ux_text", agreement: "61 %", wrongHigh: "9 %", rating: weak),
        BacktestRow(category: "tests", agreement: "88 %", wrongHigh: "2 %", rating: strong),
        BacktestRow(category: "review_code", agreement: "79 %", wrongHigh: "6 %", rating: weak),
        BacktestRow(category: "review_doc", agreement: "83 %", wrongHigh: "4 %", rating: strong),
        BacktestRow(category: "permission", agreement: "96 %", wrongHigh: "0 %", rating: strong),
        BacktestRow(category: "finish", agreement: "—", wrongHigh: "—", rating: notMeasured)
    ]
    static let barNote = "Strong: 80 % agreement or more and 5 % or less wrong while sure. "
        + "Below that Watchman marks every night decision unsure. Under 30 decisions: not measured."
    static let analyticsOffNote = "Agent analytics is off on acme-web, so your typed corrections there are not used."
    static let runBacktest = "Run Backtest Now"
    static let backtestNeverRun = "Watchman hasn't checked itself yet. The backtest hides your latest decisions "
        + "and asks Watchman to take them; nothing acts until you've seen the numbers."
    static let backtestRunning = "Backtest running · ux_text, 18 of 30 · 3 of 8 categories done"
    static let backtestRunningButton = "Running…"
    static let lastResults = "Last results, 15 Nov"
    static let backtestFailed = "The backtest stopped: the AI provider hit your plan limit. "
        + "Nothing changed; the last results stay."

    static let profileTitle = "What Watchman learned"
    static let profileCaption = "Your rules per category, distilled weekly from your decisions. An edit pins "
        + "the text until you unpin it."
    static let pinned = "Pinned by you"
    static let learnedOn = "Learned 14 Nov"
    static let unpin = "Unpin"
    static let profileDesign = [
        "Settings that differ by folder are per workbench; the rest stay global.",
        "Prefer the simpler flow; never ask for a field the app can derive.",
        "A new screen reuses the design kit; no new component for one use."
    ]
    static let profileUXText = [
        "Shipped button titles stay unless the guide page changes too.",
        "Say what happened and what to do; no apologies, no exclamation marks."
    ]
    static let profileEmpty = "Nothing learned yet. The profile is built after the first learning pass."
}
