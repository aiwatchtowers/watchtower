import AppKit
import GRDB
import SwiftUI
import XCTest
@testable import DesignKitCatalog
@testable import WatchtowerDesktop
@testable import WatchtowerCore
import WatchtowerTestSupport

/// One rendered shot of the Desktop design kit's reference screens (style
/// guide #719, spec §6): `name` is the PNG's file stem, `size` the fixed
/// frame it is rendered at, `make` builds the view on fixed sample data.
struct DesignShot {
    let name: String
    let size: NSSize
    let make: @MainActor () -> AnyView
}

/// Every shot `make desktop-shots` renders (`DesignShotsTests`). The kit's
/// promotion steps compare these before and after a move; every new screen
/// appends its own shot here. Sample data is `acme` / `example.com` only.
/// Each shot paints the surface its view sits on in the app (the detail
/// backdrop, or the window colour for the buttons), so dark mode is not
/// rendered over a transparent, white-looking page.
enum DesignShotCatalog {
    @MainActor static var all: [DesignShot] {
        PlansShotFixtures.shots + [
            DesignShot(name: "workbench-header", size: NSSize(width: 760, height: 44)) {
                AnyView(DesignShotFixtures.workbenchHeader().padding(8).shotFrame().detailBackground())
            },
            DesignShot(name: "workbench-board-cards", size: NSSize(width: 480, height: 280)) {
                AnyView(DesignShotFixtures.boardCards().padding(12).shotFrame().detailBackground())
            },
            DesignShot(name: "workbench-kanban-columns", size: NSSize(width: 1380, height: 220)) {
                AnyView(BoardColumnsShotFixtures.kanbanColumns().shotFrame().detailBackground())
            },
            DesignShot(name: "workbench-new-task", size: NSSize(width: 620, height: 240)) {
                AnyView(DesignShotFixtures.newTask().shotFrame().panelBackground())
            },
            DesignShot(name: "workbench-panel-parts", size: NSSize(width: 440, height: 120)) {
                AnyView(DesignShotFixtures.panelParts().padding(12).shotFrame().detailBackground())
            },
            DesignShot(name: "sessions-panel", size: NSSize(width: 300, height: 140)) {
                AnyView(DesignShotFixtures.sessionsPanel())
            },
            // U6 (spec 2026-11-05 §3.5): Working beside Working · not watched.
            DesignShot(name: "session-state-not-watched", size: NSSize(width: 320, height: 0)) {
                DesignShotFixtures.sessionNotWatched()
            },
            DesignShot(name: "session-drag-preview", size: NSSize(width: 300, height: 140)) {
                DesignShotFixtures.sessionDragPreview(width: 276, busy: false)
            },
            DesignShot(name: "session-drag-preview-narrow-busy", size: NSSize(width: 190, height: 140)) {
                DesignShotFixtures.sessionDragPreview(width: 166, busy: true)
            },
            DesignShot(name: "chat-rows", size: NSSize(width: 560, height: 280)) {
                AnyView(DesignShotFixtures.chatRows().padding(12).shotFrame().detailBackground())
            },
            DesignShot(name: "chat-knowledge-marks", size: NSSize(width: 560, height: 260)) {
                AnyView(DesignShotFixtures.chatKnowledgeMarks().padding(12).shotFrame().detailBackground())
            },
            // Native text runs (§5b): finished and streaming must match.
            DesignShot(name: "chat-markdown-finished", size: NSSize(width: 784, height: 0)) {
                AnyView(ChatMarkdownShotFixtures.finished(width: 760).shotFrame().detailBackground())
            },
            DesignShot(name: "chat-markdown-streaming", size: NSSize(width: 784, height: 0)) {
                AnyView(ChatMarkdownShotFixtures.streaming(width: 760).shotFrame().detailBackground())
            },
            DesignShot(name: "chat-markdown-finished-narrow", size: NSSize(width: 344, height: 0)) {
                AnyView(ChatMarkdownShotFixtures.finished(width: 320).shotFrame().detailBackground())
            },
            DesignShot(name: "chat-markdown-streaming-narrow", size: NSSize(width: 344, height: 0)) {
                AnyView(ChatMarkdownShotFixtures.streaming(width: 320).shotFrame().detailBackground())
            },
            DesignShot(name: "chat-composer-ollama-capabilities", size: NSSize(width: 620, height: 0)) {
                AnyView(ProviderCapabilitiesShotFixtures.ollamaComposer().shotFrame().detailBackground())
            },
            DesignShot(name: "workchat-hold-caption", size: NSSize(width: 560, height: 0)) {
                AnyView(SessionCapsShotFixtures.workchatHoldCaption().shotFrame().detailBackground())
            },
            DesignShot(name: "settings-notifications-idle-caption", size: NSSize(width: 620, height: 240)) {
                AnyView(SessionCapsShotFixtures.notificationSettings().shotFrame().panelBackground())
            },
            DesignShot(name: "workchat-activity-busy", size: NSSize(width: 720, height: 400)) {
                AnyView(WorkchatLiveProposalShot(model: .busy, narrow: false, agentsOpen: false))
            },
            DesignShot(name: "workchat-activity-narrow", size: NSSize(width: 340, height: 400)) {
                AnyView(WorkchatLiveProposalShot(model: .busy, narrow: true, agentsOpen: false))
            },
            DesignShot(name: "workchat-activity-agents-open", size: NSSize(width: 720, height: 480)) {
                AnyView(WorkchatLiveProposalShot(model: .busy, narrow: false, agentsOpen: true))
            },
            DesignShot(name: "workchat-activity-overflow", size: NSSize(width: 720, height: 480)) {
                AnyView(WorkchatLiveProposalShot(model: .overflow, narrow: false, agentsOpen: true))
            },
            DesignShot(name: "workchat-activity-empty", size: NSSize(width: 720, height: 300)) {
                AnyView(WorkchatLiveProposalShot(model: .empty, narrow: false, agentsOpen: false))
            },
            DesignShot(name: "workchat-activity-loading", size: NSSize(width: 720, height: 400)) {
                AnyView(WorkchatLiveProposalShot(model: .loading, narrow: false, agentsOpen: false))
            },
            DesignShot(name: "workchat-activity-thinking", size: NSSize(width: 720, height: 400)) {
                AnyView(WorkchatLiveProposalShot(model: .thinking, narrow: false, agentsOpen: false))
            },
            DesignShot(name: "workchat-activity-error", size: NSSize(width: 720, height: 400)) {
                AnyView(WorkchatLiveProposalShot(model: .error, narrow: false, agentsOpen: false))
            },
            DesignShot(name: "workchat-activity-stale", size: NSSize(width: 720, height: 400)) {
                AnyView(WorkchatLiveProposalShot(model: .stale, narrow: false, agentsOpen: false))
            },
            DesignShot(name: "workchat-activity-agents-unknown", size: NSSize(width: 720, height: 400)) {
                AnyView(WorkchatLiveProposalShot(model: .unknownAgents, narrow: false, agentsOpen: false))
            },
            DesignShot(name: "workchat-activity-actual-busy", size: NSSize(width: 720, height: 400)) {
                AnyView(WorkchatLiveProposalShot(model: .busy, narrow: false, agentsOpen: false, usesLiveImplementation: true))
            },
            DesignShot(name: "workchat-activity-actual-narrow", size: NSSize(width: 340, height: 400)) {
                AnyView(WorkchatLiveProposalShot(model: .busy, narrow: true, agentsOpen: false, usesLiveImplementation: true))
            },
            DesignShot(name: "workchat-activity-actual-agents-open", size: NSSize(width: 720, height: 480)) {
                AnyView(WorkchatLiveProposalShot(model: .busy, narrow: false, agentsOpen: true, usesLiveImplementation: true))
            },
            DesignShot(name: "workchat-activity-actual-overflow", size: NSSize(width: 720, height: 480)) {
                AnyView(WorkchatLiveProposalShot(model: .overflow, narrow: false, agentsOpen: true, usesLiveImplementation: true))
            },
            DesignShot(name: "workchat-activity-actual-empty", size: NSSize(width: 720, height: 300)) {
                AnyView(WorkchatLiveProposalShot(model: .empty, narrow: false, agentsOpen: false, usesLiveImplementation: true))
            },
            DesignShot(name: "workchat-activity-actual-loading", size: NSSize(width: 720, height: 400)) {
                AnyView(WorkchatLiveProposalShot(model: .loading, narrow: false, agentsOpen: false, usesLiveImplementation: true))
            },
            DesignShot(name: "workchat-activity-actual-thinking", size: NSSize(width: 720, height: 400)) {
                AnyView(WorkchatLiveProposalShot(model: .thinking, narrow: false, agentsOpen: false, usesLiveImplementation: true))
            },
            DesignShot(name: "workchat-activity-actual-error", size: NSSize(width: 720, height: 400)) {
                AnyView(WorkchatLiveProposalShot(model: .error, narrow: false, agentsOpen: false, usesLiveImplementation: true))
            },
            DesignShot(name: "workchat-activity-actual-stale", size: NSSize(width: 720, height: 400)) {
                AnyView(WorkchatLiveProposalShot(model: .stale, narrow: false, agentsOpen: false, usesLiveImplementation: true))
            },
            DesignShot(name: "workchat-activity-actual-agents-unknown", size: NSSize(width: 720, height: 400)) {
                AnyView(WorkchatLiveProposalShot(model: .unknownAgents, narrow: false, agentsOpen: false, usesLiveImplementation: true))
            },
            DesignShot(name: "workchat-live-line", size: NSSize(width: 560, height: 120)) {
                AnyView(DesignShotFixtures.workchatLiveLine().padding(12).shotFrame().detailBackground())
            },
            DesignShot(name: "calendar-rows", size: NSSize(width: 480, height: 200)) {
                AnyView(DesignShotFixtures.calendarRows().padding(12).shotFrame().detailBackground())
            },
            DesignShot(name: "buttons", size: NSSize(width: 460, height: 64)) {
                AnyView(DesignShotFixtures.buttons().padding(12).shotFrame().panelBackground())
            },
            // The chat project page (spec 2026-10-26 §7): the cards beside
            // the chats from 900 pt of content, below them under it.
            DesignShot(name: "chat-project-page-wide", size: NSSize(width: 1100, height: 720)) {
                ProjectPageShotFixtures.page()
            },
            DesignShot(name: "chat-project-page-narrow", size: NSSize(width: 640, height: 1000)) {
                ProjectPageShotFixtures.page()
            },
            DesignShot(name: "chat-project-page-empty", size: NSSize(width: 1100, height: 520)) {
                ProjectPageShotFixtures.page(empty: true)
            },
            // Home (#717): two columns from 900 pt of content, one below.
            DesignShot(name: "home-wide", size: NSSize(width: 1280, height: 960)) {
                HomeShotFixtures.home()
            },
            DesignShot(name: "home-narrow", size: NSSize(width: 780, height: 1440)) {
                HomeShotFixtures.home()
            },
            // A wide window: the columns fill it; Getting ready on top.
            DesignShot(name: "home-getting-ready", size: NSSize(width: 1800, height: 1100)) {
                HomeShotFixtures.home(gettingReady: true)
            },
            // Account purge notice (#601): the banner above Getting ready.
            DesignShot(name: "home-account-purge", size: NSSize(width: 1280, height: 720)) {
                HomeShotFixtures.home(purges: HomeShotFixtures.purges)
            },
            // Learn Watchtower (#718): the last zone of the right column, the
            // all-seen line, and See all.
            DesignShot(name: "home-learn", size: NSSize(width: 1280, height: 1560)) {
                HomeShotFixtures.home(learn: LearnShotFixtures.selection())
            },
            DesignShot(name: "learn-zone", size: NSSize(width: 440, height: 0)) {
                AnyView(LearnShotFixtures.zone().shotFrame().detailBackground())
            },
            DesignShot(name: "learn-zone-all-seen", size: NSSize(width: 440, height: 0)) {
                AnyView(LearnShotFixtures.zone(allSeen: true).shotFrame().detailBackground())
            },
            DesignShot(name: "learn-all-sheet", size: NSSize(width: 680, height: 760)) {
                AnyView(LearnShotFixtures.sheet().shotFrame())
            },
            DesignShot(name: "settings-privacy", size: NSSize(width: 640, height: 420)) {
                AnyView(HomeShotFixtures.privacySettings().shotFrame().detailBackground())
            },
            DesignShot(name: "settings-organization-policy", size: NSSize(width: 640, height: 600)) {
                AnyView(HomeShotFixtures.organizationPolicy().shotFrame().detailBackground())
            },
            DesignShot(name: "connections-blocked", size: NSSize(width: 900, height: 520)) {
                AnyView(HomeShotFixtures.connectionsBlocked().shotFrame().detailBackground())
            },
            DesignShot(name: "connections-overview", size: NSSize(width: 900, height: 620)) {
                AnyView(HomeShotFixtures.connectionsOverview().shotFrame().detailBackground())
            },
            DesignShot(name: "automation-list", size: NSSize(width: 1280, height: 760)) {
                AutomationShotFixtures.list()
            },
            DesignShot(name: "automation-list-collapsed", size: NSSize(width: 1280, height: 760)) {
                AutomationShotFixtures.list(collapsed: true)
            },
            DesignShot(name: "automation-card", size: NSSize(width: 900, height: 720)) {
                AnyView(AutomationShotFixtures.card().detailBackground())
            },
            DesignShot(name: "automation-draft-column", size: NSSize(width: 560, height: 760)) {
                AnyView(AutomationShotFixtures.draftColumn().shotFrame().detailBackground())
            },
            DesignShot(name: "automation-save-card", size: NSSize(width: 560, height: 520)) {
                AnyView(AutomationShotFixtures.saveCard().padding(12).shotFrame().detailBackground())
            },
            DesignShot(name: "automation-new-panel", size: NSSize(width: 900, height: 640)) {
                AnyView(AutomationShotFixtures.newPanel(fixedToAcme: false).detailBackground())
            },
            DesignShot(name: "automation-new-panel-workbench", size: NSSize(width: 900, height: 640)) {
                AnyView(AutomationShotFixtures.newPanel(fixedToAcme: true).detailBackground())
            },
            DesignShot(name: "automation-template-panel", size: NSSize(width: 1000, height: 760)) {
                AnyView(AutomationShotFixtures.templatePanel().detailBackground())
            },
            DesignShot(name: "automation-editor-panel", size: NSSize(width: 1280, height: 800)) {
                AnyView(AutomationShotFixtures.editorPanel(review: false).detailBackground())
            },
            DesignShot(name: "automation-editor-review", size: NSSize(width: 1280, height: 800)) {
                AnyView(AutomationShotFixtures.editorPanel(review: true).detailBackground())
            },
            // The Inbox read like mail (spec B1).
            DesignShot(name: "inbox-reading-pane", size: NSSize(width: 1180, height: 720)) {
                InboxShotFixtures.readingPane()
            },
            DesignShot(name: "inbox-reading-pane-narrow", size: NSSize(width: 420, height: 560)) {
                InboxShotFixtures.narrowPane()
            },
            DesignShot(name: "inbox-proposal-pane", size: NSSize(width: 1180, height: 720)) {
                InboxShotFixtures.proposalPane()
            },
            DesignShot(name: "inbox-message-pane", size: NSSize(width: 1180, height: 720)) {
                InboxShotFixtures.messagePane()
            },
            // The one Inbox (C1) without its filters (inbox builder B): today's
            // day card in the root and the root's legacy lists, at a fixed moment.
            DesignShot(name: "inbox-day-card", size: NSSize(width: 1180, height: 720)) {
                OneInboxShotFixtures.dayCard()
            },
            DesignShot(name: "inbox-day-card-regenerate", size: NSSize(width: 1180, height: 720)) {
                OneInboxShotFixtures.dayCardRegenerate()
            },
            DesignShot(name: "inbox-day-card-empty", size: NSSize(width: 1180, height: 720)) {
                OneInboxShotFixtures.dayCardEmpty()
            },
            DesignShot(name: "inbox-track-card", size: NSSize(width: 1180, height: 720)) {
                OneInboxShotFixtures.trackCard()
            },
            DesignShot(name: "inbox-tracks-stopped", size: NSSize(width: 1180, height: 720)) {
                OneInboxShotFixtures.tracksStopped()
            },
            DesignShot(name: "inbox-idea-card", size: NSSize(width: 1180, height: 720)) {
                OneInboxShotFixtures.ideaCard()
            },
            DesignShot(name: "inbox-decision-card", size: NSSize(width: 1180, height: 720)) {
                OneInboxShotFixtures.decisionCard()
            },
            DesignShot(name: "inbox-chat-decision-card", size: NSSize(width: 1180, height: 720)) {
                OneInboxShotFixtures.chatDecisionCard()
            },
            DesignShot(name: "inbox-message-card", size: NSSize(width: 1180, height: 720)) {
                OneInboxShotFixtures.messageCard()
            },
            DesignShot(name: "inbox-ideas-new", size: NSSize(width: 1180, height: 720)) {
                OneInboxShotFixtures.ideasNew()
            },
            DesignShot(name: "inbox-cheat-sheet", size: NSSize(width: 1180, height: 720)) {
                OneInboxShotFixtures.cheatSheet()
            },
            DesignShot(name: "inbox-day-card-narrow", size: NSSize(width: 420, height: 560)) {
                OneInboxShotFixtures.dayCardNarrow()
            },
            // Built-in automations (C2): the Inbox notice of a failed move.
            DesignShot(name: "inbox-builtin-notice", size: NSSize(width: 1180, height: 720)) {
                OneInboxShotFixtures.builtinNotice()
            },
            // Built-in automations (C2): the Built in section and Morning brief's card.
            DesignShot(name: "automation-builtin-list", size: NSSize(width: 1280, height: 760)) {
                BuiltinShotFixtures.list()
            },
            DesignShot(name: "automation-builtin-card", size: NSSize(width: 900, height: 720)) {
                BuiltinShotFixtures.card(.shipped)
            },
            DesignShot(name: "automation-builtin-card-updated", size: NSSize(width: 900, height: 900)) {
                BuiltinShotFixtures.card(.updated)
            },
            DesignShot(name: "automation-builtin-card-reset", size: NSSize(width: 900, height: 720)) {
                BuiltinShotFixtures.card(.resetting)
            },
            DesignShot(name: "settings-features-builtin", size: NSSize(width: 640, height: 620)) {
                BuiltinShotFixtures.featuresSettings()
            },
            // C3: the Reactions and Idea finder cards, Watch for something, the track card through its watch.
            DesignShot(name: "automations-builtin-reactions", size: NSSize(width: 900, height: 820)) {
                BuiltinShotFixtures.c3Card(reactions: true)
            },
            DesignShot(name: "automations-builtin-ideas", size: NSSize(width: 900, height: 620)) {
                BuiltinShotFixtures.c3Card(reactions: false)
            },
            DesignShot(name: "automations-new-watch", size: NSSize(width: 900, height: 720)) {
                AnyView(AutomationShotFixtures.newPanel(fixedToAcme: false).detailBackground())
            },
            DesignShot(name: "inbox-track-card-watch", size: NSSize(width: 1180, height: 720)) {
                OneInboxShotFixtures.trackCard(.bound)
            },
            DesignShot(name: "inbox-track-card-watch-edited", size: NSSize(width: 1180, height: 720)) {
                OneInboxShotFixtures.trackCard(.edited)
            },
            DesignShot(name: "inbox-track-card-unbound", size: NSSize(width: 1180, height: 720)) {
                OneInboxShotFixtures.trackCard(.unbound)
            },
            // Branch review (#712, artboards A–C).
            DesignShot(name: "branch-review-changes", size: NSSize(width: 1180, height: 760)) {
                ReviewShotFixtures.changes()
            },
            DesignShot(name: "branch-review-chat-panel", size: NSSize(width: 1180, height: 760)) {
                ReviewShotFixtures.changesWithChat()
            },
            DesignShot(name: "branch-review-empty", size: NSSize(width: 1180, height: 520)) {
                ReviewShotFixtures.empty()
            },
            DesignShot(name: "branch-review-default-branch", size: NSSize(width: 1180, height: 520)) {
                ReviewShotFixtures.defaultBranch()
            },
            DesignShot(name: "branch-review-deep-meaning", size: NSSize(width: 1180, height: 760)) {
                ReviewShotFixtures.deepMeaning()
            },
            // Branch review of a big branch (#1025, mockup frames 1–4b).
            DesignShot(name: "big-branch-1-running", size: NSSize(width: 1280, height: 860)) {
                BigBranchReviewShotFixtures.running()
            },
            DesignShot(name: "big-branch-1b-waiting", size: NSSize(width: 1280, height: 860)) {
                BigBranchReviewShotFixtures.waiting()
            },
            DesignShot(name: "big-branch-2a-done", size: NSSize(width: 1280, height: 860)) {
                BigBranchReviewShotFixtures.doneMeaning()
            },
            DesignShot(name: "big-branch-2b-failed-chapter", size: NSSize(width: 1280, height: 860)) {
                BigBranchReviewShotFixtures.failedChapter()
            },
            DesignShot(name: "big-branch-2c-summary-failed", size: NSSize(width: 1280, height: 620)) {
                BigBranchReviewShotFixtures.summaryFailed()
            },
            DesignShot(name: "big-branch-3-small-pr", size: NSSize(width: 1280, height: 620)) {
                BigBranchReviewShotFixtures.smallPR()
            },
            DesignShot(name: "big-branch-4a-past-cap", size: NSSize(width: 1280, height: 620)) {
                BigBranchReviewShotFixtures.pastTheCap()
            },
            DesignShot(name: "big-branch-4b-map-failed", size: NSSize(width: 1280, height: 620)) {
                BigBranchReviewShotFixtures.mapFailed()
            },
            // The reviewer beside the diff (#1025, mockup frame 5).
            DesignShot(name: "branch-review-reviewer", size: NSSize(width: 1280, height: 800)) {
                ReviewerShotFixtures.reviewer()
            },
            DesignShot(name: "branch-review-reviewer-author", size: NSSize(width: 1280, height: 800)) {
                ReviewerShotFixtures.author()
            },
            DesignShot(name: "branch-review-reviewer-no-round", size: NSSize(width: 1280, height: 800)) {
                ReviewerShotFixtures.noRound()
            },
            // Spec review in the review ask drawer (spec 2026-10-25 §7).
            DesignShot(name: "spec-review-meaning", size: NSSize(width: 760, height: 1200)) {
                SpecReviewShotFixtures.screen(.meaning)
            },
            // A narrow drawer: the four mark buttons (Fix / Skip /
            // Discuss / Not useful) wrap to two rows inside the card. Below about 480 the Chapters
            // screen's two columns overflow on their own.
            DesignShot(name: "spec-review-chapters-narrow", size: NSSize(width: 480, height: 1100)) {
                SpecReviewShotFixtures.screen(.chapters)
            },
            DesignShot(name: "spec-review-chapters", size: NSSize(width: 760, height: 900)) {
                SpecReviewShotFixtures.screen(.chapters)
            },
            DesignShot(name: "spec-review-wrapup", size: NSSize(width: 760, height: 900)) {
                SpecReviewShotFixtures.screen(.wrapup)
            },
            DesignShot(name: "spec-review-loop", size: NSSize(width: 760, height: 1180)) {
                SpecReviewShotFixtures.loop()
            },
            // Spec review polish (spec 2026-10-28): a loop's chapter with
            // Fix / Comment, and the footer's verdicts with and without comments.
            DesignShot(name: "spec-review-loop-chapters", size: NSSize(width: 760, height: 1000)) {
                SpecReviewShotFixtures.loopChapters()
            },
            DesignShot(name: "spec-review-footer", size: NSSize(width: 760, height: 110)) {
                SpecReviewShotFixtures.footers()
            },
            DesignShot(name: "spec-review-running", size: NSSize(width: 760, height: 360)) {
                SpecReviewShotFixtures.running()
            },
            DesignShot(name: "spec-review-strips", size: NSSize(width: 760, height: 150)) {
                SpecReviewShotFixtures.strips()
            },
            // Spec review: summary, Discuss threads, per-kind buttons and the
            // loop's new end lines (spec 2026-11-08), on fixtures.
            DesignShot(name: "spec-review-summary", size: NSSize(width: 620, height: 0)) {
                SpecReviewShotFixtures.summary()
            },
            DesignShot(name: "spec-review-thread-open", size: NSSize(width: 620, height: 0)) {
                SpecReviewShotFixtures.threadCard("open")
            },
            DesignShot(name: "spec-review-thread-replying", size: NSSize(width: 620, height: 0)) {
                SpecReviewShotFixtures.threadCard("replying")
            },
            DesignShot(name: "spec-review-thread-question-pending", size: NSSize(width: 620, height: 0)) {
                SpecReviewShotFixtures.threadCard("pending")
            },
            DesignShot(name: "spec-review-thread-question-answered", size: NSSize(width: 620, height: 0)) {
                SpecReviewShotFixtures.threadCard("answered")
            },
            DesignShot(name: "spec-review-thread-question-expired", size: NSSize(width: 620, height: 0)) {
                SpecReviewShotFixtures.threadCard("expired")
            },
            DesignShot(name: "spec-review-thread-finding-proposed", size: NSSize(width: 620, height: 0)) {
                SpecReviewShotFixtures.threadCard("proposed")
            },
            DesignShot(name: "spec-review-thread-finding-refused", size: NSSize(width: 620, height: 0)) {
                SpecReviewShotFixtures.threadCard("refused")
            },
            DesignShot(name: "spec-review-thread-folded", size: NSSize(width: 620, height: 0)) {
                SpecReviewShotFixtures.threadCard("folded")
            },
            DesignShot(name: "spec-review-buttons-findings", size: NSSize(width: 620, height: 0)) {
                SpecReviewShotFixtures.findingKinds()
            },
            DesignShot(name: "spec-review-buttons-loop", size: NSSize(width: 620, height: 0)) {
                SpecReviewShotFixtures.loopKinds()
            },
            DesignShot(name: "spec-review-loop-stalled", size: NSSize(width: 760, height: 1100)) {
                SpecReviewShotFixtures.loopEnded("loop-owner-items", end: "stalled", round: 4)
            },
            DesignShot(name: "spec-review-loop-cap", size: NSSize(width: 760, height: 420)) {
                SpecReviewShotFixtures.loopEnded("loop-cap", end: "cap", round: 8, ownerItems: false)
            },
            // A question raised from the terminal: the reason as a caption,
            // the question once, on its card.
            DesignShot(name: "ask-raised-from-chat", size: NSSize(width: 560, height: 520)) {
                AnyView(RaisedAskShotFixtures.drawerTop().shotFrame().detailBackground())
            },
            // Approve / Request changes (#964, mockup 3).
            DesignShot(name: "branch-review-approve-popover", size: NSSize(width: 400, height: 260)) {
                ReviewShotFixtures.approvePopover()
            },
            DesignShot(name: "branch-review-approved", size: NSSize(width: 1180, height: 560)) {
                ReviewShotFixtures.approved()
            },
            // Branch review polish (#958–#962): the preview and the chapter's risks.
            DesignShot(name: "branch-review-preview", size: NSSize(width: 1180, height: 560)) {
                ReviewShotFixtures.preview()
            },
            DesignShot(name: "branch-review-chapter-risks", size: NSSize(width: 1180, height: 760)) {
                ReviewShotFixtures.chapterRisks()
            },
            // Agent Settings as a page screen (#1150).
            DesignShot(name: "workbench-agent-settings", size: NSSize(width: 1040, height: 900)) {
                AgentSettingsShotFixtures.screen()
            },
            // The coach on the Analytics pane (#1120, Plan 2).
            DesignShot(name: "analytics-coach", size: NSSize(width: 900, height: 1700)) {
                CoachShotFixtures.screen(.sections)
            },
            DesignShot(name: "analytics-statistics", size: NSSize(width: 900, height: 1340)) {
                StatisticsShotFixtures.screen()
            },
            // Codex sessions on the Analytics pane (U4, board #975).
            DesignShot(name: "analytics-codex-blocks", size: NSSize(width: 900, height: 1340)) {
                CodexAnalyticsShotFixtures.blocks()
            },
            DesignShot(name: "analytics-codex-sessions", size: NSSize(width: 900, height: 260)) {
                CodexAnalyticsShotFixtures.sessions()
            },
            DesignShot(name: "analytics-codex-sessions-narrow", size: NSSize(width: 480, height: 260)) {
                CodexAnalyticsShotFixtures.sessions()
            },
            DesignShot(name: "analytics-coach-edit-sheet", size: NSSize(width: 520, height: 320)) {
                CoachShotFixtures.screen(.editSheet)
            },
            DesignShot(name: "analytics-coach-rollback-sheet", size: NSSize(width: 520, height: 300)) {
                CoachShotFixtures.screen(.rollbackSheet)
            },
            // The coach's entry points outside the Analytics pane (#1120).
            DesignShot(name: "home-coach-row", size: NSSize(width: 440, height: 360)) {
                CoachPointerShotFixtures.homeRow()
            },
            DesignShot(name: "settings-instructions-coach-pointer", size: NSSize(width: 560, height: 220)) {
                CoachPointerShotFixtures.pointer(settings: true)
            },
            DesignShot(name: "agent-settings-coach-pointer", size: NSSize(width: 560, height: 420)) {
                CoachPointerShotFixtures.pointer(settings: false)
            },
            // Usage → Watchtower (LLM usage ledger): filled (every gap line on), empty ledger, failed read.
            DesignShot(name: "usage-watchtower-filled", size: NSSize(width: 860, height: 760)) {
                LLMUsageShotFixtures.filled()
            },
            DesignShot(name: "usage-watchtower-empty", size: NSSize(width: 860, height: 360)) {
                LLMUsageShotFixtures.screen(.emptyLedger)
            },
            DesignShot(name: "usage-watchtower-error", size: NSSize(width: 860, height: 360)) {
                LLMUsageShotFixtures.screen(.failed(.timedOut))
            },
            DesignShot(name: "usage-watchtower-loading", size: NSSize(width: 860, height: 560)) {
                LLMUsageShotFixtures.screen(.loading)
            },
            // The run log and the Progress tab: no tokens, a pointer to Usage → Watchtower.
            DesignShot(name: "usage-run-log", size: NSSize(width: 860, height: 360)) {
                LLMUsageShotFixtures.runLog()
            },
            DesignShot(name: "usage-progress-run", size: NSSize(width: 860, height: 420)) {
                LLMUsageShotFixtures.progress()
            }
        ] + ProviderFallbackShotFixtures.shots + ProviderFallbackShotFixtures.runtimeShots + OnboardingAgentShotFixtures.shots + CleanupShotFixtures.Frame.allCases.map { frame in
            // The Clean Up screen (#1107), mockup frames A–G.
            DesignShot(name: "workbench-cleanup-\(frame.rawValue)", size: NSSize(width: 1040, height: frame.height)) {
                CleanupShotFixtures.screen(frame)
            }
        } + ReportProblemShotFixtures.shots + CatalogPage.allCases.map { page in
            DesignShot(name: "catalog-\(page.rawValue)", size: NSSize(width: 900, height: 0)) {
                // A fixed moment, so the Typography page's live counter is the same every run.
                AnyView(CatalogPageBody(page: page)
                    .environment(\.galleryFrozenDate, Date(timeIntervalSinceReferenceDate: 812_345.6))
                    .shotFrame()
                    .detailBackground())
            }
        } + InboxBuilderAShotFixtures.shots + InboxBuilderBShotFixtures.shots
    }
}

