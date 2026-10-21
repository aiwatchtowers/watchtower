import SwiftUI
import WatchtowerCore
import DesignKit

/// One compact line above the board for PROJ-07 drift: "Board drift: N"
/// opens the list, and a finding selects its target. A failed or partial
/// check says so (with a Refresh); a complete check with no findings —
/// the board and git agree — shows nothing.
struct WorkbenchDriftBanner: View {
    let report: WorkbenchDriftReport?
    let error: String?
    let onSelect: (Int) -> Void
    let onRefresh: () -> Void
    /// Starts (or opens) a Fix session: for every finding (nil) or one target.
    let onFix: (Int64?) -> Void
    /// The running Fix session for every finding (nil) or one target.
    let liveFix: (Int64?) -> Bool

    @State private var showList = false

    var body: some View {
        if let report, !report.findings.isEmpty {
            HStack(spacing: 6) {
                Button { showList.toggle() } label: {
                    Label(summary(report.findings), systemImage: "arrow.triangle.branch")
                        .font(.caption)
                        .foregroundStyle(report.findings.contains(where: \.isConflict) ? .orange : .secondary)
                }
                .buttonStyle(.plain)
                .help("Targets whose status disagrees with their git branch or pull request")
                .popover(isPresented: $showList, arrowEdge: .bottom) { list(report).popoverSurface() }
                if let error { errorIcon(error) }
                Spacer()
            }
        } else if let error {
            status("Drift check failed", help: error, isError: true)
        } else if let report, report.isPartial {
            status(report.incomplete ? "Drift check incomplete" : "Drift check skipped",
                   help: report.notes.joined(separator: "\n"), isError: false)
        }
    }

    private func summary(_ findings: [WorkbenchDriftFinding]) -> String {
        let conflicts = findings.filter(\.isConflict).count
        let advisory = findings.count - conflicts
        if conflicts == 0 { return "Board drift: \(advisory) to review" }
        if advisory == 0 { return "Board drift: \(conflicts) out of step with git" }
        return "Board drift: \(conflicts) out of step with git, \(advisory) to review"
    }

    private func status(_ text: String, help: String, isError: Bool) -> some View {
        HStack(spacing: 6) {
            if isError { errorIcon(help) }
            Text(text).font(.caption).foregroundStyle(.secondary).help(help)
            refreshButton
            Spacer()
        }
    }

    private var refreshButton: some View {
        Button(action: onRefresh) { Image(systemName: "arrow.clockwise") }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.caption)
            .help("Check the board against git again")
    }

    private func errorIcon(_ error: String) -> some View {
        Image(systemName: "exclamationmark.triangle")
            .foregroundStyle(.red)
            .font(.caption)
            .help(error)
    }

    private func list(_ report: WorkbenchDriftReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Board drift").font(.headline)
                if !report.base.isEmpty {
                    Text("against \(report.base)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh", action: onRefresh).controlSize(.small)
                fixButton(nil)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(report.findings) { finding in
                        DriftFindingRow(
                            finding: finding,
                            fixing: liveFix(Int64(finding.targetID)),
                            onSelect: { showList = false; onSelect(finding.targetID) },
                            onFix: { onFix(Int64(finding.targetID)) }
                        )
                    }
                }
            }
            .frame(maxHeight: 320)
            ForEach(report.notes, id: \.self) { note in
                Text(note).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 440)
    }

    private func fixButton(_ targetID: Int64?) -> some View {
        let fixing = liveFix(targetID)
        return Button(fixing ? "Fixing…" : "Fix") { onFix(targetID) }
            .controlSize(.small)
            .help(fixing ? "Open the session fixing the board" : "Start an agent session that fixes the board")
    }
}

/// One finding: the row selects its target; a hover Fix starts a session for it.
private struct DriftFindingRow: View {
    let finding: WorkbenchDriftFinding
    let fixing: Bool
    let onSelect: () -> Void
    let onFix: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.compact) {
            Button(action: onSelect) { content }.buttonStyle(.plain)
            // A running fix stays visible; otherwise Fix shows on hover.
            Button(fixing ? "Fixing…" : "Fix", action: onFix)
                .controlSize(.small)
                .opacity(hovering || fixing ? 1 : 0)
                .help(fixing ? "Open the session fixing this" : "Start an agent session that fixes this finding")
        }
        .onHover { hovering = $0 }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(finding.kindLabel)
                    .font(.caption.bold())
                    .foregroundStyle(finding.isConflict ? .orange : .secondary)
                Text("#\(finding.targetID) \(finding.title)").font(.callout).lineLimit(1)
            }
            Text(finding.detail).font(.caption).foregroundStyle(.secondary)
            Text(finding.fix).font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
