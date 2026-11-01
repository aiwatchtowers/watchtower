import SwiftUI
import UIKit
@testable import WatchtowerMobile

/// Renders a SwiftUI screen to PNGs in light and dark mode, in a window on
/// the test host's scene at the simulator's screen size and scale (design
/// pass spec §6.2). `drawHierarchy` does not draw the system's scroll-edge
/// effect, so content under the tab bar shows as plain text.
@MainActor
final class ScreenshotHost {
    /// One INDEX.md row: the screen's number, the view, its source file and
    /// how the tour reached it.
    struct IndexRow {
        let number: String
        let view: String
        let source: String
        let reached: String
    }

    enum ShotError: Error {
        case noWindowScene
        case emptyImage(String)
    }

    let directory: URL
    let env: AppEnvironment
    let linking: LinkingViewModel

    init(directory: URL, env: AppEnvironment, linking: LinkingViewModel) {
        self.directory = directory
        self.env = env
        self.linking = linking
    }

    /// Writes `<name>-light.png` and `<name>-dark.png`; with `endName`, also
    /// `<endName>-light.png` and `-dark.png` scrolled to the end.
    func capture(_ name: String, _ view: some View, endName: String? = nil, settle: Duration = .milliseconds(600)) async throws {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            throw ShotError.noWindowScene
        }
        for (style, suffix) in [(UIUserInterfaceStyle.light, "light"), (UIUserInterfaceStyle.dark, "dark")] {
            let window = UIWindow(windowScene: scene)
            window.frame = scene.screen.bounds
            window.overrideUserInterfaceStyle = style
            window.rootViewController = UIHostingController(rootView: view.environment(env).environment(linking))
            window.makeKeyAndVisible()
            // Replica observation and layout settle (a presented alert longer).
            try await Task.sleep(for: settle)
            try render(window, as: "\(name)-\(suffix)")
            if let endName {
                // Content that fits has no end to scroll to: the end shot is
                // the screen at rest.
                if let scroll = Self.tallScrollView(in: window) {
                    scroll.contentOffset.y = Self.endOffset(of: scroll)
                    try await Task.sleep(for: .milliseconds(300))
                }
                try render(window, as: "\(endName)-\(suffix)")
            }
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    /// The narrow variant's size: an iPhone SE's screen, at the largest Dynamic Type size.
    static let narrowSize = CGSize(width: 375, height: 667)

    /// Writes `<name>-light.png`, `<name>-dark.png` and `<name>-narrow.png` (light, `narrowSize`, the largest
    /// accessibility text size): the relay client mockups' three frames per state.
    func captureThree(_ name: String, _ view: some View, settle: Duration = .milliseconds(600)) async throws {
        try await capture(name, view, settle: settle)
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            throw ShotError.noWindowScene
        }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: Self.narrowSize)
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = UIHostingController(
            rootView: view.environment(env).environment(linking).dynamicTypeSize(.accessibility5)
        )
        window.makeKeyAndVisible()
        try await Task.sleep(for: settle)
        try render(window, as: "\(name)-narrow")
        window.isHidden = true
        window.rootViewController = nil
    }

    /// The first scroll view, breadth first, that can scroll: its content
    /// plus its adjusted top and bottom insets (navigation bar, tab bar) is
    /// taller than its bounds.
    static func tallScrollView(in root: UIView) -> UIScrollView? {
        var queue = [root]
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if let scroll = view as? UIScrollView,
               scroll.contentSize.height + scroll.adjustedContentInset.top + scroll.adjustedContentInset.bottom > scroll.bounds.height {
                return scroll
            }
            queue += view.subviews
        }
        return nil
    }

    /// The offset that shows the end of `scroll`'s content above its bottom
    /// inset.
    static func endOffset(of scroll: UIScrollView) -> CGFloat {
        scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height
    }

    /// Removes an earlier run's PNGs and index, so the file count is this
    /// run's.
    static func clear(_ directory: URL) throws {
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        where file.pathExtension == "png" || file.lastPathComponent == "INDEX.md" {
            try files.removeItem(at: file)
        }
    }

    static func writeIndex(_ rows: [IndexRow], to directory: URL) throws {
        let lines = ["# Screenshot tour", "", "| No. | View | Source | Reached |", "|---|---|---|---|"]
            + rows.map { "| \($0.number) | \($0.view) | `\($0.source)` | \($0.reached) |" }
        try (lines.joined(separator: "\n") + "\n")
            .write(to: directory.appendingPathComponent("INDEX.md"), atomically: true, encoding: .utf8)
    }

    private func render(_ window: UIWindow, as name: String) throws {
        // iOS 26 draws a presented alert outside what `drawHierarchy` captures: a shot of one shows the screen beneath.
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        guard let data = image.pngData(), !data.isEmpty else { throw ShotError.emptyImage(name) }
        try data.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
