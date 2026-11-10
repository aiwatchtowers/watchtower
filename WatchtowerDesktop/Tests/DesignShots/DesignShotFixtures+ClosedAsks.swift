import AppKit
import DesignKit
import SwiftUI

/// Design-only scenes for the closed asks list (#1713 spec,
/// `docs/superpowers/specs/2026-11-10-closed-asks-list-design.md`). Nothing
/// here is wired into the app: the copy below is the spec's string table,
/// which the implementation moves into `WatchtowerCore`
/// (`ClosedAskListCopy`) with a test. Sample data only (no live install).
@MainActor
enum ClosedAsksShotFixtures {
    enum Frame: String, CaseIterable {
        case big, search, noMatch, narrow, empty, loading, error, busy, staleError, partial, askGone, opened

        var height: CGFloat {
            switch self {
            case .big, .busy, .staleError: 720
            case .search, .opened, .partial, .askGone: 420
            default: 0
            }
        }
    }

    static var shots: [DesignShot] {
        Frame.allCases.map { frame in
            DesignShot(name: "closed-asks-\(frame.rawValue)", size: NSSize(width: 440, height: frame.height)) {
                AnyView(ClosedAsksDrawerMock(frame: frame))
            }
        } + [
            // The drawer at its least width (320): two-line titles wrap, the time stays.
            DesignShot(name: "closed-asks-big-min-width", size: NSSize(width: 320, height: 560)) {
                AnyView(ClosedAsksDrawerMock(frame: .big))
            }
        ]
    }
}

/// The spec's strings, in one place (the implementation pins them in a test).
enum ClosedAsksMockCopy {
    static let title = "Closed asks"
    static let scopeOutside = "Filed outside the app"
    static let scopeAutomations = "Automation runs"
    static let searchPlaceholder = "Search titles, answers, #number"
    static let loading = "Loading closed asks…"
    static let empty = "No closed asks here yet."
    static let emptyHint = "Asks you answer, and asks the agent withdraws, are kept here."
    static let loadFailed = "Could not load the closed asks: the database is busy."
    static let refreshFailed = "Could not refresh the list: the database is busy. It shows what was read at 14:32."
    static let unreadable = "2 asks could not be read (#212, #219)."
    static let askGone = "That ask no longer exists. The list was read again."
    static let retry = "Retry"
    static let clearSearch = "Clear Search"
    static let back = "Closed asks"
    static let busyHelp = "Refreshing…"
    static func noMatch(_ query: String) -> String { "No closed asks match “\(query)”." }
    static func matches(_ shown: Int, of total: Int) -> String { "\(shown) of \(total)" }
}

/// One row as the spec's model gives it.
struct ClosedAskMockRow: Identifiable {
    let id: Int
    let kind: String
    let title: String
    let status: Status
    let detail: String
    let time: String

    enum Status: String {
        case answered = "Answered", delivered = "Delivered", withdrawn = "Withdrawn"
        case replaced = "Replaced", dismissed = "Dismissed"

        /// `Tone.status` names: only an answer the agent has not read yet is blue.
        var tone: Color {
            switch self {
            case .answered: Tone.status("blue")
            case .delivered: Tone.status("green")
            case .withdrawn, .replaced, .dismissed: Tone.status("gray")
            }
        }
    }
}

struct ClosedAskMockSection: Identifiable {
    let title: String
    let rows: [ClosedAskMockRow]
    var id: String { title }
}

enum ClosedAsksMockData {
    private static let samples: [(String, String, ClosedAskMockRow.Status, String)] = [
        ("review", "Spec: login redirect keeps the return URL after SSO", .delivered, "Approved · 3 comments"),
        ("question", "Which session store should the redirect fix use — the cookie or the server table?",
         .delivered, "Server table; keep the cookie as a fallback"),
        ("check", "Check the login flow on staging with an expired session", .delivered, "OK 4 · Broken 1"),
        ("review", "Plan: login redirect, 6 tasks", .replaced, "replaced by #406"),
        ("question", "Rename the `acme_auth` package now or after the release?", .answered, "After the release"),
        ("review", "Spec: login redirect keeps the return URL after SSO (round 1)", .replaced, "replaced by #401"),
        ("check", "Open example.com/settings and confirm the banner is gone", .dismissed, "Not needed any more"),
        ("question", "Run the migration on the shared database now?", .withdrawn, "withdrawn by the agent"),
        ("review", "Review the changes to the session cleanup", .delivered,
         "Changes requested · 2 comments · “Keep the old flag for one release”"),
        ("question", "Should the retry use the existing backoff helper?", .delivered, "Yes"),
        ("check", "Sign in with a second account and switch between them", .delivered, "OK 3")
    ]

