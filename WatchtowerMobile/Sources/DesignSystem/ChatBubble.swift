import SwiftUI

/// One line of a session's chat, the Desktop's `SessionChatRow` at phone
/// size (mockups 3, 4, 8): the owner's lines right on the accent fill
/// (`Fill.selected`, `Radius.bubble`), the agent's text left with no
/// bubble, Watchtower's lines as centred captions, a subagent as a quiet
/// `Fill.rest` line that opens its chat. `caption` goes under an owner line
/// ("Queued · the agent reads it at its next step", "Waiting for your
/// Mac"); `isPending` dims a line not yet taken. Text renders inline
/// markdown (`code`, **bold**, links).
///
///     ChatBubble(role: .owner, text: line.text, caption: "Queued · …", isPending: true)
///     ChatBubble(role: .subagent, text: "Explore · finished", onTap: { open() })
struct ChatBubble: View {
    enum Role: Equatable {
        case owner, agent, watchtower, subagent
    }

    let role: Role
    let text: String
    var caption: String?
    var isPending = false
    var onTap: (() -> Void)?

    static func fill(_ role: Role) -> Color? {
        switch role {
        case .owner: Fill.selected
        case .subagent: Fill.rest
        case .agent, .watchtower: nil
        }
    }

    static func alignment(_ role: Role) -> HorizontalAlignment {
        switch role {
        case .owner: .trailing
        case .watchtower: .center
        case .agent, .subagent: .leading
        }
    }

    var body: some View {
        VStack(alignment: Self.alignment(role), spacing: Spacing.small) {
            line
            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: Self.alignment(role), vertical: .center))
        .opacity(isPending ? 0.75 : 1)
    }

    @ViewBuilder private var line: some View {
        switch role {
        case .owner:
            Text(Self.markdown(text))
                .font(TypeScale.rowTitle)
                .textSelection(.enabled)
                .padding(.horizontal, Spacing.medium)
                .padding(.vertical, Spacing.regular)
                .background(Fill.selected, in: RoundedRectangle(cornerRadius: Radius.bubble, style: .continuous))
                .padding(.leading, Spacing.hero)
        case .agent:
            Text(Self.markdown(text))
                .font(TypeScale.rowTitle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .watchtower:
            Text(Self.markdown(text))
                .font(TypeScale.meta)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        case .subagent:
            Button {
                onTap?()
            } label: {
                HStack(spacing: Spacing.regular) {
                    Image(systemName: "person.2")
                    Text(text).lineLimit(2)
                    Spacer(minLength: Spacing.small)
                    if onTap != nil {
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Spacing.cozy)
                .frame(minHeight: PhoneMetrics.minTouch)
                .background(Fill.rest, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(onTap == nil)
        }
    }

    /// Inline markdown only, line breaks kept; text that does not parse
    /// shows as written.
    static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
