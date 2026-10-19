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
            DesignShot(name: "workbench-panel-parts", size: NSSize(width: 440, height: 120)) {
                AnyView(DesignShotFixtures.panelParts().padding(12).shotFrame().detailBackground())
            },
            DesignShot(name: "sessions-panel", size: NSSize(width: 300, height: 140)) {
                AnyView(DesignShotFixtures.sessionsPanel())
            },
            DesignShot(name: "chat-rows", size: NSSize(width: 560, height: 280)) {
                AnyView(DesignShotFixtures.chatRows().padding(12).shotFrame().detailBackground())
            },
            DesignShot(name: "calendar-rows", size: NSSize(width: 480, height: 200)) {
                AnyView(DesignShotFixtures.calendarRows().padding(12).shotFrame().detailBackground())
            },
            DesignShot(name: "buttons", size: NSSize(width: 460, height: 64)) {
                AnyView(DesignShotFixtures.buttons().padding(12).shotFrame().panelBackground())
            },
            DesignShot(name: "gallery", size: NSSize(width: 900, height: 0)) {
                AnyView(DesignSystemGalleryContent().shotFrame().detailBackground())
            },
            DesignShot(name: "kit-new-components", size: NSSize(width: 640, height: 760)) {
                AnyView(GalleryNewComponents().padding(Spacing.page).shotFrame().detailBackground())
            }
        ]
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
    private static let defaultsSuite = "DesignShotsTests"

    /// Removes the header's database and layout defaults (`DesignShotsTests`
    /// calls it once, after the class).
    static func cleanUp() {
        if let poolPath { TestDatabase.cleanup(path: poolPath) }
        poolPath = nil
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
