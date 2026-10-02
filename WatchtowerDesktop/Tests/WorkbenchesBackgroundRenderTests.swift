import AppKit
import GRDB
import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The Projects workspace reads as AI Chat's conversation does: the title
/// row, the project page header and the Board render in the detail backdrop
/// `MainNavigationView` puts behind every tab, the side panel in its own
/// colour, and the session on screen is a tab that runs on into the
/// workspace across the panel's edge line.
/// (The terminal's transparency under dark is `TerminalPaletteTests`'.)
@MainActor
final class WorkbenchesBackgroundRenderTests: XCTestCase {
    private var manager: DatabaseManager!
    private var path: String!
    private var suiteName: String!

    override func setUpWithError() throws {
        (manager, path) = try TestDatabase.createDatabaseManager()
        suiteName = "WorkbenchesBackgroundRenderTests-\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    private static let size = NSSize(width: 900, height: 500)

    func testProjectPagePaintsTheDetailBackdropBesideThePanelColour() async throws {
        let projectID = try await manager.dbPool.write { db -> Int64 in
            let id = try TestDatabase.insertWorkbench(db)
            _ = try TestDatabase.insertWorkbenchTarget(db, projectID: id)
            return id
        }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let vm = WorkbenchesViewModel(dbPool: manager.dbPool, cli: WorkbenchCLI(runner: FakeCLIRunner()), defaults: defaults)
        await vm.reload()
        vm.drill(into: projectID)
        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(vm.selectedWorkbench?.id, projectID, "the page, not the empty state, is on screen")
        let appState = AppState.isolated()
        appState.databaseManager = manager

        for name in [NSAppearance.Name.darkAqua, .aqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            let panel = try pixel(render(List { EmptyView() }.panelListStyle(), appearance), x: 450, y: 250)
            let detail = try pixel(render(Color.clear.detailBackground(), appearance), x: 450, y: 250)
            XCTAssertEqual(panel.alpha, 255, "an empty capture would compare equal to another one")
            XCTAssertEqual(detail.alpha, 255, "an empty capture would compare equal to another one")
            // A sentinel stands in for the window behind the tab, so any spot
            // the tab leaves unpainted shows.
            let page = try render(WorkbenchesView(vm: vm).environment(appState).background(Color.red), appearance)
            // Near both edges of the page and its middle (the Board), right
            // of the panel whether the panel is shown or not; the title row
            // between its title and the Go to… button at its right end.
            for (x, y) in [(650, 15), (880, 55), (880, 480), (700, 300)] {
                XCTAssertEqual(try pixel(page, x: x, y: y), detail, "\(name) workspace at (\(x), \(y))")
            }
            // The panel's empty space below its list.
            XCTAssertEqual(try pixel(page, x: 100, y: 400), panel, "\(name) panel")
        }
    }

    /// The session on screen is a tab of the workspace: at its row the
    /// panel's edge line is covered by the workspace backdrop; at another
    /// row and below the list the line stays.
    func testSelectedSessionTabCoversThePanelEdgeLine() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("acme-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let projectID = try await manager.dbPool.write { db in
            try TestDatabase.insertWorkbench(db, name: "acme", folder: folder.path)
        }
        var sessions: [TerminalSession] = []
        for title in ["first", "second", "third"] {
            let row = try await manager.dbPool.write { db in
                try TerminalSessionQueries.create(db, .init(
                    projectID: projectID, kind: .claude, title: title, folderPath: folder.path,
                    claudeSessionID: UUID().uuidString.lowercased()
                ))
            }
            sessions.append(row)
        }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let vm = WorkbenchesViewModel(dbPool: manager.dbPool, cli: WorkbenchCLI(runner: FakeCLIRunner()), defaults: defaults)
        await vm.reload()
        vm.drill(into: projectID)
        _ = await vm.loadSessions(projectID: projectID)
        // The middle row of three (the newest is listed first), not running:
        // its pane shows Resume and starts nothing.
        let selected = sessions[1]
        var layout = vm.layout
        layout.show(.session(selected.id))
        vm.layout = layout
        XCTAssertEqual(vm.drilledSessions.map(\.id), sessions.reversed().map(\.id))
        XCTAssertEqual(vm.panelSelection, .session(selected.id))
        let appState = AppState.isolated()
        appState.databaseManager = manager

        for name in [NSAppearance.Name.darkAqua, .aqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            let detail = try pixel(render(Color.clear.detailBackground(), appearance), x: 450, y: 250)
            let page = try render(WorkbenchesView(vm: vm).environment(appState), appearance)
            // The panel's last column, where its edge line runs; the rows sit
            // under the header and the SESSIONS label, about 26pt apart.
            let edge = Int(PanelResizeHandle.defaultWidth) - 1
            let line = try pixel(page, x: edge, y: 400)
            XCTAssertNotEqual(line, detail, "\(name): the edge line shows below the list")
            XCTAssertEqual(try pixel(page, x: edge, y: 90), detail, "\(name): the selected tab covers the line")
            XCTAssertEqual(try pixel(page, x: edge, y: 64), line, "\(name): another row keeps the line")
            // Through the resize strip into the page, the same colour.
            XCTAssertEqual(try pixel(page, x: edge + 4, y: 90), detail, "\(name): the strip beside the tab")
        }
    }

    // MARK: - Rendering

    private func render(_ view: some View, _ appearance: NSAppearance) throws -> NSBitmapImageRep {
        try ViewRenderProbe(size: Self.size).render(view, appearance)
    }

    private func pixel(_ bitmap: NSBitmapImageRep, x: Int, y: Int) throws -> ViewRenderProbe.RGBA {
        try ViewRenderProbe(size: Self.size).pixel(bitmap, x: x, y: y)
    }
}
