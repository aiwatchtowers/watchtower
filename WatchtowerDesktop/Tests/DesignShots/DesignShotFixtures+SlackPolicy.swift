import AppKit
import DesignKit
import SwiftUI
import WatchtowerCore
@testable import WatchtowerDesktop
import WatchtowerTestSupport

/// Scenes of the Slack Developer Policy hygiene spec (#1769,
/// `docs/superpowers/specs/2026-11-17-slack-policy-hygiene-design.md` §8).
/// The People frames render the real views on fixture data; the others are
/// still design-only. The strings are `SlackPolicyMockCopy`. Sample data
/// only (`acme`, made-up people).
@MainActor
enum SlackPolicyShotFixtures {
    enum Frame: String, CaseIterable {
        case privacyDefault, privacyOnAll, privacyOff, privacyPolicy, privacyFileVault
        case slackFileVault, slackRemoved
        case removeOn, removeOff
        case setupDisclosure, connectDisclosure
        case personCard, personStopConfirm, personStopped
        case peopleList, teamSummary, orgLinks, orgLinksEmpty
        case digestHeader

        var width: CGFloat {
            switch self {
            case .removeOn, .removeOff: 420
            case .setupDisclosure: 520
            case .connectDisclosure: 440
            default: 640
            }
        }
    }

    static var shots: [DesignShot] {
        Frame.allCases.map { frame in
            DesignShot(name: "slack-ph-\(frame.rawValue)", size: NSSize(width: frame.width, height: 0)) {
                AnyView(scene(frame))
            }
        } + [Frame.privacyDefault, .slackRemoved, .personStopped].map { frame in
            DesignShot(name: "slack-ph-\(frame.rawValue)-narrow", size: NSSize(width: 360, height: 0)) {
                AnyView(scene(frame))
            }
        }
    }

    @ViewBuilder private static func scene(_ frame: Frame) -> some View {
        switch frame {
        case .privacyDefault, .privacyOnAll, .privacyOff, .privacyPolicy, .privacyFileVault:
            PrivacyMock(frame: frame)
        case .slackFileVault, .slackRemoved:
            SlackWorkspacesMock(frame: frame)
        case .removeOn, .removeOff:
            RemoveDialogMock(purgeOn: frame == .removeOn)
        case .setupDisclosure:
            SetupDisclosureMock()
        case .connectDisclosure:
            ConnectDisclosureMock()
        case .personCard, .personStopConfirm, .personStopped, .peopleList, .teamSummary, .orgLinks, .orgLinksEmpty:
            PeopleShotScenes.scene(frame)
        case .digestHeader:
            DigestHeaderMock()
        }
    }
}

private typealias Copy = SlackPolicyMockCopy

/// The page frame every scene shares.
private struct Page<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.large) { content }
            .controlSize(.small)
            .padding(Spacing.page)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .detailBackground()
    }
}

private typealias FileVaultLine = FileVaultLineContent

// MARK: - Settings → System → Privacy

private struct PrivacyMock: View {
    let frame: SlackPolicyShotFixtures.Frame

    private var isOn: Bool { frame != .privacyOff }

    private var foot: String {
        switch frame {
        case .privacyOff: Copy.footOff
        case .privacyOnAll, .privacyPolicy: Copy.footOnAll
        default: Copy.footDefault
        }
    }

