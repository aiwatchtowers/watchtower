import SwiftUI
import WatchtowerCore

// The pieces the Context, Skills and Trouble blocks share.

/// What a Context, Skills or Trouble block shows.
enum AgentAnalyticsBlockState: Equatable {
    /// No session of the period has the facts the block reads.
    case notMeasured
    /// Measured, and nothing to show.
    case nothingFound
    case measured

    static let notMeasuredLine = "Not measured yet for older sessions — they fill in after the next history scan."

    static func make(factsSessions: Int?, hasFindings: Bool) -> Self {
        guard (factsSessions ?? 0) > 0 else { return .notMeasured }
        return hasFindings ? .measured : .nothingFound
    }
}

/// A titled v2 block: its content once measured, else one line saying why
/// there is none; `footer` shows in every state (facts that need no new
/// sessions).
struct AgentAnalyticsBlock<Content: View, Footer: View>: View {
    let title: String
    let state: AgentAnalyticsBlockState
    let content: Content
    let footer: Footer

    init(
        title: String,
        state: AgentAnalyticsBlockState,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.title = title
        self.state = state
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        AgentAnalyticsSection(title: title) {
            switch state {
            case .notMeasured:
                Text(AgentAnalyticsBlockState.notMeasuredLine).font(.callout).foregroundStyle(.secondary)
            case .nothingFound:
                Text("Nothing to fix here").font(.callout).foregroundStyle(.secondary)
            case .measured:
                content
            }
            footer
        }
    }
}

extension AgentAnalyticsBlock where Footer == EmptyView {
    init(title: String, state: AgentAnalyticsBlockState, @ViewBuilder content: () -> Content) {
        self.init(title: title, state: state, content: content) { EmptyView() }
    }
}

/// A session's short id as a link to its analytics.
struct AgentSessionLink: View {
    let uuid: String
    let actions: AgentAnalyticsActions

    var body: some View {
        Button(String(uuid.prefix(8))) { actions.openSession(uuid) }
            .buttonStyle(.link)
            .font(.callout.monospaced())
            .help("Show this session's analytics")
            .accessibilityLabel("Session \(uuid.prefix(8))")
    }
}

/// A stacked bar of shares with a legend line per part ("skills 900 · 10%").
struct AgentShareBar: View {
    let parts: [(label: String, tokens: Int64, share: Double)]

    private static let palette: [Color] = [.blue, .purple, .teal, .mint, .pink, .green, .indigo, .gray]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { proxy in
                HStack(spacing: 1) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                        Rectangle()
                            .fill(Self.color(index))
                            .frame(width: max(proxy.size.width * min(max(part.share, 0), 1) - 1, 0))
                    }
                }
            }
            .frame(height: 10)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .accessibilityHidden(true)
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                    HStack(spacing: 4) {
                        Circle().fill(Self.color(index)).frame(width: 8, height: 8).accessibilityHidden(true)
                        Text("\(part.label) \(AgentAnalyticsFormat.tokens(part.tokens)) · "
                            + AgentAnalyticsFormat.percent(part.share, of: 1))
                    }
                }
            }
            .font(.callout.monospacedDigit())
        }
    }

    private static func color(_ index: Int) -> Color { palette[index % palette.count] }
}
