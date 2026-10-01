import SwiftUI
import WatchtowerCore

/// One compact line above the board when targets disagree with git
/// (PROJ-07): "Board drift: N" opens the list; a finding selects its
/// target. Nothing is shown while the board and git agree.
struct ProjectDriftBanner: View {
    let report: ProjectDriftReport?
    let error: String?
    let onSelect: (Int) -> Void
    let onRefresh: () -> Void

    @State private var showList = false

    var body: some View {
        if let findings = report?.findings, !findings.isEmpty {
            HStack(spacing: 6) {
                Button { showList.toggle() } label: {
                    Label(summary(findings), systemImage: "arrow.triangle.branch")
                        .font(.caption)
                        .foregroundStyle(findings.contains(where: \.isConflict) ? .orange : .secondary)
                }
                .buttonStyle(.plain)
                .help("Targets whose status disagrees with their git branch or pull request")
                .popover(isPresented: $showList, arrowEdge: .bottom) { list(findings) }
                if let error { errorIcon(error) }
                Spacer()
            }
        } else if let error {
            HStack(spacing: 6) {
                errorIcon(error)
                Text("Drift check failed").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private func summary(_ findings: [ProjectDriftFinding]) -> String {
        let conflicts = findings.filter(\.isConflict).count
        if conflicts == 0 { return "Board drift: \(findings.count) to review" }
        return "Board drift: \(conflicts) out of step with git" + (conflicts < findings.count ? ", \(findings.count - conflicts) to review" : "")
    }

    private func errorIcon(_ error: String) -> some View {
        Image(systemName: "exclamationmark.triangle")
            .foregroundStyle(.red)
            .font(.caption)
            .help(error)
    }

    private func list(_ findings: [ProjectDriftFinding]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Board drift").font(.headline)
                if let base = report?.base, !base.isEmpty {
                    Text("against \(base)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh", action: onRefresh).controlSize(.small)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(findings) { finding in
                        Button {
                            showList = false
                            onSelect(finding.targetID)
                        } label: { row(finding) }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 320)
            ForEach(report?.notes ?? [], id: \.self) { note in
                Text(note).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 420)
    }

    private func row(_ finding: ProjectDriftFinding) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(finding.kindLabel)
                    .font(.caption.bold())
                    .foregroundStyle(finding.isConflict ? .orange : .secondary)
                Text("#\(finding.targetID) \(finding.title)").font(.callout).lineLimit(1)
            }
            Text(finding.detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