private extension View {
    /// Fills the shot's whole frame, content at the top leading corner, so
    /// the surface behind it covers the PNG.
    func shotFrame() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The sample data behind the catalog's shots. A fixture that fails to
/// build fails the running test and renders its error as text, so the shot
/// never passes as a blank or stand-in PNG.
@MainActor
enum DesignShotFixtures {
    private static var poolPath: String?
    private static var newTaskPoolPath: String?
    /// Every fixture's defaults suite, removed by `cleanUp`.
    static let defaultsSuite = "DesignShotsTests"

    /// Removes the header's database and layout defaults (`DesignShotsTests`
    /// calls it once, after the class).
    static func cleanUp() {
        if let poolPath { TestDatabase.cleanup(path: poolPath) }
        poolPath = nil
        ReviewShotFixtures.cleanUp()
        ReviewerShotFixtures.cleanUp()
        SpecReviewShotFixtures.cleanUp()
        InboxShotFixtures.cleanUp()
        OneInboxShotFixtures.cleanUp()
        AutomationShotFixtures.cleanUp()
        BuiltinShotFixtures.cleanUp()
        CleanupShotFixtures.cleanUp()
        AgentSettingsShotFixtures.cleanUp()
        CoachShotFixtures.cleanUp()
        InboxFolderMenuShotFixtures.cleanUp()
        InboxFoldersShotFixtures.cleanUp()
        InboxApprovalsShotFixtures.cleanUp()
        ProjectPageShotFixtures.cleanUp()
        if let newTaskPoolPath { TestDatabase.cleanup(path: newTaskPoolPath) }
        newTaskPoolPath = nil
        UserDefaults().removePersistentDomain(forName: defaultsSuite)
    }

