import AppKit
import DesignKit
import SwiftUI
import WatchtowerCore
@testable import WatchtowerDesktop

/// Design-only scenes for the Slack Developer Policy hygiene spec (#1769,
/// `docs/superpowers/specs/2026-11-17-slack-policy-hygiene-design.md` §8).
/// Nothing here is wired into the app; the strings are
/// `SlackPolicyMockCopy`. Sample data only (`acme`, made-up people).
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
        case .personCard, .personStopConfirm, .personStopped:
            PersonMock(frame: frame)
        case .peopleList:
            PeopleListMock()
        case .teamSummary:
            TeamSummaryMock()
        case .orgLinks, .orgLinksEmpty:
            OrgLinksMock(empty: frame == .orgLinksEmpty)
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

/// The FileVault-off line, shared by Privacy and Connections → Slack.
private struct FileVaultLine: View {
    var body: some View {
        HStack(alignment: .top, spacing: Spacing.regular) {
            Image(systemName: "lock.open.fill").foregroundStyle(Tone.warning)
            VStack(alignment: .leading, spacing: Spacing.small) {
                Text(Copy.fileVaultOff).font(.callout).fixedSize(horizontal: false, vertical: true)
                Button(Copy.openFileVault) {}.buttonStyle(.kitSecondary)
            }
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tone.warning.opacity(ChipTint.fillOpacity), in: RoundedRectangle(cornerRadius: Radius.row))
    }
}

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

// MARK: - People

private struct PersonMock: View {
    let frame: SlackPolicyShotFixtures.Frame

    var body: some View {
        Page {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                Text(Copy.personName).font(.title2.weight(.semibold))
                if frame != .personStopped {
                    Text(Copy.personPeriod).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: Spacing.medium)
                if frame == .personCard {
                    Button(Copy.stopCard) {}.buttonStyle(.kitQuiet)
                }
            }
            switch frame {
            case .personStopped:
                VStack(alignment: .leading, spacing: Spacing.regular) {
                    Text(Copy.stoppedLine).font(.callout).foregroundStyle(.secondary)
                    Button(Copy.makeAgain) {}.buttonStyle(.kitSecondary)
                }
            case .personStopConfirm:
                VStack(alignment: .leading, spacing: Spacing.regular) {
                    Text(Copy.stopTitle).font(.headline)
                    Text(Copy.stopBody).font(.callout).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: Spacing.regular) {
                        Spacer()
                        Button(Copy.cancel) {}.buttonStyle(.kitSecondary)
                        Button(Copy.stopConfirm) {}.buttonStyle(.kitDestructive)
                    }
                }
                .padding(Spacing.medium)
                .card()
            default:
                Text(Copy.basisLine).font(.caption).foregroundStyle(.secondary)
                Text(Copy.personSummary).font(.callout).fixedSize(horizontal: false, vertical: true)
                section(Copy.decisionRoleTitle, "arrow.triangle.branch") {
                    Chip(text: Copy.decisionRole, color: Tone.status("blue"))
                }
                section(Copy.guideTitle, "bubble.left.and.text.bubble.right") {
                    Text(Copy.guideText).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                section(Copy.tacticsTitle, "lightbulb") {
                    ForEach(Copy.tactics, id: \.self) { Text("• " + $0).font(.callout) }
                }
            }
        }
    }
}

/// A titled card section, as on the person view.
private func section<Content: View>(
    _ title: String,
    _ icon: String,
    @ViewBuilder _ content: () -> Content
) -> some View {
    VStack(alignment: .leading, spacing: Spacing.regular) {
        Label(title, systemImage: icon).font(.subheadline.weight(.semibold))
        content()
    }
    .padding(Spacing.medium)
    .frame(maxWidth: .infinity, alignment: .leading)
    .card()
}

/// People list rows: role and work topics, no red-flag mark, no message
/// count or volume change.
private struct PeopleListMock: View {
    var body: some View {
        Page {
            Text(Copy.peopleTitle).font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: Spacing.small) {
                ForEach(Copy.peopleRows, id: \.name) { row in
                    HStack(spacing: Spacing.regular) {
                        Text(row.name).font(.body.weight(.medium))
                        Chip(text: row.role, color: Tone.status("blue"))
                        Text(row.line).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: Spacing.regular)
                    }
                    .padding(Spacing.regular)
                    .card()
                }
            }
        }
    }
}

/// Team Summary without Needs Attention: the summary and the tips.
private struct TeamSummaryMock: View {
    var body: some View {
        Page {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                Text(Copy.teamSummaryTitle).font(.title2.weight(.semibold))
                Text(Copy.personPeriod).font(.caption).foregroundStyle(.secondary)
            }
            Text(Copy.teamSummary).font(.callout).fixedSize(horizontal: false, vertical: true)
            section(Copy.tipsTitle, "lightbulb") {
                ForEach(Copy.tips, id: \.self) { Text("• " + $0).font(.callout) }
            }
        }
    }
}

/// People → Connections: only the org links the owner entered.
private struct OrgLinksMock: View {
    let empty: Bool

    var body: some View {
        Page {
            HStack(spacing: Spacing.regular) {
                Text(Copy.orgLinksTitle).font(.title3.weight(.semibold))
                Spacer(minLength: Spacing.medium)
                Button {} label: { Label(Copy.editConnections, systemImage: "pencil") }.buttonStyle(.kitSecondary)
            }
            if empty {
                Text(Copy.orgLinksEmpty).font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: Spacing.small) {
                    ForEach(Copy.orgLinks, id: \.name) { link in
                        HStack(spacing: Spacing.regular) {
                            Text(link.role)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 70, alignment: .leading)
                            Text(link.name).font(.body.weight(.medium))
                            Spacer(minLength: Spacing.regular)
                        }
                    }
                }
                .padding(Spacing.medium)
                .card()
            }
        }
    }
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