    private static let days = ["Today", "Yesterday", "Friday, 7 November", "Thursday, 6 November",
                               "Wednesday, 5 November", "Tuesday, 4 November", "Monday, 3 November",
                               "Friday, 31 October", "Thursday, 30 October"]

    /// 84 asks over nine days, newest first.
    static var big: [ClosedAskMockSection] { sections(total: 84) }

    static func sections(total: Int) -> [ClosedAskMockSection] {
        var out: [ClosedAskMockSection] = []
        var id = 412
        var left = total
        for (index, day) in days.enumerated() where left > 0 {
            let count = min(left, index < 2 ? 7 : 10 + index % 3)
            var rows: [ClosedAskMockRow] = []
            for slot in 0..<count {
                let sample = samples[(id * 5) % samples.count]
                let hour = 18 - slot
                rows.append(ClosedAskMockRow(
                    id: id, kind: sample.0, title: sample.1, status: sample.2, detail: sample.3,
                    time: String(format: "%02d:%02d", max(hour, 8), (id * 7) % 60)
                ))
                id -= 1
            }
            out.append(ClosedAskMockSection(title: day, rows: rows))
            left -= count
        }
        return out
    }

    /// "login" over the big list: the matches only, still grouped.
    static var search: [ClosedAskMockSection] {
        big.compactMap { section in
            let rows = section.rows.filter { $0.title.localizedCaseInsensitiveContains("login") }
            return rows.isEmpty ? nil : ClosedAskMockSection(title: section.title, rows: Array(rows.prefix(2)))
        }.prefix(2).map(\.self)
    }

    /// The automations list of a workbench with two closed automation asks.
    static let narrow: [ClosedAskMockSection] = [
        ClosedAskMockSection(title: "Yesterday", rows: [
            ClosedAskMockRow(id: 388, kind: "question", title: "Post the weekly summary to #acme-team?",
                             status: .delivered, detail: "⚙ Weekly summary · run #41 · Post it", time: "17:05")
        ]),
        ClosedAskMockSection(title: "Monday, 3 November", rows: [
            ClosedAskMockRow(id: 351, kind: "check", title: "Confirm the nightly export reached example.com",
                             status: .withdrawn, detail: "⚙ Nightly export · run #12 · withdrawn by the agent",
                             time: "09:12")
        ])
    ]
}

private struct ClosedAsksDrawerMock: View {
    let frame: ClosedAsksShotFixtures.Frame
    private typealias Copy = ClosedAsksMockCopy

    private var sections: [ClosedAskMockSection] {
        switch frame {
        case .big, .busy, .staleError, .partial, .askGone: ClosedAsksMockData.big
        case .search: ClosedAsksMockData.search
        case .narrow: ClosedAsksMockData.narrow
        default: []
        }
    }

    private var total: Int? {
        switch frame {
        case .loading, .error: nil
        case .narrow: 2
        case .empty: 0
        case .partial: 82
        default: 84
        }
    }

    private var shownCount: Int { sections.reduce(0) { $0 + $1.rows.count } }

    private var query: String {
        switch frame {
        case .search: "login"
        case .noMatch: "postgres"
        default: ""
        }
    }

    var body: some View {
        Group {
            if frame == .opened {
                openedAsk
            } else {
                list
            }
        }
        .controlSize(.small)
        .frame(maxWidth: .infinity, maxHeight: frame.height > 0 ? .infinity : nil, alignment: .topLeading)
        .background(Surface.text)
    }

    // MARK: The list