    static func failure(_ error: Error) -> AnyView {
        XCTFail("design shot fixture failed: \(error)")
        return AnyView(Text("fixture failed: \(String(describing: error))").foregroundStyle(.red))
    }

    // MARK: - Workbench

    /// The header's view buttons with Terminal on and Board off (a session
    /// pane alone). No CLI and no sessions, so Changes and Chat show disabled.
    static func workbenchHeader() -> AnyView {
        do {
            let (pool, path) = try TestDatabase.createPool()
            if let poolPath { TestDatabase.cleanup(path: poolPath) }
            poolPath = path
            let project = try pool.write { db in
                let id = try TestDatabase.insertWorkbench(db, folder: "/tmp/acme")
                return try XCTUnwrap(try Workbench.fetchOne(db, sql: "SELECT * FROM projects WHERE id = ?", arguments: [id]))
            }
            let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
            let vm = WorkbenchesViewModel(dbPool: pool, cli: nil, defaults: defaults)
            var layout = WorkspaceLayout.default
            layout.primary = .session(1)
            vm.setLayout(layout, projectID: project.id)
            return AnyView(WorkbenchHeaderControls(vm: vm, project: project, onDelete: {}, onCleanUpOldWorktrees: {}))
        } catch {
            return failure(error)
        }
    }

