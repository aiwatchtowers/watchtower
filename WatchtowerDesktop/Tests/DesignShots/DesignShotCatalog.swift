import AppKit
import GRDB
import SwiftUI
import XCTest
@testable import DesignKitCatalog
@testable import WatchtowerDesktop
import WatchtowerCore
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
        [
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
            DesignShot(name: "chat-rows", size: NSSize(width: 560, height: 280)) {
                AnyView(DesignShotFixtures.chatRows().padding(12).shotFrame().detailBackground())
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
            DesignShot(name: "settings-privacy", size: NSSize(width: 640, height: 420)) {
                AnyView(HomeShotFixtures.privacySettings().shotFrame().detailBackground())
            },
            DesignShot(name: "automation-list", size: NSSize(width: 1280, height: 760)) {
                AutomationShotFixtures.list()
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
            // The one Inbox (C1): every kind under the filter bar, at a fixed moment.
            DesignShot(name: "inbox-all", size: NSSize(width: 1180, height: 720)) {
                OneInboxShotFixtures.all()
            },
            DesignShot(name: "inbox-filter-day", size: NSSize(width: 1180, height: 720)) {
                OneInboxShotFixtures.filterDay()
            },
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
            DesignShot(name: "inbox-message-card", size: NSSize(width: 1180, height: 720)) {
                OneInboxShotFixtures.messageCard()
            },
            DesignShot(name: "inbox-filter-ideas-new", size: NSSize(width: 1180, height: 720)) {
                OneInboxShotFixtures.ideasNew()
            },
            DesignShot(name: "inbox-cheat-sheet", size: NSSize(width: 1180, height: 720)) {
                OneInboxShotFixtures.cheatSheet()
            },
            DesignShot(name: "inbox-day-card-narrow", size: NSSize(width: 420, height: 560)) {
                OneInboxShotFixtures.dayCardNarrow()
            },
            // Branch review (#712, artboards A–C).
            DesignShot(name: "branch-review-changes", size: NSSize(width: 1180, height: 760)) {
                ReviewShotFixtures.changes()
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
            // Search while the messages index is rebuilt (#892).
            DesignShot(name: "search-index-rebuilding", size: NSSize(width: 720, height: 200)) {
                AnyView(SearchShotFixtures.rebuildPending().shotFrame().detailBackground())
            }
        ] + CatalogPage.allCases.map { page in
            DesignShot(name: "catalog-\(page.rawValue)", size: NSSize(width: 900, height: 0)) {
                // A fixed moment, so the Typography page's live counter is the same every run.
                AnyView(CatalogPageBody(page: page)
                    .environment(\.galleryFrozenDate, Date(timeIntervalSinceReferenceDate: 812_345.6))
                    .shotFrame()
                    .detailBackground())
            }
        }
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
        InboxShotFixtures.cleanUp()
        OneInboxShotFixtures.cleanUp()
        AutomationShotFixtures.cleanUp()
        if let newTaskPoolPath { TestDatabase.cleanup(path: newTaskPoolPath) }
        newTaskPoolPath = nil
        UserDefaults().removePersistentDomain(forName: defaultsSuite)
    }

    private static func failure(_ error: Error) -> AnyView {
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
