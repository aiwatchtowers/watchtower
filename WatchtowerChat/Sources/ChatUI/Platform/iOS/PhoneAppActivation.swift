#if os(iOS)
import SwiftUI

extension View {
    /// Runs `action` each time the scene becomes active.
    func onAppActivation(_ action: @escaping () -> Void) -> some View {
        modifier(AppActivation(action: action))
    }
}

private struct AppActivation: ViewModifier {
    let action: () -> Void
    @Environment(\.scenePhase) private var phase

    func body(content: Content) -> some View {
        content.onChange(of: phase) { _, phase in
            if phase == .active { action() }
        }
    }
}
#endif