    /// A collapsed parent, a leaf and a selected leaf, with every priority
    /// and three statuses between them.
    static func boardCards() -> AnyView {
        do {
            let queue = try TestDatabase.create()
            let (rows, parentID) = try queue.write { db -> ([WorkbenchBoardRow], Int64) in
                let pid = try TestDatabase.insertWorkbench(db, folder: "/tmp/acme")
                let parent = try TestDatabase.insertWorkbenchTarget(db, projectID: pid, text: "Billing export for acme",
                                                                    status: "in_progress", priority: "high")
                try TestDatabase.insertWorkbenchTarget(db, projectID: pid, text: "CSV columns", status: "done",
                                                       parentID: parent)
                try TestDatabase.insertWorkbenchTarget(db, projectID: pid, text: "Nightly schedule", status: "in_progress",
                                                       parentID: parent)
                try TestDatabase.insertWorkbenchTarget(db, projectID: pid, text: "Fix the login redirect",
                                                       status: "todo", priority: "low")
                try TestDatabase.insertWorkbenchTarget(db, projectID: pid, text: "Invoice PDF layout",
                                                       status: "blocked", priority: "medium")
                let roots = try WorkbenchQueries.board(db, projectID: pid)
                return (WorkbenchBoardOutline.rows(roots, collapsed: [Int(parent)], showDone: true), parent)
            }
            let selectedID = rows.last?.node.target.id
            return AnyView(VStack(spacing: 6) {
                ForEach(rows, id: \.node.target.id) { row in
                    WorkbenchBoardCardView(row: row, isSelected: row.node.target.id == selectedID,
                                           isCollapsed: Int64(row.node.target.id) == parentID) {}
                }
                Spacer(minLength: 0)
            })
        } catch {
            return failure(error)
        }
    }

