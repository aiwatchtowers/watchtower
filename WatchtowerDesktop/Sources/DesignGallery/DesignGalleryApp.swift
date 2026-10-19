import AppKit
import DesignKitCatalog
import SwiftUI

/// The design gallery (#760): a separate window over the Desktop design kit,
/// run with `make design-gallery`. Never part of the app bundle.
@main
struct DesignGalleryApp: App {
    @NSApplicationDelegateAdaptor private var delegate: GalleryAppDelegate

    var body: some Scene {
        WindowGroup("Design Gallery") {
            GalleryRootView()
        }
        .defaultSize(width: 1100, height: 760)
    }
}

/// `swift run` starts a bare executable with no bundle: make it a regular
/// app with a Dock icon and bring its window to the front.
final class GalleryAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
