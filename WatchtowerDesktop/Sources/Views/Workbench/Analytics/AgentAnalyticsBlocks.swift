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

/// A titled v2 block as a soft card: its one-sentence lead and content once
/// measured, else one line saying why there is none; `footer` shows in every
/// state (facts that need no new sessions).
struct AgentAnalyticsBlock<Content: View, Footer: View>: View {
    let title: String
    let lead: String?
    let state: AgentAnalyticsBlockState
    let content: Content
    let footer: Footer

    init(
        title: String,
        lead: String? = nil,
        state: AgentAnalyticsBlockState,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.title = title
        self.lead = lead
        self.state = state
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            switch state {
            case .notMeasured:
                Text(AgentAnalyticsBlockState.notMeasuredLine).font(.callout).foregroundStyle(.secondary)
            case .nothingFound:
                Text("Nothing to fix here").font(.callout).foregroundStyle(.secondary)
            case .measured:
                if let lead, !lead.isEmpty {
                    Text(lead).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                content
            }
            footer
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

extension AgentAnalyticsBlock where Footer == EmptyView {
    init(title: String, lead: String? = nil, state: AgentAnalyticsBlockState, @ViewBuilder content: () -> Content) {
        self.init(title: title, lead: lead, state: state, content: content) { EmptyView() }
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

/// A baseline part ready to draw: name, key (for its colour), tokens, share.
struct AgentBaselinePart: Equatable {
    let key: String
    let label: String
    let tokens: Int64
    let share: Double

    /// The five largest parts and, when there are more, one grey "N more"
    /// that adds up the rest.
    static func fold(_ parts: [AgentPartShare], keep: Int = 5) -> [Self] {
        let sorted = parts.sorted { $0.tokens > $1.tokens }
        let (shown, rest) = AgentAnalyticsFormat.fold(sorted, keep: keep)
        var rows = shown.map {
            Self(key: $0.part, label: AgentAnalyticsFormat.label(part: $0.part), tokens: $0.tokens, share: $0.share)
        }
        if !rest.isEmpty {
            rows.append(Self(
                key: "", label: "\(rest.count) more", tokens: rest.reduce(0) { $0 + $1.tokens },
                share: rest.reduce(0) { $0 + $1.share }
            ))
        }
        return rows
    }
}

/// The session-start baseline: one stacked bar and a two-column legend.
struct AgentBaselineBar: View {
    let parts: [AgentBaselinePart]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            GeometryReader { proxy in
                HStack(spacing: Stroke.hairline) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                        Rectangle()
                            .fill(AgentAnalyticsPalette.color(forPart: part.key))
                            .frame(width: max(proxy.size.width * min(max(part.share, 0), 1) - Stroke.hairline, 0))
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 10)
            .clipShape(RoundedRectangle(cornerRadius: Radius.mark))
            .accessibilityHidden(true)
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: Spacing.wide), GridItem(.flexible())],
                alignment: .leading, spacing: Spacing.small
            ) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    HStack(spacing: Spacing.small) {
                        Circle()
                            .fill(AgentAnalyticsPalette.color(forPart: part.key))
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                        Text(part.label).lineLimit(1)
                        Spacer(minLength: Spacing.regular)
                        Text("\(AgentAnalyticsFormat.tokens(part.tokens)) · \(AgentAnalyticsFormat.share(part.share))")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            .font(.callout)
        }
    }
}

/// One growth source as a bar row: name, a soft accent bar scaled to the
/// largest source, its size and share.
struct AgentGrowthRowView: View {
    let name: String
    let tokens: Int64
    let share: Double
    let largest: Int64

    var body: some View {
        HStack(spacing: Spacing.cozy) {
            Text(name).lineLimit(1).frame(width: 190, alignment: .leading)
            GeometryReader { proxy in
                let fraction = largest > 0 ? min(Double(tokens) / Double(largest), 1) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(Fill.hover)
                    Capsule().fill(Color.accentColor)
                        .frame(width: max(proxy.size.width * fraction, tokens > 0 ? 3 : 0))
                        .opacity(0.8)
                }
            }
            .frame(height: 6)
            .accessibilityHidden(true)
            Text(AgentAnalyticsFormat.tokens(tokens)).foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
            Text(AgentAnalyticsFormat.share(share)).frame(width: 40, alignment: .trailing)
        }
        .font(.callout.monospacedDigit())
        .accessibilityElement(children: .combine)
    }
}
