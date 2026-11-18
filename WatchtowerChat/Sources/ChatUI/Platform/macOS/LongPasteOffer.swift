#if os(macOS)
import SwiftUI
import WatchtowerDesign

/// The non-modal offer under a long text paste.
public struct LongPasteOffer: View {
    let characterCount: Int
    let onAttach: () -> Void
    let onKeep: () -> Void

    public init(characterCount: Int, onAttach: @escaping () -> Void, onKeep: @escaping () -> Void) {
        self.characterCount = characterCount
        self.onAttach = onAttach
        self.onKeep = onKeep
    }

    public var body: some View {
        HStack(spacing: Spacing.regular) {
            Text("Long paste: \(characterCount.formatted()) characters")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Attach as File", action: onAttach)
                .buttonStyle(.link)
                .font(.caption)
            Button("Keep as Text", action: onKeep)
                .buttonStyle(.link)
                .font(.caption)
        }
    }
}
#endif
