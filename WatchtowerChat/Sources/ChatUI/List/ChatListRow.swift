import ChatWire
import SwiftUI
import WatchtowerDesign

/// One list row's words (pure): the title, the line under it by state, the dot, the project and the age.
public struct ChatListRowContent: Equatable {
    public static let waitingLine = "Waiting for your approval"
    public static let answeringLine = "Answering…"
    public static let unreadLine = "New answer"
    public static let untitled = "New chat"

    public enum Dot: Equatable {
        case waiting, answering, unread, none
    }

    public let id: Int64
    public let title: String
    /// The chat has a title of its own (`title` is otherwise `untitled`).
    public let hasTitle: Bool
    public let detail: String
    public let dot: Dot
    /// The project's name while the line is not a state; an app that lists one project's chats clears it.
    public var project: String?
    /// The last answer's first line, whatever the state ("" before any answer).
    public let lastLine: String
    /// `ChatAge`'s label; an app with its own age words sets it.
    public var age: String
    public let pinned: Bool
    /// The tool of the oldest pending approval while the chat waits (nil from an older engine).
    public let pendingTool: String?
    /// A complete answer the owner has not seen, whatever the dot shows first.
    public let unread: Bool

    public init(_ conversation: ChatList.Conversation, now: Date, calendar: Calendar = .current) {
        id = conversation.id
        hasTitle = !conversation.title.isEmpty
        title = hasTitle ? conversation.title : Self.untitled
        lastLine = conversation.lastLine
        pinned = conversation.pinned
        pendingTool = conversation.pendingTool
        unread = conversation.unread
        switch conversation.state {
        case .waiting: (detail, dot) = (Self.waitingLine, .waiting)
        case .answering: (detail, dot) = (Self.answeringLine, .answering)
        case .unread: (detail, dot) = (Self.unreadLine, .unread)
        default: (detail, dot) = (conversation.lastLine, .none)
        }
        project = dot == .waiting || dot == .answering ? nil : conversation.project?.name
        age = ChatAge.label(conversation.updatedAt, now: now, calendar: calendar)
    }
}

/// "now", "5m", "3h", a weekday, "Mar 4", "Mar 4, 2025".
public enum ChatAge {
    public static func label(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3_600 { return "\(Int(seconds) / 60)m" }
        if seconds < 86_400 { return "\(Int(seconds) / 3_600)h" }
        var format = Date.FormatStyle(calendar: calendar).locale(Locale(identifier: "en_US_POSIX"))
        format.timeZone = calendar.timeZone
        if seconds < 6 * 86_400 { return date.formatted(format.weekday(.abbreviated)) }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(format.month(.abbreviated).day())
        }
        return date.formatted(format.month(.abbreviated).day().year())
    }
}

/// A conversation in the list: the app's own row when its style draws one (`ChatUIStyle.listRow`, the Mac's Chats
/// panel), else ChatUI's.
public struct ChatListRow: View {
    let content: ChatListRowContent
    @Environment(\.chatUIStyle) private var style

    public init(content: ChatListRowContent) {
        self.content = content
    }

    public var body: some View {
        Group {
            if let row = style.listRow(content) {
                row
            } else {
                standardRow
            }
        }
        .accessibilityIdentifier("chat.list.row.\(content.id)")
    }

    private var standardRow: some View {
        HStack(alignment: .top, spacing: Spacing.regular) {
            dot.frame(width: IconSize.stateDot, height: IconSize.stateDot).padding(.top, Spacing.compact)
            VStack(alignment: .leading, spacing: Spacing.tight) {
                HStack(spacing: Spacing.small) {
                    if content.pinned {
                        Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(content.title).font(.callout.weight(.medium)).lineLimit(1)
                    Spacer(minLength: Spacing.small)
                    Text(content.age).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                HStack(spacing: Spacing.small) {
                    if let project = content.project {
                        Text(project).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Text("·").font(.caption).foregroundStyle(.tertiary)
                    }
                    Text(content.detail)
                        .font(.caption)
                        .foregroundStyle(content.dot == .waiting ? Tone.warning : Color.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, Spacing.small)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var dot: some View {
        switch content.dot {
        case .waiting: Circle().fill(Tone.warning)
        case .answering: Circle().fill(Tone.status("blue"))
        case .unread: Circle().fill(Color.accentColor)
        case .none: Circle().strokeBorder(Stroke.hairlineColor, lineWidth: Stroke.selection)
        }
    }
}