    var body: some View {
        Page {
            if frame == .privacyFileVault { FileVaultLine() }
            SettingsSection(title: Copy.privacyTitle) {
                SettingRow(title: Copy.purgeTitle,
                           caption: [.privacyDefault, .privacyFileVault].contains(frame) ? Copy.captionDefault : nil) {
                    Toggle("", isOn: .constant(isOn))
                        .labelsHidden()
                        .managedByOrganization(frame == .privacyPolicy)
                }
                Text(foot)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Connections → Slack

private struct SlackWorkspacesMock: View {
    let frame: SlackPolicyShotFixtures.Frame

    var body: some View {
        Page {
            if frame == .slackFileVault { FileVaultLine() }
            SettingsSection(title: Copy.workspacesTitle) {
                HStack(spacing: Spacing.regular) {
                    Image(systemName: "number").foregroundStyle(.secondary)
                    Text("acme").font(.body)
                    if frame == .slackRemoved { OutlineTag(text: Copy.accountRemoved) }
                    Spacer(minLength: Spacing.medium)
                    if frame != .slackRemoved {
                        Text(Copy.accountFull).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if frame == .slackRemoved {
                    HStack(alignment: .top, spacing: Spacing.regular) {
                        Text(Copy.removedLine)
                            .font(.caption)
                            .foregroundStyle(Tone.error)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: Spacing.regular)
                        Button(Copy.addAgain) {}.buttonStyle(.kitSecondary)
                    }
                }
            }
        }
    }
}

// MARK: - Remove dialog

private struct RemoveDialogMock: View {
    let purgeOn: Bool

    var body: some View {
        Page {
            HStack(alignment: .top, spacing: Spacing.regular) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tone.warning)
                VStack(alignment: .leading, spacing: Spacing.small) {
                    Text(Copy.removeTitle).font(.headline)
                    Text(purgeOn ? Copy.removeBodyOn : Copy.removeBodyOff)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: Spacing.regular) {
                Spacer()
                Button(Copy.cancel) {}.buttonStyle(.kitSecondary)
                Button(Copy.remove) {}.buttonStyle(.kitDestructive)
            }
        }
    }
}

// MARK: - Disclosure

private struct DisclosureBlock: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            Text(Copy.disclosureTitle).font(.subheadline.weight(.semibold))
            ForEach(Copy.disclosureLines, id: \.self) { line in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                    Text("•").foregroundStyle(.secondary)
                    Text(line).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
            Button(Copy.privacyLink) {}.buttonStyle(.kitQuiet)
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

/// The Set up for my company sheet's first step with the disclosure above
/// the token paste (screens spec frame `slack-fl-setup-empty`).
private struct SetupDisclosureMock: View {
    private typealias Setup = SlackFullLiveMockCopy

    var body: some View {
        Page {
            Text(Setup.setupTitle).font(.title3.weight(.semibold))
            Text(Setup.setupIntro).font(.callout).fixedSize(horizontal: false, vertical: true)
            DisclosureBlock()
            VStack(alignment: .leading, spacing: Spacing.small) {
                Text(Setup.setupStep1).font(.subheadline.weight(.semibold))
                Text(Setup.setupStep1Help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(Setup.openTokenPage) {}.buttonStyle(.kitSecondary)
            }
            VStack(alignment: .leading, spacing: Spacing.small) {
                Text(Setup.setupStep2).font(.subheadline.weight(.semibold))
                TextField(Setup.tokenPlaceholder, text: .constant("")).textFieldStyle(.kit)
                Text(Setup.tokenNote).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: Spacing.regular) {
                Spacer()
                Button(Setup.cancel) {}.buttonStyle(.kitSecondary)
                Button(Setup.createApp) {}.buttonStyle(.kitPrimary).disabled(true)
            }
        }
    }
}

/// The connect confirm (screens spec frame `slack-fl-connect-confirm`) with
/// the one-line disclosure.
private struct ConnectDisclosureMock: View {
    private typealias Connect = SlackFullLiveMockCopy

    var body: some View {
        Page {
            Text(Connect.confirmTitle).font(.title3.weight(.semibold))
            Text(Connect.confirmBody).font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: Spacing.regular) {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    Text(Copy.connectLine).font(.caption).fixedSize(horizontal: false, vertical: true)
                    Button(Copy.privacyLink) {}.buttonStyle(.kitQuiet)
                }
            }
            HStack(spacing: Spacing.regular) {
                Spacer()
                Button(Connect.cancel) {}.buttonStyle(.kitSecondary)
                Button(Connect.connect) {}.buttonStyle(.kitPrimary)
            }
        }
    }
}

// MARK: - People (the real views)

/// People → person card, Stop card, People list rows, Team Summary and the
/// owner's org links, rendered from the real views on fixture data.
@MainActor
private enum PeopleShotScenes {
    @ViewBuilder static func scene(_ frame: SlackPolicyShotFixtures.Frame) -> some View {
        switch frame {
        case .personCard, .personStopConfirm:
            if let card = dana {
                PersonDetailView(
                    card: card,
                    userName: "dana",
                    history: [],
                    userNameResolver: name,
                    onStopCard: {},
                    confirmingStop: frame == .personStopConfirm
                )
            }
        case .personStopped:
            PersonStoppedView(userName: "dana") {}
        case .peopleList:
            Page {
                Text(Copy.peopleTitle).font(.title2.weight(.semibold))
                VStack(alignment: .leading, spacing: Spacing.small) {
                    ForEach(rows, id: \.userID) { card in
                        PeoplePersonRow(card: card, userName: name(card.userID)) { EmptyView() }
                    }
                }
            }
        case .teamSummary:
            TeamSummaryDetailView(summary: teamSummary)
        case .orgLinks, .orgLinksEmpty:
            ConnectionsView(
                profile: frame == .orgLinks ? orgProfile : nil,
                allCards: [],
                userNameResolver: name
            ) { _, _, _ in }
            .detailBackground()
        default:
            EmptyView()
        }
    }

    private static func name(_ userID: String) -> String {
        ["1:UDANA": "dana", "1:ULEE": "lee", "1:USAM": "sam"][userID] ?? userID
    }

    /// Nov 3 – Nov 16, the mockups' window.
    private static func day(_ day: Int) -> Double {
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: day, hour: 12))
        return date?.timeIntervalSince1970 ?? 0
    }

    private static func json(_ items: [String]) -> String {
        (try? String(data: JSONEncoder().encode(items), encoding: .utf8)) ?? "[]"
    }

    /// The cards, written to a test database and read back as the view
    /// model reads them.
    private static let cards: [PeopleCard] = {
        do {
            let (manager, _) = try TestDatabase.createDatabaseManager()
            return try manager.dbPool.write { db in
                for (index, row) in Copy.peopleRows.enumerated() {
                    let userID = ["1:UDANA", "1:ULEE", "1:USAM"][index]
                    let isDana = index == 0
                    try TestDatabase.insertPeopleCard(
                        db, userID: userID, periodFrom: day(3), periodTo: day(16),
                        messageCount: isDana ? 42 : 30 - index, channelsActive: isDana ? 5 : 3,
                        summary: isDana ? Copy.personSummary : row.line,
                        decisionRole: row.role, highlights: "[]",
                        communicationGuide: isDana ? Copy.guideText : "",
                        tactics: isDana ? json(Copy.tactics) : "[]"
                    )
                }
                return try PeopleCardQueries.fetchForWindow(db, from: day(3), to: day(16))
            }
        } catch {
            return []
        }
    }()

    private static var dana: PeopleCard? { cards.first { $0.userID == "1:UDANA" } }

    /// The list's rows in the mockups' order, the person's summary line
    /// standing in for the topics.
    private static var rows: [PeopleCard] {
        ["1:UDANA", "1:ULEE", "1:USAM"].compactMap { id in
            guard var card = cards.first(where: { $0.userID == id }) else { return nil }
            if let row = Copy.peopleRows.first(where: { $0.name == "@" + name(id) }) { card.summary = row.line }
            return card
        }
    }

    private static let teamSummary = PeopleCardSummary(
        id: 1, periodFrom: day(3), periodTo: day(16), summary: Copy.teamSummary, attention: "[]",
        tips: json(Copy.tips), model: "", inputTokens: 0, outputTokens: 0, costUSD: 0, promptVersion: 1,
        createdAt: ""
    )

    private static let orgProfile = UserProfile(
        slackUserID: "1:UOWNER", peers: json(["1:USAM", "1:UDANA"]), manager: "1:ULEE"
    )
}

// MARK: - Digest detail

/// The digest header without Mark read in Slack.
private struct DigestHeaderMock: View {
    var body: some View {
        Page {
            HStack(spacing: Spacing.regular) {
                Text(Copy.digestTitle).font(.title2.weight(.semibold))
                Spacer(minLength: Spacing.medium)
                Label(Copy.digestMessages, systemImage: "message").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
