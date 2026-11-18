import AppKit
import DesignKit
import GRDB
import SwiftUI
import WatchtowerCore
@testable import WatchtowerDesktop

/// Design-only scenes for the Slack Full / Live screens (#1779, spec
/// `docs/superpowers/specs/2026-11-15-slack-full-live-screens-design.md`).
/// Nothing here is wired into the app; the strings are
/// `SlackFullLiveMockCopy`. Sample data only (`acme`, made-up ids).
@MainActor
enum SlackFullLiveShotFixtures {
    /// Connections → Slack, one frame per state.
    enum Pane: String, CaseIterable {
        case full, fullLive, live, off, loading, checking, probeFailed, readFailed, liveProblems
        case sharedApp, portBusy, pasteInvalid, organization, setupInstall, setupApproval, linkMissing
    }

    /// The Set up for my company sheet and the Add the link sheet.
    enum Setup: String, CaseIterable {
        case empty, ready, progress, success, badToken, notAllowed, linkFailed, approval
        case addLinkEmpty, addLinkBusy, addLinkError, addLinkDone
        case adopt, adoptAppId, adoptNotCollaborator
    }

    /// Connecting from a link or a pasted code.
    enum Connect: String, CaseIterable {
        case confirm, browser, success, teamMismatch, denied
    }

    /// The onboarding Slack card's sheet when no build-baked app exists (plan B, A13).
    enum Onboarding: String, CaseIterable {
        case empty, organization, pasteInvalid, portBusy
    }

    static var shots: [DesignShot] {
        Pane.allCases.map { pane in
            DesignShot(name: "slack-fl-pane-\(pane.rawValue)", size: NSSize(width: 640, height: 0)) {
                AnyView(SlackPaneMock(pane: pane))
            }
        } + [
            DesignShot(name: "slack-fl-pane-fullLive-narrow", size: NSSize(width: 360, height: 0)) {
                AnyView(SlackPaneMock(pane: .fullLive))
            },
            DesignShot(name: "slack-fl-pane-sharedApp-narrow", size: NSSize(width: 360, height: 0)) {
                AnyView(SlackPaneMock(pane: .sharedApp))
            }
        ] + Setup.allCases.map { frame in
            DesignShot(name: "slack-fl-setup-\(frame.rawValue)", size: NSSize(width: 520, height: 0)) {
                AnyView(SlackSetupSheetMock(frame: frame))
            }
        } + [
            DesignShot(name: "slack-fl-setup-ready-narrow", size: NSSize(width: 380, height: 0)) {
                AnyView(SlackSetupSheetMock(frame: .ready))
            }
        ] + Connect.allCases.map { frame in
            DesignShot(name: "slack-fl-connect-\(frame.rawValue)", size: NSSize(width: 440, height: 0)) {
                AnyView(SlackConnectSheetMock(frame: frame))
            }
        } + Onboarding.allCases.map { frame in
            DesignShot(name: "slack-fl-onboarding-\(frame.rawValue)", size: NSSize(width: 520, height: 0)) {
                AnyView(SlackOnboardingConnectMock(frame: frame))
            }
        } + [
            DesignShot(name: "slack-fl-onboarding-empty-narrow", size: NSSize(width: 380, height: 0)) {
                AnyView(SlackOnboardingConnectMock(frame: .empty))
            },
            DesignShot(name: "slack-fl-needs-full-digests", size: NSSize(width: 720, height: 360)) {
                AnyView(NeedsFullSlackDigestsMock())
            },
            DesignShot(name: "slack-fl-needs-full-digests-narrow", size: NSSize(width: 360, height: 400)) {
                AnyView(NeedsFullSlackDigestsMock())
            },
            // Owner's answer to ask #1315: both tabs stay visible with Live only.
            DesignShot(name: "slack-fl-needs-full-catchup", size: NSSize(width: 720, height: 360)) {
                AnyView(NeedsFullSlackDigestsMock(tab: "catchUp"))
            },
            DesignShot(name: "slack-fl-needs-full-statistics", size: NSSize(width: 720, height: 360)) {
                AnyView(NeedsFullSlackDigestsMock(tab: "statistics"))
            },
            DesignShot(name: "slack-fl-needs-full-home-card", size: NSSize(width: 420, height: 0)) {
                AnyView(NeedsFullSlackHomeCardMock())
            },
            DesignShot(name: "slack-fl-needs-full-knowledge", size: NSSize(width: 640, height: 0)) {
                AnyView(NeedsFullSlackKnowledgeMock())
            },
            DesignShot(name: "slack-fl-artifact-keep-disabled", size: NSSize(width: 640, height: 0)) {
                AnyView(LiveArtifactKeepMock())
            }
        ]
    }
}

