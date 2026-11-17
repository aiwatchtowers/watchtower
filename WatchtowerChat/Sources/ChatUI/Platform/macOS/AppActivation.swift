#if os(macOS)
import AppKit
import SwiftUI

extension View {
    /// Runs `action` each time the app becomes active (the Mac re-reads the routing status then).
    func onAppActivation(_ action: @escaping () -> Void) -> some View {
        onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in action() }
    }
}
#endif
