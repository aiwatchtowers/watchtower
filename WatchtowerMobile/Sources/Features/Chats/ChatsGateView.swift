import SwiftUI

/// The Chats tab's centred message (mockups 1b, 1e–1h): the title, the line and at most one action, from
/// `ChatsGateModel`. The action of the empty state (New chat) and of the Relay state (Switch to Relay…) is the
/// prominent one; Retry is secondary.
struct ChatsGateMessage: View {
    let model: ChatsGateModel
    let act: (ChatsGateModel.Action) -> Void

    var body: some View {
        VStack(spacing: Spacing.regular) {
            if let title = model.title {
                Text(title)
                    .font(TypeScale.screenTitle)
                    .multilineTextAlignment(.center)
            }
            if let line = model.line {
                Text(line)
                    .font(TypeScale.rowTitle)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
            if let action = model.action, let title = model.actionTitle {
                button(action, title)
                    .frame(maxWidth: PhoneMetrics.gateButton)
                    .padding(.top, Spacing.small)
            }
        }
        .padding(.horizontal, Spacing.wide)
        .padding(.vertical, Spacing.large)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func button(_ action: ChatsGateModel.Action, _ title: String) -> some View {
        let tap = { act(action) }
        switch action {
        case .retry:
            Button(title, action: tap).buttonStyle(SecondaryActionStyle())
        case .newChat:
            Button(title, action: tap).buttonStyle(ProminentActionStyle()).disabled(!model.canCreate)
        case .switchToRelay:
            Button(title, action: tap).buttonStyle(ProminentActionStyle())
        }
    }
}

/// The loading state (mockup 1c): a few grey bars where the rows will be, and the line under them.
struct ChatsLoadingView: View {
    let line: String?

    private static let widths: [CGFloat] = [0.6, 1, 0.8, 1, 0.7]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            GeometryReader { proxy in
                VStack(alignment: .leading, spacing: Spacing.medium) {
                    ForEach(Array(Self.widths.enumerated()), id: \.offset) { _, width in
                        RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                            .fill(Fill.rest)
                            .frame(width: proxy.size.width * width, height: PhoneMetrics.skeletonBar)
                    }
                }
            }
            .frame(height: CGFloat(Self.widths.count) * (PhoneMetrics.skeletonBar + Spacing.medium))
            .accessibilityHidden(true)
            if let line {
                Text(line)
                    .font(TypeScale.meta)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, Spacing.small)
        .padding(.top, Spacing.regular)
    }
}
