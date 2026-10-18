import SwiftUI

/// A failed write over a list that still has content (board #670): the
/// list stays, the error shows above it until closed. A screen with nothing
/// to show keeps its full-page error view.
struct WriteErrorBanner: View {
    let message: String
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            Spacer()
            Button(action: onClose) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Dismiss")
        }
        .padding(8)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal)
        .padding(.vertical, 6)
    }
}
