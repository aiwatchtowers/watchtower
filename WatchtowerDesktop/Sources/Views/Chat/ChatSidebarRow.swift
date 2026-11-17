import ChatUI
import ChatWire
import SwiftUI
import WatchtowerCore

/// One chat in the Chats panel as it looked before the unified chat (spec 2026-10-26 §5.1; unified chat spec §2 "a
/// move, not a redesign", final review I5), drawn for ChatUI's list row through `DesignKitChatStyle.listRow`: a 16 pt
/// state dot column, then the title (semibold while unread) and the second line (waiting, answering, or the project,
/// the last answer and its age). The panel adds the tab, the click, the menu and the hover ✕.
struct ChatSidebarRow: View {
    static let untitled = "New Chat"
    static let waitingLine = "Waiting for approval"
    static let answeringLine = "Answering…"

    let content: ChatListRowContent

    /// The panel's words for a conversation: its age as the panel counts it ("just now", "2h", "4d"), and the
    /// project only at All chats (one project's chats are all its own).
    static func content(_ conversation: ChatList.Conversation, now: Date, showsProject: Bool) -> ChatListRowContent {
        var content = ChatListRowContent(conversation, now: now)
        content.age = TimeFormatting.shortAge(from: conversation.updatedAt, now: now)
        if !showsProject { content.project = nil }
        return content
    }

    private var state: ChatSidebarRowState { ChatSidebarRowState(content.dot) }

    /// The second line: the state's words, or the project and the last answer's first line ("" when there is
    /// neither), with the age after it.
    private var line: (text: String, age: String?) {
        switch state {
        case .waitingForApproval: (Self.waitingLine, nil)
        case .answering: (Self.answeringLine, nil)
        case .unread, .read:
            ([content.project, content.lastLine].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
             content.age)
        }
    }

    var body: some View {
        let line = line
        HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
            ChatSidebarStateDot(state: state)
                .frame(width: 16)
                // A waiting or answering second line reads the state out.
                .accessibilityHidden(state.secondLineNamesState)
            VStack(alignment: .leading, spacing: 0) {
                Text(content.hasTitle ? content.title : Self.untitled)
                    .fontWeight(state == .unread ? .semibold : .regular)
                    .lineLimit(1)
                    .truncationMode(.tail)
                // A long preview is cut; its age after it never is.
                HStack(spacing: Spacing.small) {
                    if !line.text.isEmpty {
                        Text(line.text)
                            .font(.caption2)
                            .foregroundStyle(state.secondLineStyle)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    if let age = line.age {
                        Text(line.text.isEmpty ? age : "· \(age)")
                            .font(.caption2)
                            .foregroundStyle(state.secondLineStyle)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// The panel row's state, by ChatUI's dot: waiting for approval > answering > unread > read.
enum ChatSidebarRowState: Equatable {
    case waitingForApproval, answering, unread, read

    init(_ dot: ChatListRowContent.Dot) {
        switch dot {
        case .waiting: self = .waitingForApproval
        case .answering: self = .answering
        case .unread: self = .unread
        case .none: self = .read
        }
    }

    var dotStyle: Color {
        switch self {
        case .waitingForApproval: Tone.warning
        case .answering, .unread: .accentColor
        case .read: .secondary
        }
    }

    /// Line 2 in the state's colour while it names the state.
    var secondLineStyle: Color {
        switch self {
        case .waitingForApproval: Tone.warning
        case .answering: .accentColor
        case .unread, .read: .secondary
        }
    }

    /// Line 2 says the state, so VoiceOver need not hear the dot too.
    var secondLineNamesState: Bool {
        self == .waitingForApproval || self == .answering
    }

    var accessibilityLabel: String {
        switch self {
        case .waitingForApproval: "Waiting for approval"
        case .answering: "Answering"
        case .unread: "Unread"
        case .read: "Read"
        }
    }
}

/// A chat's state dot (spec 2026-10-26 §5.2): waiting for approval orange, answering accent and pulsing (still under
/// Reduce Motion), unread accent, read a grey ring. Its accessibility label names the state.
struct ChatSidebarStateDot: View {
    let state: ChatSidebarRowState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: state == .read ? "circle" : "circle.fill")
            .font(.system(size: IconSize.stateDot))
            .foregroundStyle(state.dotStyle)
            .symbolEffect(.pulse, isActive: state == .answering && !reduceMotion)
            .accessibilityLabel(state.accessibilityLabel)
    }
}