private typealias Copy = SlackFullLiveMockCopy

// MARK: - Connections → Slack

private struct SlackPaneMock: View {
    let pane: SlackFullLiveShotFixtures.Pane

    private var hasAccount: Bool {
        [.full, .fullLive, .loading, .checking, .probeFailed, .readFailed, .sharedApp].contains(pane)
    }

    private var showsConnect: Bool { !hasAccount || pane == .sharedApp }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            if pane == .sharedApp { sharedBanner }
            modeSection
            if let record { recordRow(record) }
            if showsConnect { connectSection }
            if hasAccount { workspaces }
        }
        .controlSize(.small)
        .padding(Spacing.page)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .detailBackground()
    }

    /// The real Slack mode section (`SlackModeSection`) on fixture data.
    private var modeSection: some View {
        SlackModeSection(presentation: SlackPaneModeFixture.presentation(pane), checkAgain: {}, tryAgain: {})
    }

    private var connectSection: some View {
        SettingsSection(title: Copy.connectTitle, caption: Copy.connectCaption) {
            if pane == .organization {
                VStack(alignment: .leading, spacing: Spacing.compact) {
                    Text(Copy.orgTitle).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    HStack {
                        Label(Copy.orgRow, systemImage: "building.2").font(.callout)
                        Spacer(minLength: Spacing.medium)
                        Button(Copy.connect) {}.buttonStyle(.kitPrimary)
                    }
                }
            }
            if pane == .portBusy {
                HStack(alignment: .top, spacing: Spacing.regular) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tone.warning)
                    Text(Copy.portBusy).font(.caption).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: Spacing.regular) {
                TextField(Copy.pastePlaceholder, text: .constant(pasteText)).textFieldStyle(.kit)
                Button(Copy.connect) {}
                    .buttonStyle(.kitSecondary)
                    .disabled(pasteText.isEmpty)
            }
            if pane == .pasteInvalid {
                Text(Copy.pasteInvalid)
                    .font(.caption)
                    .foregroundStyle(Tone.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Spacing.regular) {
                Text(Copy.noAppYet).font(.caption).foregroundStyle(.secondary)
                Button(Copy.setUpForCompany) {}.buttonStyle(.kitQuiet)
            }
        }
    }

    private var pasteText: String {
        pane == .pasteInvalid ? "https://acme.slack.com/apps/A0ACME" : ""
    }

    private var record: (String, String, Bool)? {
        switch pane {
        case .setupInstall: (Copy.recordInstall, Copy.continueSetup, true)
        case .setupApproval: (Copy.recordApproval, Copy.checkAgain, false)
        case .linkMissing: (Copy.recordLinkMissing, Copy.addLink, true)
        default: nil
        }
    }

    private func recordRow(_ record: (String, String, Bool)) -> some View {
        HStack(alignment: .center, spacing: Spacing.medium) {
            Image(systemName: record.2 ? "wrench.and.screwdriver" : "hourglass").foregroundStyle(Tone.warning)
            Text(record.0).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Spacing.medium)
            Button(record.1) {}.buttonStyle(.kitPrimary)
        }
        .padding(Spacing.medium)
        .card()
    }

    private var sharedBanner: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            HStack(spacing: Spacing.regular) {
                Image(systemName: "clock.badge.exclamationmark").foregroundStyle(Tone.warning)
                Text(Copy.sharedTitle).font(.headline)
            }
            Text(Copy.sharedBody).font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Spacing.regular) {
                Button(Copy.setUpForCompany) {}.buttonStyle(.kitSecondary)
                Button(Copy.pasteALink) {}.buttonStyle(.kitQuiet)
            }
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tone.warning.opacity(ChipTint.fillOpacity), in: RoundedRectangle(cornerRadius: Radius.row))
    }

    private var workspaces: some View {
        SettingsSection(title: Copy.workspacesTitle) {
            HStack(spacing: Spacing.regular) {
                Image(systemName: "number").foregroundStyle(.secondary)
                Text("acme").font(.body)
                if pane == .sharedApp { OutlineTag(text: Copy.chipShared) }
                Spacer(minLength: Spacing.medium)
                Text(pane == .sharedApp ? Copy.accountShared : Copy.accountFull)
                    .font(.caption).foregroundStyle(.secondary)
            }
            if pane != .sharedApp {
                Button(Copy.connectAnother) {}.buttonStyle(.kitQuiet)
            }
        }
    }
}

