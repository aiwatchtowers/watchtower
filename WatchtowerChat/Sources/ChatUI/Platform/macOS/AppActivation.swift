#if os(macOS)
import AppKit
import SwiftUI

extension View {
    /// Runs `action` each time the app becomes active (the Mac re-reads the routing status then), for as long as the
    /// view is on screen.
    func onAppActivation(_ action: @escaping () -> Void) -> some View {
        task {
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                action()
            }
        }
    }
}
#endif
