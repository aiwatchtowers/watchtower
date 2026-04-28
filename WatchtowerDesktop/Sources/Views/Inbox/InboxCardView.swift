import SwiftUI
import AppKit

// MARK: - CardSize

enum CardSize {
    case compact
    case medium
    case pinned
}

// MARK: - InboxCardView

/// Flat row in the same visual language as `TrackRow` / digest list rows:
/// - 3 stacked lines (header / body / metadata), no surrounding card stroke
/// - background tinted by read/unread state, selection handled by the parent list
/// - destructive actions live in the context menu; feedback is inline like in Tracks
struct InboxCardView: View {
    let item: InboxItem
    let size: CardSize
    var senderName: String? = nil
    var userNames: [String: String] = [:]
    var channelName: String? = nil
    var isExpanded: Bool = false
    var conversation: [InboxConversationMessage] = []
    var conversationLoaded: Bool = false
    var slackURL: URL? = nil
    let onToggle: () -> Void
    let onSnooze: (SnoozeOption) -> Void
    let onDismiss: () -> Void
    let onCreateTask: () -> Void
    let onMarkRead: () -> Void
    let onFeedback: (Int, String) -> Void

    // MARK: - Snooze Options

    enum SnoozeOption {
        case oneHour
        case tillTomorrow
        case tillMonday
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerLine
            bodyLine
            if size != .compact {
                metadataLine
            }
            if size == .pinned, !item.aiReason.isEmpty {
                aiReasonBlock
            }
            if isExpanded {
                conversationSection
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .contextMenu { contextMenuContent }
    }

    // MARK: - Line 1: header (icon + type capsule + channel + time + chevron)

    private var headerLine: some View {
        HStack(alignment: .center, spacing: 6) {
            if size == .pinned { priorityIcon }
            triggerCapsule
            channelOrDMBadge
            Spacer()
            Text(item.messageDate, style: .relative)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if size != .compact {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
            }
        }
    }

    // MARK: - Line 2: snippet

