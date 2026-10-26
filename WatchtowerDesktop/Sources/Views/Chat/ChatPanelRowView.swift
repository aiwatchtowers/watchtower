import SwiftUI
import WatchtowerCore

/// One chat in the Chats panel (spec 2026-10-26 §5.1), the sessions
/// panel's row shape: a 16 pt state dot column, then the title (semibold
/// while unread) and the second line (waiting, answering, or the last
/// answer and its age). The panel adds the tab, the click and the menu;
/// `accessory` is the trailing slot (the hover ✕).
struct ChatPanelRowView<Accessory: View>: View {
    let row: ChatPanelRow
    let state: ChatPanelRowState
    /// The second line (`ChatPanelRowState.secondLine`).
    let secondLine: ChatPanelSecondLine
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
            ChatStateDot(state: state)
                .frame(width: 16)
                // A waiting or answering second line reads the state out.
                .accessibilityHidden(state.secondLineNamesState)
            VStack(alignment: .leading, spacing: 0) {
                Text(row.conversation.displayTitle)
                    .fontWeight(row.isUnread ? .semibold : .regular)
                    .lineLimit(1)
                    .truncationMode(.tail)
                // A long preview is cut; its age after it never is.
                HStack(spacing: Spacing.small) {
                    if !secondLine.text.isEmpty {
                        Text(secondLine.text)
                            .font(.caption2)
                            .foregroundStyle(state.secondLineStyle)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    if let age = secondLine.ageLabel {
                        Text(age)
                            .font(.caption2)
                            .foregroundStyle(state.secondLineStyle)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
            }
            Spacer(minLength: 0)
            accessory()
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

extension ChatPanelRowView where Accessory == EmptyView {
    init(row: ChatPanelRow, state: ChatPanelRowState, secondLine: ChatPanelSecondLine) {
        self.init(row: row, state: state, secondLine: secondLine) { EmptyView() }
    }
}

/// A chat's state dot (spec §5.2): waiting for approval orange, answering
/// accent and pulsing (still under Reduce Motion), unread accent, read a
/// grey ring. Its accessibility label names the state.
struct ChatStateDot: View {
    let state: ChatPanelRowState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: state == .read ? "circle" : "circle.fill")
            .font(.system(size: IconSize.stateDot))
            .foregroundStyle(state.dotStyle)
            .symbolEffect(.pulse, isActive: state == .answering && !reduceMotion)
            .accessibilityLabel(state.accessibilityLabel)
    }
}

extension ChatPanelRowState {
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

    /// Line 2 says the state ("Waiting for approval: …", "Answering…"), so
    /// VoiceOver need not hear the dot too.
    var secondLineNamesState: Bool {
        self == .waitingForApproval || self == .answering
    }
}
