import AppKit
import GRDB
import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The Projects tab reads as one surface with its side panel: the title row,
/// the project page header and the Board render in the panel list's colour,
/// not the darker detail backdrop `MainNavigationView` puts behind every tab.
/// (The terminal's transparency under dark is `TerminalPaletteTests`'.)
@MainActor
final class ProjectsBackgroundRenderTests: XCTestCase {
    private var manager: DatabaseManager!
    private var path: String!
    private var suiteName: String!

    override func setUpWithError() throws {
        (manager, path) = try TestDatabase.createDatabaseManager()
        suiteName = "ProjectsBackgroundRenderTests-\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    private static let size = NSSize(width: 900, height: 500)

    func testProjectPagePaintsThePanelColourOverTheDetailBackdrop() async throws {
        let projectID = try await manager.dbPool.write { db -> Int64 in
            let id = try TestDatabase.insertProject(db)
            _ = try TestDatabase.insertProjectTarget(db, projectID: id)
            return id
        }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let vm = ProjectsViewModel(dbPool: manager.dbPool, cli: ProjectCLI(runner: FakeCLIRunner()), defaults: defaults)
        await vm.reload()
        vm.drill(into: projectID)
        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(vm.selectedProject?.id, projectID, "the page, not the empty state, is on screen")
        let appState = AppState()
        appState.databaseManager = manager

        for name in [NSAppearance.Name.darkAqua, .aqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            let panel = try pixel(render(List { EmptyView() }.panelListStyle(), appearance), x: 450, y: 250)
            XCTAssertEqual(panel.alpha, 255, "an empty capture would compare equal to another one")
            // A sentinel stands in for the detail backdrop, so any spot the
            // tab leaves unpainted shows.
            let page = try render(ProjectsView(vm: vm).environment(appState).background(Color.red), appearance)
            // Near both edges of the page and its middle (the Board), right
            // of the panel whether the panel is shown or not.
            for (x, y) in [(880, 15), (880, 55), (880, 480), (700, 300)] {
                XCTAssertEqual(try pixel(page, x: x, y: y), panel, "\(name) at (\(x), \(y))")
            }
        }
    }

    // MARK: - Rendering

    private struct RGBA: Equatable, CustomStringConvertible {
        let red: Int, green: Int, blue: Int, alpha: Int
        var description: String { "rgba(\(red), \(green), \(blue), \(alpha))" }
    }

    private func render(_ view: some View, _ appearance: NSAppearance) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view.frame(width: Self.size.width, height: Self.size.height))
        host.frame = NSRect(origin: .zero, size: Self.size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        // The layer tree, composited as on screen.
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(Self.size.width), pixelsHigh: Int(Self.size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        try XCTUnwrap(host.layer).render(in: context.cgContext)
        return bitmap
    }

    private func pixel(_ bitmap: NSBitmapImageRep, x: Int, y: Int) throws -> RGBA {
        let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
        func byte(_ value: CGFloat) -> Int { Int((value * 255).rounded()) }
        return RGBA(red: byte(color.redComponent), green: byte(color.greenComponent),
                    blue: byte(color.blueComponent), alpha: byte(color.alphaComponent))
    }
}