    private var list: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if (total ?? 0) >= 10 { searchRow }
            switch frame {
            case .staleError: banner(Copy.refreshFailed, retry: true)
            case .partial: banner(Copy.unreadable, retry: false)
            case .askGone: banner(Copy.askGone, retry: false)
            default: EmptyView()
            }
            content
        }
    }

    private var header: some View {
        HStack(spacing: Spacing.regular) {
            Image(systemName: "tray.full")
                .foregroundStyle(.secondary)
                .frame(width: IconSize.header)
            VStack(alignment: .leading, spacing: Spacing.tight) {
                HStack(spacing: Spacing.compact) {
                    Text(Copy.title).font(.headline)
                    if let total, total > 0 {
                        Text(query.isEmpty ? "\(total)" : Copy.matches(shownCount, of: total))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if frame == .busy {
                        ProgressView().controlSize(.mini).help(Copy.busyHelp)
                    }
                }
                Text(frame == .narrow ? Copy.scopeAutomations : "Session · Fix the login redirect after SSO")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: Spacing.regular)
            Button {} label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .buttonStyle(.kitIcon(isOn: false))
            Button {} label: { Image(systemName: "xmark") }
                .buttonStyle(.kitIcon(isOn: false))
        }
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.cozy)
    }

    private var searchRow: some View {
        HStack(spacing: Spacing.compact) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            if query.isEmpty {
                Text(Copy.searchPlaceholder).foregroundStyle(.tertiary)
            } else {
                Text(query)
            }
            Spacer(minLength: 0)
            if !query.isEmpty {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
        }
        .font(.callout)
        .padding(.horizontal, Spacing.regular)
        .padding(.vertical, Spacing.compact)
        .background(Fill.card, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .padding(.horizontal, Spacing.medium)
        .padding(.top, Spacing.cozy)
        .padding(.bottom, Spacing.small)
    }

    @ViewBuilder
    private var content: some View {
        switch frame {
        case .loading:
            stateBlock(icon: nil, text: Copy.loading, hint: nil, action: nil)
        case .error:
            stateBlock(icon: "exclamationmark.triangle", text: Copy.loadFailed, hint: nil, action: Copy.retry)
        case .empty:
            stateBlock(icon: "tray", text: Copy.empty, hint: Copy.emptyHint, action: nil)
        case .noMatch:
            stateBlock(icon: "magnifyingglass", text: Copy.noMatch(query), hint: nil, action: Copy.clearSearch)
        default:
            if frame.height > 0 {
                // The real list scrolls (lazy rows); a content-height shot has no room to.
                ScrollView { rows }
            } else {
                rows
            }
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    HStack(spacing: Spacing.compact) {
                        Text(section.title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        Text("\(section.rows.count)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, Spacing.regular)
                    .padding(.bottom, Spacing.tight)
                    .accessibilityAddTraits(.isHeader)
                    ForEach(section.rows) { row in
                        ClosedAskMockRowView(row: row, isSelected: frame == .big && row.id == 410)
                    }
                }
            }
        }
        .padding(.horizontal, Spacing.small)
        .padding(.top, Spacing.regular)
        .padding(.bottom, Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func stateBlock(icon: String?, text: String, hint: String?, action: String?) -> some View {
        VStack(spacing: Spacing.regular) {
            if let icon {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(icon == "exclamationmark.triangle" ? Tone.warning : Color.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(text).font(.callout).multilineTextAlignment(.center)
            if let hint {
                Text(hint).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if let action {
                Button(action) {}.buttonStyle(.kitSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Spacing.wide)
        .padding(.vertical, Spacing.hero)
    }

    private func banner(_ text: String, retry: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tone.warning)
            Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if retry { Button(Copy.retry) {}.buttonStyle(.kitQuiet) }
        }
        .padding(Spacing.regular)
        .card()
        .padding(.horizontal, Spacing.medium)
        .padding(.top, Spacing.small)
    }

    // MARK: An ask opened from the list

    private var openedAsk: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Spacing.compact) {
                Button {} label: {
                    Label(Copy.back, systemImage: "chevron.left")
                }
                .buttonStyle(.kitQuiet)
                Text("84").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.medium)
            .padding(.top, Spacing.regular)
            HStack(spacing: Spacing.regular) {
                Image(systemName: "questionmark.bubble").foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    Text("#411 Which session store should the redirect fix use — the cookie or the server table?")
                        .font(.headline).lineLimit(2)
                    Text("Question · Fix the login redirect after SSO · 2h").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: Spacing.regular)
                Button {} label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(.kitIcon(isOn: false))
                Button {} label: { Image(systemName: "xmark") }
                    .buttonStyle(.kitIcon(isOn: false))
            }
            .padding(.horizontal, Spacing.medium)
            .padding(.vertical, Spacing.cozy)
            Divider()
            VStack(alignment: .leading, spacing: Spacing.regular) {
                Text("The ask's read-only drawer, unchanged: the agent's card, the question, your answer.")
                    .font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: Spacing.small) {
                    Text("Which session store should the redirect fix use?").font(.callout.weight(.semibold))
                    Label("Server table", systemImage: "largecircle.fill.circle")
                    Label("Cookie", systemImage: "circle").foregroundStyle(.secondary)
                    Text("Other: keep the cookie as a fallback").foregroundStyle(.secondary)
                }
                .padding(Spacing.medium)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
            }
            .padding(Spacing.medium)
            Spacer(minLength: 0)
            Divider()
            HStack {
                Chip(text: "Delivered", color: Tone.status("green"))
                Spacer()
            }
            .padding(Spacing.medium)
        }
    }
}

private struct ClosedAskMockRowView: View {
    let row: ClosedAskMockRow
    let isSelected: Bool

    private var icon: String {
        switch row.kind {
        case "review": "doc.text.magnifyingglass"
        case "check": "checklist"
        default: "questionmark.bubble"
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: IconSize.composer)
            VStack(alignment: .leading, spacing: Spacing.small) {
                Text(row.title)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Spacing.compact) {
                    Chip(text: row.status.rawValue, color: row.status.tone)
                    Text("#\(row.id) · \(row.detail)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: Spacing.small)
            Text(row.time)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .kitRow(isSelected: isSelected)
    }
}
