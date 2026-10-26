import SwiftUI

/// A pending permission prompt at the end of the Workchat (mockup 4, the
/// Desktop's `WorkchatPermissionCard`): the tool, what it runs in mono on
/// the card fill, then **Allow once** and **Deny** sharing the width. A
/// prompt the phone may only deny (`allowBlockedNote`, why) has Deny only.
/// The waiting card paint; buttons are 46 pt tall.
///
///     InlinePermissionCard(toolName: prompt.toolName, summary: prompt.summary,
///                          isAnswering: model.answering, error: model.error,
///                          onAllow: { allow() }, onDeny: { deny() })
struct InlinePermissionCard: View {
    let toolName: String
    let summary: String
    var allowBlockedNote: String?
    var isAnswering = false
    var error: String?
    let onAllow: () -> Void
    let onDeny: () -> Void

    static func title(toolName: String) -> String {
        toolName.isEmpty ? "Permission request" : toolName
    }

    static func buttonTitles(allowBlocked: Bool) -> [String] {
        allowBlocked ? ["Deny"] : ["Allow once", "Deny"]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            Text(Self.title(toolName: toolName))
                .font(.footnote.weight(.semibold))
            Text(summary)
                .font(TypeScale.code)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.regular)
                .background(Fill.card, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            if let allowBlockedNote {
                Text(allowBlockedNote).font(TypeScale.meta).foregroundStyle(.secondary)
            }
            HStack(spacing: Spacing.regular) {
                if allowBlockedNote == nil {
                    Button("Allow once", action: onAllow).buttonStyle(ProminentActionStyle())
                }
                Button("Deny", action: onDeny).buttonStyle(SecondaryActionStyle())
            }
            .disabled(isAnswering)
            if let error {
                Text(error).font(TypeScale.meta).foregroundStyle(PhoneTone.red.color)
            }
        }
        .card(.waiting)
    }
}

/// One answer an inline ask offers.
struct InlineAskOption: Equatable, Identifiable {
    let id: String
    let label: String
    var isRecommended = false
}

/// An open ask at the end of the Workchat (mockup 4, the Desktop's
/// `WorkchatAskCard`): "Ask #110 · question", the title, and its options as
/// 44 pt rows (the recommended one on `Fill.selected` under an accent line,
/// marked "recommended"). An ask without quick options gets **Open**,
/// which opens the full ask.
///
///     InlineAskCard(askID: ask.id, kind: "question", title: ask.title, options: options,
///                   onPick: { answer($0) }, onOpen: { open(ask.id) })
struct InlineAskCard: View {
    let askID: Int64
    /// The ask's kind word ("question", "review", "check"); empty for none.
    let kind: String
    let title: String
    var options: [InlineAskOption] = []
    var isAnswering = false
    let onPick: (InlineAskOption) -> Void
    let onOpen: () -> Void

    static let recommendedLabel = "recommended"

    static func header(askID: Int64, kind: String) -> String {
        kind.isEmpty ? "Ask #\(askID)" : "Ask #\(askID) · \(kind)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            Text(Self.header(askID: askID, kind: kind))
                .font(TypeScale.meta)
                .foregroundStyle(.secondary)
            Text(title)
                .font(TypeScale.rowEmphasis)
                .textSelection(.enabled)
            if options.isEmpty {
                Button("Open", action: onOpen).buttonStyle(SecondaryActionStyle())
            } else {
                ForEach(options) { option in
                    optionRow(option)
                }
            }
        }
        .disabled(isAnswering)
        .card(.plain)
    }

    private func optionRow(_ option: InlineAskOption) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
        return Button {
            onPick(option)
        } label: {
            HStack(spacing: Spacing.regular) {
                Text(option.label).font(.subheadline).foregroundStyle(.primary)
                Spacer(minLength: Spacing.small)
                if option.isRecommended {
                    Text(Self.recommendedLabel).font(TypeScale.meta).foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, Spacing.cozy)
            .frame(minHeight: PhoneMetrics.minTouch)
            .background(RowPlate.fill(isSelected: option.isRecommended), in: shape)
            .overlay(shape.strokeBorder(
                option.isRecommended ? Color.accentColor : Stroke.hairlineColor,
                lineWidth: Stroke.hairline
            ))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
    }
}
