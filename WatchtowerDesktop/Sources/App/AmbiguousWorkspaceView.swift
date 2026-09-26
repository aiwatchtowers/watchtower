import SwiftUI

/// Shown at launch in place of the app when no `active_workspace` is set and
/// several workspaces hold a database (`WatchtowerDatabaseError.ambiguousWorkspace`).
/// The CLI refuses to start on that config, so the Desktop does not guess
/// either — it names the candidates and the command that picks one.
struct AmbiguousWorkspaceView: View {
    let candidates: [String]
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.questionmark")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Several workspaces hold a database")
                .font(.headline)
            Text(candidates.joined(separator: ", "))
                .font(.body.monospaced())
                .textSelection(.enabled)
            Text("Pick the one Watchtower should use, then try again:")
                .foregroundStyle(.secondary)
            Text("watchtower config set active_workspace <name>")
                .font(.body.monospaced())
                .textSelection(.enabled)
            Button("Try Again", action: onRetry)
                .buttonStyle(.borderedProminent)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
