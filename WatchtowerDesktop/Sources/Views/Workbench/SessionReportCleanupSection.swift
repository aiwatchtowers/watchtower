import SwiftUI
import WatchtowerCore

/// The session report's "Cleanup" section (board #535, spec
/// 2026-10-12-session-cleanup §12): Go's summary of the session's last
/// cleanup (`cleanup_result`) and when it ran, or "Cleanup ran — result
/// unreadable"; nothing when the session was never cleaned up. It watches
/// the stored result while shown, so a cleanup run from anywhere (the app,
/// the agent's `finish_session`) shows at once.
struct SessionReportCleanupSection: View {
    let vm: WorkbenchesViewModel
    let sessionID: Int64

    var body: some View {
        content
            .task(id: sessionID) { await vm.observeCleanupRecord(sessionID: sessionID) }
    }

    @ViewBuilder
    private var content: some View {
        if let line = vm.cleanupReportLine(sessionID: sessionID) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Cleanup")
                    .font(.subheadline.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(line)
                if let at = vm.cleanupRecords[sessionID]?.at, !at.isEmpty {
                    Text(TimeFormatting.relativeTime(from: at)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 20)
        } else {
            // A zero-size anchor, so the task runs before any result exists;
            // the report stacks it with no spacing.
            Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
        }
    }
}
