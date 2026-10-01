import AppKit
import GRDB
import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The Projects tab reads as one surface with its side panel: the page, the
/// Board and the terminal (transparent under dark) render in the panel list's
/// colour, not the darker detail backdrop `MainNavigationView` puts behind
/// every tab. Rendered to a bitmap: what counts is what shows through.
@MainActor
final class ProjectsBackgroundRenderTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
    }

    override func tearDown() {
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    private static let size = NSSize(width: 900, height: 500)

    func testProjectPagePaintsThePanelColourOverTheDetailBackdrop() async throws {
        let projectID = try await pool.write { try TestDatabase.insertProject($0) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ProjectsBackgroundRenderTests-\(UUID().uuidString)"))
        let vm = ProjectsViewModel(dbPool: pool, cli: ProjectCLI(runner: FakeCLIRunner()), defaults: defaults)
        await vm.reload()
        vm.drill(into: projectID)

        for name in [NSAppearance.Name.darkAqua, .aqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            let panel = try pixel(render(List { EmptyView() }.panelListStyle(), appearance), x: 450, y: 250)
            // `MainNavigationView` puts a darker detail backdrop behind every
            // tab (the shipped app's palette tells it apart from the panel
            // colour; a test process may resolve both alike): a sentinel
            // stands in for it, so any spot left unpainted shows.
            let page = try render(ProjectsView(vm: vm).environment(AppState()).background(Color.red), appearance)
            // Spots across the page — its top and bottom rows and the
            // middle — right of the panel whether the panel is shown or not.
            for (x, y) in [(880, 15), (880, 55), (880, 480), (700, 300)] {
                XCTAssertEqual(try pixel(page, x: x, y: y), panel, "\(name) at (\(x), \(y))")
            }
        }
    }

    /// The terminal's inner margin (`TerminalHostAttachment.margin`) mirrors
    /// the terminal's own background: under dark it lets the page show
    /// through, under light it stays the opaque dark palette. (The body's
    /// transparency is `TerminalPaletteTests`'; an offscreen capture cannot
    /// composite SwiftTerm's drawn contents.)
    func testTerminalMarginShowsThePageThroughOnlyUnderDark() throws {
        for (name, showsPage) in [(NSAppearance.Name.darkAqua, true), (.aqua, false)] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            let page = try pixel(render(Color.clear.panelBackground(), appearance), x: 450, y: 250)
            let margin = try pixel(render(TerminalHost().panelBackground(), appearance), x: 4, y: 4)
            XCTAssertEqual(margin == page, showsPage, "\(name): margin \(margin), page \(page)")
        }
    }

    // MARK: - Rendering

    private struct RGB: Equatable, CustomStringConvertible {
        let red: Int, green: Int, blue: Int
        var description: String { "rgb(\(red), \(green), \(blue))" }
    }

    /// A terminal in its host container, as `ProjectSessionView` shows it.
    private struct TerminalHost: NSViewRepresentable {
        func makeNSView(context: Context) -> TerminalContainerView {
            let container = TerminalContainerView(frame: NSRect(origin: .zero, size: ProjectsBackgroundRenderTests.size))
            TerminalHostAttachment.attach(PalettedTerminalView(frame: .zero), to: container)
            return container
        }

        func updateNSView(_ nsView: TerminalContainerView, context: Context) {}
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
        // The layer tree, composited as on screen: `cacheDisplay` redraws
        // the views into one context, where the terminal's transparent fill
        // would clear what is under it instead of letting it show.
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(Self.size.width), pixelsHigh: Int(Self.size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        try XCTUnwrap(host.layer).render(in: context.cgContext)
        return bitmap
    }

    /// `x`, `y` in points from the top left, as sRGB bytes.
    private func pixel(_ bitmap: NSBitmapImageRep, x: Int, y: Int) throws -> RGB {
        let scale = CGFloat(bitmap.pixelsWide) / Self.size.width
        let color = try XCTUnwrap(bitmap.colorAt(x: Int(CGFloat(x) * scale), y: Int(CGFloat(y) * scale))?
            .usingColorSpace(.sRGB))
        return RGB(red: Int((color.redComponent * 255).rounded()),
                   green: Int((color.greenComponent * 255).rounded()),
                   blue: Int((color.blueComponent * 255).rounded()))
    }
}
