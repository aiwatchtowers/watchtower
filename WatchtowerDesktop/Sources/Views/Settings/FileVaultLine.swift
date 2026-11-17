import AppKit
import SwiftUI
import WatchtowerCore
import DesignKit

/// The FileVault-off line of Privacy and Connections → Slack (#1769): shown
/// only for a definite `.off`, with a button to FileVault's settings pane.
struct FileVaultLine: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if FileVaultNotice.isShown(appState.fileVaultState) {
            FileVaultLineContent()
        }
    }
}

struct FileVaultLineContent: View {
    var body: some View {
        HStack(alignment: .top, spacing: Spacing.regular) {
            Image(systemName: "lock.open.fill").foregroundStyle(Tone.warning)
            VStack(alignment: .leading, spacing: Spacing.small) {
                Text(FileVaultNotice.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                Button(FileVaultNotice.action) {
                    if let url = URL(string: FileVaultNotice.settingsURL) { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(.kitSecondary)
            }
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tone.warning.opacity(ChipTint.fillOpacity), in: RoundedRectangle(cornerRadius: Radius.row))
    }
}
