#if os(macOS)
import SwiftUI

/// The chat's keys on the Mac beside the field's own (Enter sends, Shift+Enter a new line): ⌘↩ sends, ⌘. stops the
/// running turn. The window's ⌘K / ⌘N stay in the app's shell.
struct ChatComposerShortcuts: View {
    let canSend: Bool
    let canStop: Bool
    let onSend: () -> Void
    let onStop: () -> Void

    var body: some View {
        ZStack {
            Button("Send", action: onSend)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSend)
            Button("Stop", action: onStop)
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!canStop)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}
#endif