    /// The New Task panel (AI-14 §2), opened for a sub-task of a group.
    static func newTask() -> AnyView {
        do {
            let (pool, path) = try TestDatabase.createPool()
            if let newTaskPoolPath { TestDatabase.cleanup(path: newTaskPoolPath) }
            newTaskPoolPath = path
            let (pid, parent) = try pool.write { db -> (Int64, Int64) in
                let pid = try TestDatabase.insertWorkbench(db, folder: "/tmp/acme")
                let parent = try TestDatabase.insertWorkbenchTarget(db, projectID: pid, text: "Billing export for acme",
                                                                    status: "in_progress", priority: "high")
                return (pid, parent)
            }
            let vm = WorkbenchBoardViewModel(dbPool: pool, projectID: pid)
            vm.load()
            return AnyView(WorkbenchNewTargetSheet(
                request: WorkbenchNewTargetRequest(parentID: Int(parent)), vm: vm, workbenchName: "acme"
            ))
        } catch {
            return failure(error)
        }
    }

    /// The target panel's small parts: a section header with a count, a
    /// status menu label and a read-only one, the `#id` badge and an agent tag.
    static func panelParts() -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Sub-tasks", systemImage: "checklist", count: 3)
            HStack(spacing: 8) {
                MenuLabel(text: "In progress", systemImage: "circle.lefthalf.filled", color: .blue)
                MenuLabel(text: "Done", systemImage: "checkmark.circle.fill", color: .green, isMenu: false)
                CountBadge(text: "#42")
                OutlineTag(text: "Codex")
            }
            Spacer(minLength: 0)
        })
    }

    /// Three tab rows of a side panel, the middle one selected.
    static func sessionsPanel() -> AnyView {
        AnyView(HStack(spacing: 0) {
            List {
                ForEach(Array(["acme setup", "Billing export", "Login redirect"].enumerated()), id: \.offset) { index, title in
                    Label(title, systemImage: "terminal")
                        .panelTab(isSelected: index == 1)
                }
            }
            .clearPlainList()
            .frame(width: 220)
            .panelSurface()
            Color.clear.detailBackground()
        })
    }

    /// Two live codex sessions' state lines: one watched, one the session
    /// host cannot watch (U6), as the sessions panel and the strip draw them.
    static func sessionNotWatched() -> AnyView {
        let rows: [(String, SessionSwitcherPresentation.State)] = [
            ("Billing export", .init(kind: .working, live: true)),
            ("Login redirect", .init(kind: .working, live: true, watchIssue: "compressed"))
        ]
        return AnyView(VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 6) {
                    SessionLiveDot(state: row.1)
                    Text(row.0).lineLimit(1)
                    Spacer(minLength: 8)
                    SessionStateLabel(state: row.1)
                }
            }
        }
        .padding(12)
        .shotFrame()
        .panelBackground())
    }

    /// The same preview wrapper and row as a live drag, including a title
    /// much wider than the narrow panel. No live session or VM is needed.
    static func sessionDragPreview(width: CGFloat, busy: Bool) -> AnyView {
        let session = TerminalSession(
            id: 42, projectID: 1, kind: .codex,
            title: "acme billing export and invoice reconciliation",
            titleSource: .user, folderPath: "/tmp/acme",
            createdAt: "2026-10-01T12:00:00Z", lastActiveAt: "2026-10-01T12:00:00Z"
        )
        let row = SessionSwitcherPresentation.Row(
            session: session, state: busy ? .live(.working) : .notStarted,
            caption: busy ? "Working" : "Not running", badge: nil, shortcut: nil
        )
        let content = TerminalSessionRow(
            row: row, actions: SessionRowActions(open: { _ in }, rename: { _ in }, delete: { _ in }),
            reportLine: "#42 · 3/5", reportProgress: 0.6, opensIn: .chat
        )
        .panelTab(isSelected: true)
        let height = ViewRenderProbe.fittingHeight(AnyView(content), width: width)
        return AnyView(SessionRowDragPreview(size: CGSize(width: width, height: height)) { content }
            .padding(Spacing.medium)
            .shotFrame()
            .panelBackground())
    }

    // MARK: - Chat

    static func chatRows() -> AnyView {
        do {
            let queue = try TestDatabase.create()
            let items = try queue.write { db -> [ChatThreadItem] in
                let conv = try TestDatabase.insertChatConversation(db)
                let texts = [("user", "What changed in the acme billing export this week?"),
                             ("assistant", "The export gained **two columns** and now runs nightly.\n\n- `invoice_id`\n- `paid_at`")]
                return try texts.map { role, text in
                    let id = try TestDatabase.insertChatMessage(db, conversationID: conv, role: role, text: text)
                    let message = try XCTUnwrap(ChatMessageRecord.fetchOne(
                        db, sql: "SELECT * FROM chat_messages WHERE id = ?", arguments: [id]))
                    return ChatThreadItem(message: message, steps: [], siblingIndex: 1, siblingCount: 1)
                }
            }
            return AnyView(VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    ChatMessageRow(item: item, isLast: index == items.count - 1, isEditing: false, actions: ChatRowActions())
                }
                HStack {
                    Spacer()
                    FloatingButtonLabel(title: "Jump to latest", systemImage: "arrow.down")
                    Spacer()
                }
                Spacer(minLength: 0)
            })
        } catch {
            return failure(error)
        }
    }

    /// An owner message that saved a decision, and each other mark state.
    static func chatKnowledgeMarks() -> AnyView {
        let marks: [(ChatKnowledgeMark, String)] = [
            (.saved(kind: "note", ideaID: 2), "note"), (.empty, "decision"), (.changed(ideaID: 3), "decision"),
            (.undone, "decision"), (.failed("database is locked"), "decision")
        ]
        return AnyView(VStack(alignment: .trailing, spacing: 12) {
            UserMessageBubble(text: "decided: release acme on Tuesdays from next week")
            ChatKnowledgeMarkLine(mark: .saved(kind: "decision", ideaID: 1), prefixKind: "decision",
                                  undo: {}, openInInbox: { _ in })
            ForEach(Array(marks.enumerated()), id: \.offset) { _, entry in
                ChatKnowledgeMarkLine(mark: entry.0, prefixKind: entry.1, undo: {}, openInInbox: { _ in })
            }
            Spacer(minLength: 0)
        })
    }

    // MARK: - Workchat

    /// The live line with a tool step and its timer, Thinking…, and the
    /// empty row that keeps its height.
    static func workchatLiveLine() -> AnyView {
        let now = Date()
        let tool = WorkchatActivityPresenter.line(
            activity: SessionFeedActivity(tool: "Bash", summary: "make test FILTER=AcmeExportTests", startedAt: now.addingTimeInterval(-75)),
            working: true, background: false, runningSubagents: 0, stateAt: now, lastAgentAt: nil)
        let thinking = WorkchatActivityPresenter.line(
            activity: nil, working: true, background: false, runningSubagents: 0,
            stateAt: now.addingTimeInterval(-12), lastAgentAt: nil)
        return AnyView(VStack(spacing: 0) {
            WorkchatActivityLine(line: tool)
            Divider()
            WorkchatActivityLine(line: thinking)
            Divider()
            WorkchatActivityLine(line: nil)
            Divider()
            Spacer(minLength: 0)
        })
    }

    // MARK: - Calendar

    /// A past event, one starting within the hour and one happening now.
    /// The times follow the clock (the row reads `Date()`), so the time
    /// texts differ between runs; the styles do not.
    static func calendarRows() -> AnyView {
        let now = Date()
        let events = [
            event("past", title: "acme weekly sync", start: now.addingTimeInterval(-3 * 3600), minutes: 60, location: "Room 2"),
            event("now", title: "Billing export review", start: now.addingTimeInterval(-15 * 60), minutes: 45,
                  location: "meet.example.com"),
            event("soon", title: "Design critique", start: now.addingTimeInterval(40 * 60), minutes: 30, location: "")
        ]
        return AnyView(VStack(spacing: 6) {
            ForEach(events, id: \.id) { CalendarEventRow(event: $0, recordingCount: $0.id == "past" ? 1 : 0) }
            Spacer(minLength: 0)
        })
    }

    private static func event(_ id: String, title: String, start: Date, minutes: Double, location: String) -> CalendarEvent {
        let iso = ISO8601DateFormatter()
        let row: Row = [
            "id": id, "calendar_id": "cal1", "title": title, "description": "", "location": location,
            "start_time": iso.string(from: start), "end_time": iso.string(from: start.addingTimeInterval(minutes * 60)),
            "organizer_email": "owner@example.com",
            "attendees": #"[{"email":"a@example.com","display_name":"A","response_status":"accepted","slack_user_id":""}]"#,
            "is_recurring": 0, "is_all_day": 0, "event_status": "confirmed", "event_type": "", "html_link": "",
            "raw_json": "{}", "synced_at": "", "updated_at": ""
        ]
        return CalendarEvent(row: row)
    }

    // MARK: - Buttons

    static func buttons() -> AnyView {
        AnyView(HStack(spacing: 10) {
            Button("Save") {}.buttonStyle(.kitPrimary)
            Button("Save") {}.buttonStyle(.kitPrimary).disabled(true)
            Button("Stop") {}.buttonStyle(.kitDestructive).controlSize(.small)
            Button("Stop") {}.buttonStyle(.kitDestructive)
            Spacer(minLength: 0)
        })
    }
}
