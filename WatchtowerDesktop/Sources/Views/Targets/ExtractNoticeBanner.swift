import SwiftUI

/// The outcome of an extraction started from the New Target form, rendered
/// inline in that form.
///
/// Before this existed, `CreateTargetSheet` handed `.empty`/`.failed` to the
/// global `ExtractIndicatorView` capsule — which lives in the main window,
/// underneath this modal sheet, where it is neither visible nor clickable. The
/// spinner simply stopped and the button looked like it had done nothing.
struct ExtractNotice: Equatable {
    enum Kind: Equatable {
        /// A single proposal was merged into the form the user is looking at.
        case filled
        /// The model ran fine but found no target in the text.
        case nothing
        /// The extraction call itself failed.
        case failed
    }

    var kind: Kind
    var message: String
    var canRetry: Bool
    /// Raw CLI stderr behind a `.failed` message, shown under "Show details".
    var details: String?
}

/// Inline banner for an `ExtractNotice`, with the actions that make sense for
/// its kind: Undo for a fill, Retry for a recoverable failure.
struct ExtractNoticeBanner: View {
    let notice: ExtractNotice
    let onRetry: () -> Void
    let onUndo: () -> Void
    let onDismiss: () -> Void

    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                Text(notice.message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                actions
            }
            if let details = notice.details, !details.isEmpty {
                DisclosureGroup("Show details", isExpanded: $showDetails) {
                    Text(details)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
            }
        }
        .padding(10)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var actions: some View {
        switch notice.kind {
        case .filled:
            Button("Undo", action: onUndo)
                .controlSize(.small)
        case .nothing, .failed:
            if notice.canRetry {
                Button("Retry", action: onRetry)
                    .controlSize(.small)
            }
            Button("Dismiss", action: onDismiss)
                .controlSize(.small)
        }
    }

    private var icon: String {
        switch notice.kind {
        case .filled: return "sparkles"
        case .nothing: return "questionmark.circle"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private var tint: Color {
        switch notice.kind {
        case .filled: return .accentColor
        case .nothing: return .secondary
        case .failed: return .orange
        }
    }
}