    private var bodyLine: some View {
        Text(snippetAttributed)
            .font(.subheadline)
            .fontWeight(item.isUnread ? .medium : .regular)
            .foregroundStyle(item.isUnread ? .primary : .secondary)
            .lineLimit(isExpanded ? nil : (size == .compact ? 1 : 2))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Line 3: metadata (sender + AI reason hint + feedback)

    private var metadataLine: some View {
        HStack(spacing: 10) {
            Label(senderDisplay, systemImage: "person.fill")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            if size == .medium, !item.aiReason.isEmpty {
                Image(systemName: "sparkles")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
                Text(SlackTextParser.toAttributedString(item.aiReason, userNames: userNames))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            if item.hasLinkedTarget {
                Label("Task", systemImage: "checkmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.green)
            }

            Spacer()

            feedbackButtons
        }
    }

    // MARK: - Pinned AI reason block (full)

    private var aiReasonBlock: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "sparkles")
                .foregroundStyle(.yellow)
                .font(.caption)
            Text(SlackTextParser.toAttributedString(item.aiReason, userNames: userNames))
                .font(.caption)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Trigger Capsule (replaces the bare colour-coded icon with a Tracks-style chip)

    private var triggerCapsule: some View {
        HStack(spacing: 4) {
            Image(systemName: triggerSymbol)
                .font(.caption2)
            Text(triggerLabel)
                .font(.caption2)
                .fontWeight(.semibold)
        }
        .foregroundStyle(triggerColor)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(triggerColor.opacity(0.12), in: Capsule())
    }

    private var triggerLabel: String {
        switch item.triggerType {
        case "mention":               return "Mention"
        case "dm":                    return "DM"
        case "thread_reply":          return "Thread"
        case "reaction":              return "Reaction"
        case "jira_assigned":         return "Jira"
        case "jira_comment_mention":  return "Jira"
        case "calendar_invite":       return "Invite"
        case "calendar_time_change":  return "Reschedule"
        case "calendar_cancelled":    return "Cancelled"
        case "decision_made":         return "Decision"
        case "briefing_ready":        return "Briefing"
        default:                      return item.triggerType.capitalized
        }
    }

    private var triggerSymbol: String {
        switch item.triggerType {
        case "mention":               return "at"
        case "dm":                    return "envelope"
        case "thread_reply":          return "bubble.left.and.bubble.right"
        case "reaction":              return "eye"
        case "jira_assigned":         return "ticket"
        case "jira_comment_mention":  return "bubble.left"
        case "calendar_invite":       return "calendar.badge.plus"
        case "calendar_time_change":  return "clock.arrow.circlepath"
        case "calendar_cancelled":    return "calendar.badge.minus"
        case "decision_made":         return "paperplane"
        case "briefing_ready":        return "sun.max"
        default:                      return "circle"
        }
    }

    private var triggerColor: Color {
        switch item.triggerType {
        case "mention":              return .blue
        case "dm":                   return .green
        case "thread_reply":         return .purple
        case "reaction":             return .yellow
        case "jira_assigned",
             "jira_comment_mention": return .orange
        case "calendar_invite",
             "calendar_time_change",
             "calendar_cancelled":   return .teal
        case "decision_made":        return .indigo
        case "briefing_ready":       return .yellow
        default:                     return .secondary
        }
    }

    @ViewBuilder
    private var channelOrDMBadge: some View {
        if item.isDM {
            EmptyView()
        } else if let name = channelName, !name.isEmpty {
            Text("#\(name)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var priorityIcon: some View {
        switch item.priority {
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

    private var senderDisplay: String {
        if let name = senderName, !name.isEmpty { return name }
        if let resolved = userNames[item.senderUserID], !resolved.isEmpty { return resolved }
        return item.senderUserID.isEmpty ? "Unknown" : item.senderUserID
    }

    private var snippetAttributed: AttributedString {
        SlackTextParser.toAttributedString(item.snippet, userNames: userNames)
    }

    // MARK: - Inline conversation (unchanged behaviour)

    @ViewBuilder
    private var conversationSection: some View {
        Divider().padding(.vertical, 2)
        if !conversationLoaded {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading conversation…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        } else if conversation.isEmpty {
            Text("No conversation messages found locally yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(conversation.enumerated()), id: \.element.id) { idx, msg in
                    let prevAuthor = idx > 0 ? conversation[idx - 1].author : nil
                    chatBubble(msg, showAuthor: prevAuthor != msg.author)
                }
            }
            .padding(.top, 4)
        }
    }

    private func chatBubble(_ msg: InboxConversationMessage, showAuthor: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if showAuthor {
                Text(msg.author)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            }
            Text(msg.text)
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    msg.isTrigger
                        ? Color.accentColor.opacity(0.15)
                        : Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 12)
                )
                .overlay(
                    msg.isTrigger
                        ? RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.accentColor.opacity(0.3), lineWidth: 1)
                        : nil
                )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Feedback (inline thumbs, like Tracks/Digests)

    private var feedbackButtons: some View {
        HStack(spacing: 2) {
            Button {
                onFeedback(1, "")
            } label: {
                Image(systemName: "hand.thumbsup")
            }
            .buttonStyle(.plain)

            Button {
                onFeedback(-1, "")
            } label: {
                Image(systemName: "hand.thumbsdown")
            }
            .buttonStyle(.plain)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: - Context Menu (replaces the bordered action bar)

    @ViewBuilder
    private var contextMenuContent: some View {
        if item.isUnread {
            Button {
                onMarkRead()
            } label: {
                Label("Mark as Read", systemImage: "envelope.open")
            }
        }
        if let url = slackURL {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Label("Open in Slack", systemImage: "arrow.up.right.square")
            }
        }
        if item.itemClass == .actionable {
            Menu {
                Button("1 hour")        { onSnooze(.oneHour) }
                Button("Till tomorrow") { onSnooze(.tillTomorrow) }
                Button("Till Monday")   { onSnooze(.tillMonday) }
            } label: {
                Label("Snooze", systemImage: "moon.zzz")
            }
            if !item.hasLinkedTarget {
                Button {
                    onCreateTask()
                } label: {
                    Label("Create Task", systemImage: "checkmark.circle")
                }
            }
            Divider()
            Button(role: .destructive) {
                onDismiss()
            } label: {
                Label("Dismiss", systemImage: "archivebox")
            }
        }
    }
}
