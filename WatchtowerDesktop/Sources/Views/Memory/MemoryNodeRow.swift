import SwiftUI
import WatchtowerCore

/// One node in the browser list: title, type chip, status/dispute markers.
struct MemoryNodeRow: View {
    let node: MemoryNodeListItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(node.displayTitle)
                    .font(.callout)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if node.isDisputed {
                    Image(systemName: "exclamationmark.bubble")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help("Dispute pending")
                }
                MemoryTypeChip(type: node.type)
            }
            HStack(spacing: 6) {
                if node.status != "active" {
                    Text(node.status)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if node.tier == "long" {
                    Text("long-term")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if node.isBelief {
                    MemoryConfidenceBar(confidence: node.confidence)
                        .frame(width: 60)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// One belief in the beliefs dashboard list: confidence, subject, status.
struct MemoryBeliefRowView: View {
    let belief: MemoryBeliefRow

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(belief.displayTitle)
                    .font(.callout)
                    .fontWeight(.medium)
                    .lineLimit(2)
                Spacer(minLength: 0)
                if belief.isDisputed {
                    Image(systemName: "exclamationmark.bubble")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help(belief.disputeReason ?? "Dispute pending")
                }
            }
            HStack(spacing: 8) {
                MemoryConfidenceBar(confidence: belief.confidence)
                    .frame(width: 80)
                Text(String(format: "%.0f%%", belief.confidence * 100))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                statusChip
                if !belief.subjectTitle.isEmpty {
                    Text(belief.subjectTitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusChip: some View {
        if belief.status != "active" {
            Text(belief.status)
                .font(.caption2)
                .fontWeight(.medium)
                .padding(.horizontal, 5)
                .background((belief.status == "shaken" ? Color.orange : Color.secondary).opacity(0.15))
                .foregroundStyle(belief.status == "shaken" ? .orange : .secondary)
                .clipShape(Capsule())
        }
    }
}

/// Thin confidence meter for belief rows.
struct MemoryConfidenceBar: View {
    let confidence: Double // 0..1

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule()
                    .fill(color)
                    .frame(width: max(2, geo.size.width * confidence))
            }
        }
        .frame(height: 4)
    }

    private var color: Color {
        if confidence >= 0.7 { .green } else if confidence >= 0.4 { .orange } else { .red }
    }
}