// MARK: - Set up for my company / Add the link

private struct SlackSetupSheetMock: View {
    let frame: SlackFullLiveShotFixtures.Setup

    private var isAddLink: Bool { frame.rawValue.hasPrefix("addLink") }

    private var token: String {
        switch frame {
        case .empty, .addLinkEmpty: ""
        default: "xoxe.xoxp-1-sample-token"
        }
    }

    private var isBusy: Bool { frame == .progress || frame == .addLinkBusy }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            VStack(alignment: .leading, spacing: Spacing.small) {
                Text(isAddLink ? Copy.addLinkTitle : Copy.setupTitle).font(.title3.weight(.semibold))
                Text(isAddLink ? Copy.addLinkIntro : Copy.setupIntro)
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if showsForm { form }
            if frame == .progress { progress }
            outcome
            buttons
        }
        .controlSize(.small)
        .padding(Spacing.page)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .detailBackground()
    }

    private var showsForm: Bool {
        [.empty, .ready, .badToken, .notAllowed, .addLinkEmpty, .addLinkBusy, .addLinkError,
         .adopt, .adoptAppId, .adoptNotCollaborator].contains(frame)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            VStack(alignment: .leading, spacing: Spacing.small) {
                Text(Copy.setupStep1).font(.headline)
                Text(Copy.setupStep1Help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(Copy.openTokenPage) {}.buttonStyle(.kitSecondary)
            }
            VStack(alignment: .leading, spacing: Spacing.small) {
                Text(Copy.setupStep2).font(.headline)
                SecureField(Copy.tokenPlaceholder, text: .constant(token)).textFieldStyle(.kit).disabled(isBusy)
                Text(Copy.tokenNote).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            ForEach(Array(Copy.progressSteps.enumerated()), id: \.offset) { index, step in
                HStack(spacing: Spacing.regular) {
                    Group {
                        if index < 2 {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Tone.success)
                        } else if index == 2 {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "circle").foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: ListLayout.markColumn)
                    Text(step).font(.callout).foregroundStyle(index > 2 ? .secondary : .primary)
                }
            }
            Text(Copy.progressCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    @ViewBuilder private var outcome: some View {
        switch frame {
        case .success:
            notice(icon: "checkmark.circle.fill", tone: Tone.success, title: Copy.successTitle, body: Copy.successBody)
        case .badToken, .addLinkError:
            notice(icon: "exclamationmark.triangle.fill", tone: Tone.warning, title: nil, body: Copy.badToken)
        case .notAllowed:
            notice(icon: "exclamationmark.triangle.fill", tone: Tone.warning, title: nil, body: Copy.notAllowed)
        case .linkFailed:
            notice(icon: "exclamationmark.triangle.fill", tone: Tone.warning, title: Copy.successTitle, body: Copy.linkFailed)
        case .approval:
            notice(icon: "hourglass", tone: Tone.warning, title: nil, body: Copy.approval)
        case .addLinkBusy:
            HStack(spacing: Spacing.regular) {
                ProgressView().controlSize(.small)
                Text(Copy.addLinkBusy).font(.caption).foregroundStyle(.secondary)
            }
        case .addLinkDone:
            notice(icon: "checkmark.circle.fill", tone: Tone.success, title: nil, body: Copy.addLinkDone)
        case .adopt:
            notice(icon: "arrow.triangle.2.circlepath", tone: Tone.status("blue"), title: Copy.adoptTitle, body: Copy.adoptBody)
        case .adoptAppId:
            VStack(alignment: .leading, spacing: Spacing.medium) {
                notice(icon: "arrow.triangle.2.circlepath", tone: Tone.status("blue"),
                       title: Copy.adoptTitle, body: Copy.adoptBody)
                VStack(alignment: .leading, spacing: Spacing.small) {
                    TextField(Copy.adoptAppIDLabel, text: .constant("")).textFieldStyle(.kit)
                    Text(Copy.adoptAppIDHelp).font(.caption).foregroundStyle(.secondary)
                }
            }
        case .adoptNotCollaborator:
            notice(icon: "exclamationmark.triangle.fill", tone: Tone.warning, title: Copy.adoptTitle,
                   body: Copy.notCollaborator)
        default:
            EmptyView()
        }
    }

    private func notice(icon: String, tone: Color, title: String?, body: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.regular) {
            Image(systemName: icon).foregroundStyle(tone)
            VStack(alignment: .leading, spacing: Spacing.small) {
                if let title { Text(title).font(.headline) }
                Text(body).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var buttons: some View {
        HStack(spacing: Spacing.regular) {
            Spacer()
            switch frame {
            case .empty, .ready:
                Button(Copy.cancel) {}.buttonStyle(.kitSecondary)
                Button(Copy.createApp) {}.buttonStyle(.kitPrimary).disabled(token.isEmpty)
            case .progress:
                Button(Copy.close) {}.buttonStyle(.kitSecondary)
            case .badToken:
                Button(Copy.cancel) {}.buttonStyle(.kitSecondary)
                Button(Copy.tryAgain) {}.buttonStyle(.kitPrimary)
            case .notAllowed, .adoptNotCollaborator:
                Button(Copy.cancel) {}.buttonStyle(.kitSecondary)
                Button(Copy.copyAdminNote) {}.buttonStyle(.kitSecondary)
                Button(Copy.tryAgain) {}.buttonStyle(.kitPrimary)
            case .adopt, .adoptAppId:
                Button(Copy.cancel) {}.buttonStyle(.kitSecondary)
                Button(Copy.adoptAction) {}.buttonStyle(.kitPrimary).disabled(frame == .adoptAppId)
            case .success:
                Button(Copy.copyCode) {}.buttonStyle(.kitSecondary)
                Button(Copy.done) {}.buttonStyle(.kitPrimary)
            case .linkFailed:
                Button(Copy.close) {}.buttonStyle(.kitSecondary)
                Button(Copy.addLink) {}.buttonStyle(.kitPrimary)
            case .approval:
                Button(Copy.close) {}.buttonStyle(.kitSecondary)
                Button(Copy.checkAgain) {}.buttonStyle(.kitPrimary)
            case .addLinkEmpty, .addLinkBusy:
                Button(Copy.cancel) {}.buttonStyle(.kitSecondary)
                Button(Copy.addLinkAction) {}.buttonStyle(.kitPrimary).disabled(token.isEmpty || isBusy)
            case .addLinkError:
                Button(Copy.cancel) {}.buttonStyle(.kitSecondary)
                Button(Copy.tryAgain) {}.buttonStyle(.kitPrimary)
            case .addLinkDone:
                Button(Copy.done) {}.buttonStyle(.kitPrimary)
            }
        }
    }
}

// MARK: - Onboarding: connect Slack without a build-baked app (plan B, A13)

private struct SlackOnboardingConnectMock: View {
    let frame: SlackFullLiveShotFixtures.Onboarding

    private var pasteText: String { frame == .pasteInvalid ? "https://acme.slack.com/apps/A0ACME" : "" }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            VStack(alignment: .leading, spacing: Spacing.small) {
                Text(Copy.onboardingTitle).font(.title3.weight(.semibold))
                Text(Copy.onboardingCaption)
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: Spacing.medium) {
                if frame == .organization {
                    VStack(alignment: .leading, spacing: Spacing.compact) {
                        Text(Copy.orgTitle).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        HStack {
                            Label(Copy.orgRow, systemImage: "building.2").font(.callout)
                            Spacer(minLength: Spacing.medium)
                            Button(Copy.connect) {}.buttonStyle(.kitPrimary)
                        }
                    }
                }
                if frame == .portBusy {
                    HStack(alignment: .top, spacing: Spacing.regular) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tone.warning)
                        Text(Copy.portBusy).font(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: Spacing.regular) {
                    TextField(Copy.pastePlaceholder, text: .constant(pasteText)).textFieldStyle(.kit)
                    Button(Copy.connect) {}
                        .buttonStyle(.kitSecondary)
                        .disabled(pasteText.isEmpty)
                }
                if frame == .pasteInvalid {
                    Text(Copy.pasteInvalid)
                        .font(.caption).foregroundStyle(Tone.error).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: Spacing.regular) {
                    Text(Copy.noAppYet).font(.caption).foregroundStyle(.secondary)
                    Button(Copy.setUpForCompany) {}.buttonStyle(.kitQuiet)
                }
            }
            .padding(Spacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
            Text(Copy.onboardingLiveHint)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(Copy.skip) {}.buttonStyle(.kitSecondary)
            }
        }
        .controlSize(.small)
        .padding(Spacing.page)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .detailBackground()
    }
}

// MARK: - Connect from a link or code

private struct SlackConnectSheetMock: View {
    let frame: SlackFullLiveShotFixtures.Connect

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            switch frame {
            case .confirm:
                Text(Copy.confirmTitle).font(.title3.weight(.semibold))
                Text(Copy.confirmBody).font(.callout).fixedSize(horizontal: false, vertical: true)
            case .browser:
                HStack(alignment: .top, spacing: Spacing.regular) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: Spacing.small) {
                        Text(Copy.browserWait).font(.callout).fixedSize(horizontal: false, vertical: true)
                        Text(Copy.browserNote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            case .success:
                notice("checkmark.circle.fill", Tone.success, Copy.connectedTitle, Copy.connectedBody)
            case .teamMismatch:
                notice("exclamationmark.triangle.fill", Tone.warning, nil, Copy.teamMismatch)
            case .denied:
                notice("xmark.circle", Tone.status("gray"), nil, Copy.denied)
            }
            HStack(spacing: Spacing.regular) {
                Spacer()
                switch frame {
                case .confirm:
                    Button(Copy.cancel) {}.buttonStyle(.kitSecondary)
                    Button(Copy.connect) {}.buttonStyle(.kitPrimary)
                case .browser:
                    Button(Copy.cancel) {}.buttonStyle(.kitSecondary)
                case .success:
                    Button(Copy.done) {}.buttonStyle(.kitPrimary)
                case .teamMismatch, .denied:
                    Button(Copy.close) {}.buttonStyle(.kitSecondary)
                    Button(Copy.startAgain) {}.buttonStyle(.kitPrimary)
                }
            }
        }
        .controlSize(.small)
        .padding(Spacing.page)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .detailBackground()
    }

    private func notice(_ icon: String, _ tone: Color, _ title: String?, _ body: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.regular) {
            Image(systemName: icon).foregroundStyle(tone)
            VStack(alignment: .leading, spacing: Spacing.small) {
                if let title { Text(title).font(.headline) }
                Text(body).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - needsFullSlack

/// The real `FeatureEmptyState` of a Slack tab under `Readiness.needsFullSlack`
/// (screens spec §2.1): its line and its one Connect workspace app button.
private struct NeedsFullSlackDigestsMock: View {
    var tab = "digests"

    var body: some View {
        if let copy = EmptyStateCopyTable.copy(for: tab, briefingHour: 8) {
            FeatureEmptyState(
                copy: copy, readiness: .needsFullSlack, syncLine: nil, turnOnError: nil, isTurningOn: false
            ) { _ in }
            .detailBackground()
        }
    }
}

/// The real Home → Getting ready row of Digests under `needsFullSlack`.
private struct NeedsFullSlackHomeCardMock: View {
    var body: some View {
        GettingReadyRowView(
            card: GettingReadyCard(
                feature: .digests,
                copy: EmptyStateCopyTable.featureCard(.digests, briefingHour: 8),
                readiness: .needsFullSlack)
        ) { _ in }
        .controlSize(.small)
        .padding(Spacing.large)
        .detailBackground()
    }
}

/// No Knowledge search view exists in the Desktop yet (the knowledge index
/// is read by the chats' `search_knowledge`): the note's string is
/// `SlackModePresentation.knowledgeNote`, laid out as the mockup did.
private struct NeedsFullSlackKnowledgeMock: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            HStack(spacing: Spacing.regular) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                Text("release checklist").foregroundStyle(.secondary)
                Spacer()
            }
            .padding(Spacing.regular)
            .card()
            HStack(alignment: .top, spacing: Spacing.regular) {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Text(SlackPaneModeFixture.presentation(.live).knowledgeNote ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Spacing.regular)
                Button(Copy.needsFullAction) {}.buttonStyle(.kitQuiet)
            }
            ForEach(["Release checklist — Confluence", "Release notes 2.4 — kept chat artifact"], id: \.self) { title in
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    Text(title).font(.callout)
                    Text("example.com").font(.caption).foregroundStyle(.secondary)
                }
                .padding(Spacing.regular)
                .frame(maxWidth: .infinity, alignment: .leading)
                .kitRow(isSelected: false)
            }
        }
        .controlSize(.small)
        .padding(Spacing.page)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .detailBackground()
    }
}

