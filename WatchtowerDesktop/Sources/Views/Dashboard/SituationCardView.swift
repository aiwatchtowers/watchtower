import SwiftUI
import AppKit

// MARK: - SituationCardView

/// Row for a single `Situation` in the Dashboard feed — same flat-row visual
/// language as `InboxCardView`/`TrackRow`: compact header + one-line summary when
/// collapsed, secretary card + expandable member-signal originals + action row
/// when expanded.
struct SituationCardView: View {
    let situation: Situation
    var isExpanded: Bool = false
    var memberSignals: [InboxItem] = []
    var memberSignalsLoaded: Bool = false
    var senderName: (InboxItem) -> String = { _ in "" }
    var channelName: (InboxItem) -> String = { _ in "" }
    let onToggle: () -> Void
    let onDone: () -> Void
    let onDismiss: () -> Void
    let onSnooze: (SnoozeOption) -> Void
    let onFeedback: (Int) -> Void
    /// Disables the Target button while its async prefill is being built, to
    /// avoid a double-tap racing two `CreateTargetSheet` presentations.
    var isCreatingTarget: Bool = false
    let onCreateTarget: () -> Void
    let onCreateTrack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerLine
            bodyLine
            if isExpanded {
                expandedContent
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .contextMenu { contextMenuContent }
    }

    // MARK: - Line 1: header (kind badge + priority + title + updated + chevron)

    private var headerLine: some View {
        HStack(alignment: .center, spacing: 6) {
            kindBadge
            priorityIcon
            Text(situation.title)
                .font(.subheadline)
                .fontWeight(.medium)
                .lineLimit(1)
            Spacer()
            if let updatedAt = situation.updatedAt {
                Text(updatedAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
        }
    }

    // MARK: - Line 2: one-line why-it-matters, falling back to the AI reason

    private var bodyLine: some View {
        Text(fallbackSummaryText)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(isExpanded ? nil : 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var fallbackSummaryText: String {
        situation.whyMatters.isEmpty ? situation.aiReason : situation.whyMatters
    }

    // MARK: - Expanded content: secretary card / placeholder, member signals, actions

    @ViewBuilder
    private var expandedContent: some View {
        secretaryCardOrPlaceholder
        memberSignalsSection
        actionRow
    }

    @ViewBuilder
    private var secretaryCardOrPlaceholder: some View {
        if situation.hasCard {
            cardSection
        } else if situation.cardStatus == .failed {
            Text("Context unavailable — will retry")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Preparing context…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    private var cardSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !situation.whyMatters.isEmpty {
                cardParagraph(title: "Why it matters", text: situation.whyMatters)
            }
            if !situation.summary.isEmpty {
                cardParagraph(title: "Summary", text: situation.summary)
            }
            if !situation.chronology.isEmpty {
                cardParagraph(title: "Chronology", text: situation.chronology)
            }
        }
        .padding(.top, 2)
    }

    private func cardParagraph(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Member-signal originals (reuses InboxCardView.conversationSection's shape)

    @ViewBuilder
    private var memberSignalsSection: some View {
        Divider().padding(.vertical, 2)
        if !memberSignalsLoaded {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading signals…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        } else if memberSignals.isEmpty {
            Text("No member signals recorded.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(memberSignals) { item in
                    memberSignalBubble(item)
                }
            }
            .padding(.top, 4)
        }
    }

    private func memberSignalBubble(_ item: InboxItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(senderName(item)) · \(channelName(item))")
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            Text(item.snippet)
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Action row (Done / Dismiss / Snooze / Create target / Create track / feedback)

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button("Done", action: onDone)
                .buttonStyle(.bordered)
            Button("Dismiss", role: .destructive, action: onDismiss)
                .buttonStyle(.bordered)
            Menu {
                snoozeMenuItems
            } label: {
                Label("Snooze", systemImage: "moon.zzz")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Button(action: onCreateTarget) {
                Label("Target", systemImage: "checkmark.circle")
            }
            .buttonStyle(.bordered)
            .disabled(isCreatingTarget)
            Button(action: onCreateTrack) {
                Label("Track", systemImage: "binoculars")
            }
            .buttonStyle(.bordered)
            Spacer()
            feedbackButtons
        }
        .padding(.top, 4)
    }

    private var feedbackButtons: some View {
        HStack(spacing: 8) {
            Button { onFeedback(1) } label: {
                Image(systemName: "hand.thumbsup")
            }
            .buttonStyle(.plain)

            Button { onFeedback(-1) } label: {
                Image(systemName: "hand.thumbsdown")
            }
            .buttonStyle(.plain)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: - Kind Badge

    private var kindBadge: some View {
        let info = kindBadgeInfo
        return Text(info.label)
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(info.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(info.color.opacity(0.12), in: Capsule())
    }

    private var kindBadgeInfo: (label: String, color: Color) {
        switch situation.kind {
        case .external:      return ("Signal", .secondary)
        case .targetUpdate:  return ("Target", .blue)
        case .trackUpdate:   return ("Track", .purple)
        case .mixed:         return ("Mixed", .orange)
        }
    }

    @ViewBuilder
    private var priorityIcon: some View {
        switch situation.priority {
        case "high":
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.caption)
        case "medium":
            Image(systemName: "minus.circle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
        default:
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.blue)
                .font(.caption)
        }
    }

    // MARK: - Context Menu (quick actions without expanding)

    @ViewBuilder
    private var contextMenuContent: some View {
        Menu {
            snoozeMenuItems
        } label: {
            Label("Snooze", systemImage: "moon.zzz")
        }
        Button(action: onDone) {
            Label("Done", systemImage: "checkmark.circle")
        }
        Divider()
        Button(role: .destructive, action: onDismiss) {
            Label("Dismiss", systemImage: "archivebox")
        }
    }

    @ViewBuilder
    private var snoozeMenuItems: some View {
        Button("1 hour") { onSnooze(.oneHour) }
        Button("Till tomorrow") { onSnooze(.tillTomorrow) }
        Button("Till Monday") { onSnooze(.tillMonday) }
    }
}