// MARK: - Add to Knowledge disabled (shipped)

/// The artifact panel's action bar as `ArtifactPanelView` draws it, with the
/// hover help that carries the reason drawn as a tooltip.
private struct LiveArtifactKeepMock: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            HStack(alignment: .top, spacing: Spacing.regular) {
                Button("Edit") {}
                Button("Copy") {}
                Button("Export…") {}
                VStack(alignment: .leading, spacing: Spacing.small) {
                    Button {} label: { Label(Copy.keepTitle, systemImage: "books.vertical") }.disabled(true)
                    Text(Copy.keepReason)
                        .font(.caption)
                        .padding(.horizontal, Spacing.regular)
                        .padding(.vertical, Spacing.small)
                        .card()
                }
                Spacer()
            }
        }
        .padding(Spacing.cozy)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .panelBackground()
    }
}

// MARK: - The real Slack mode section's fixture data

/// `SlackModePresentation` for each pane frame, built from sample accounts
/// and `slack_live_status` rows (`acme`, made-up ids) at a fixed clock.
@MainActor
enum SlackPaneModeFixture {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func presentation(_ pane: SlackFullLiveShotFixtures.Pane) -> SlackModePresentation {
        let acme = SlackAccount(row: Row([
            "id": 1, "team_id": "T0ACME", "team_name": "acme", "status": "ok", "enabled": true
        ]))
        let hasAccount: Set<SlackFullLiveShotFixtures.Pane> =
            [.full, .fullLive, .loading, .checking, .probeFailed, .readFailed, .sharedApp]
        var lastError: SlackLiveError?
        switch pane {
        case .probeFailed:
            lastError = SlackLiveError(
                provider: "claude", message: "the watchtower command did not answer in 150 seconds.", kind: .probe)
        case .readFailed:
            lastError = SlackLiveError(provider: "", message: "database is locked", kind: .read)
        default: break
        }
        return SlackModePresentation(
            accounts: hasAccount.contains(pane) ? [acme] : [],
            sharedAppAccountIDs: pane == .sharedApp ? [1] : [],
            liveStatuses: rows(pane),
            isRunning: pane == .checking,
            hasRead: pane != .loading,
            lastError: lastError,
            now: now)
    }

    private static func rows(_ pane: SlackFullLiveShotFixtures.Pane) -> [SlackLiveStatusRow] {
        let twoHours: TimeInterval = 2 * 3600, fiveHours: TimeInterval = 5 * 3600, twelveMin: TimeInterval = 12 * 60
        switch pane {
        case .full:
            return [row("claude", "not_connected", "connectors_off", ago: twoHours)]
        case .fullLive, .checking, .probeFailed, .readFailed:
            return [row("claude", "ok", team: "T0ACME", ago: fiveHours),
                    row("codex", "not_connected", "cli_missing", ago: fiveHours)]
        case .live:
            return [row("claude", "not_connected", "no_connector", ago: twelveMin),
                    row("codex", "ok", team: "T0ACME", ago: twelveMin)]
        case .liveProblems:
            return [row("claude", "ok", ago: 10), row("codex", "needs_admin", ago: 10)]
        case .sharedApp:
            return [row("claude", "no_plan", ago: twoHours)]
        case .loading, .off:
            return []
        default:
            return [row("claude", "not_connected", "no_connector", ago: twelveMin)]
        }
    }

    private static func row(
        _ provider: String, _ status: String, _ errorClass: String = "", team: String = "", ago: TimeInterval
    ) -> SlackLiveStatusRow {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return SlackLiveStatusRow(
            teamID: team, provider: provider, status: status, errorClass: errorClass, connectorID: "",
            checkedAt: fmt.string(from: now.addingTimeInterval(-ago)))
    }
}
