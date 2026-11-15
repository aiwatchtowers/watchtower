import AppKit
import DesignKit
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
    }

    /// Connecting from a link or a pasted code.
    enum Connect: String, CaseIterable {
        case confirm, browser, success, teamMismatch, denied
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
        } + [
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

/// One Live row: a provider, its status, the reason and the time.
private struct LiveRowMock {
    let provider: String
    let status: String
    let reason: String?
    let checked: String
    let tone: Color
}

private struct SlackPaneMock: View {
    let pane: SlackFullLiveShotFixtures.Pane

    private var chip: (String, Color) {
        switch pane {
        case .full: (Copy.chipFull, Tone.success)
        case .fullLive, .loading, .checking, .probeFailed, .readFailed: (Copy.chipFullLive, Tone.success)
        case .live, .liveProblems: (Copy.chipLive, Tone.status("blue"))
        case .sharedApp: (Copy.chipShared, Tone.warning)
        default: (Copy.chipOff, Tone.status("gray"))
        }
    }

    private var summary: String {
        switch pane {
        case .full: Copy.summaryFull
        case .fullLive, .loading, .checking, .probeFailed, .readFailed: Copy.summaryFullLive
        case .live, .liveProblems: Copy.summaryLive
        case .sharedApp: Copy.summaryShared
        default: Copy.summaryOff
        }
    }

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

    private var modeSection: some View {
        SettingsSection(title: Copy.modeTitle, isBusy: pane == .checking) {
            HStack(spacing: Spacing.regular) {
                Chip(text: chip.0, color: chip.1, dot: true)
                Spacer(minLength: Spacing.medium)
            }
            Text(summary).font(.callout).fixedSize(horizontal: false, vertical: true)
            liveBlock
        }
    }

    private var liveRows: [LiveRowMock] {
        switch pane {
        case .full:
            [LiveRowMock(provider: Copy.providerClaude, status: Copy.liveNotConnected,
                         reason: Copy.reasonConnectorsOff, checked: Copy.checked2H, tone: Tone.status("gray"))]
        case .fullLive, .checking, .probeFailed:
            [LiveRowMock(provider: Copy.providerClaude, status: Copy.liveOn, reason: nil,
                         checked: Copy.checked5H, tone: Tone.success),
             LiveRowMock(provider: Copy.providerCodex, status: Copy.liveNotConnected,
                         reason: Copy.reasonCLIMissing, checked: Copy.checked5H, tone: Tone.status("gray"))]
        case .live:
            [LiveRowMock(provider: Copy.providerClaude, status: Copy.liveNotConnected,
                         reason: Copy.reasonDefault, checked: Copy.checked12Min, tone: Tone.status("gray")),
             LiveRowMock(provider: Copy.providerCodex, status: Copy.liveOnTeamID, reason: nil,
                         checked: Copy.checked12Min, tone: Tone.success)]
        case .liveProblems:
            [LiveRowMock(provider: Copy.providerClaude, status: Copy.liveOnUnidentified,
                         reason: Copy.reasonUnidentified, checked: Copy.checkedJustNow, tone: Tone.success),
             LiveRowMock(provider: Copy.providerCodex, status: Copy.liveNeedsAdmin,
                         reason: Copy.reasonNeedsAdmin, checked: Copy.checkedJustNow, tone: Tone.warning)]
        case .sharedApp:
            [LiveRowMock(provider: Copy.providerClaude, status: Copy.liveNoPlan,
                         reason: Copy.reasonNoPlan, checked: Copy.checked2H, tone: Tone.status("gray"))]
        default:
            [LiveRowMock(provider: Copy.providerClaude, status: Copy.liveNotConnected,
                         reason: Copy.reasonDefault, checked: Copy.checked12Min, tone: Tone.status("gray"))]
        }
    }

    @ViewBuilder private var liveBlock: some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            HStack(spacing: Spacing.regular) {
                Text(Copy.liveTitle).font(.subheadline.weight(.semibold))
                Spacer(minLength: Spacing.medium)
                if pane != .loading, pane != .readFailed {
                    Button(Copy.checkAgain) {}.buttonStyle(.kitSecondary).disabled(pane == .checking)
                }
            }
            switch pane {
            case .loading:
                HStack(spacing: Spacing.regular) {
                    ProgressView().controlSize(.small)
                    Text(Copy.loading).font(.caption).foregroundStyle(.secondary)
                }
            case .readFailed:
                problem(Copy.readFailed, action: Copy.tryAgain)
            case .off:
                Text(Copy.notCheckedYet).font(.caption).foregroundStyle(.secondary)
            default:
                ForEach(liveRows, id: \.provider) { row in liveRow(row) }
                if pane == .checking {
                    Text(Copy.checking).font(.caption).foregroundStyle(.secondary)
                }
                if pane == .probeFailed { problem(Copy.probeFailed, action: nil) }
            }
        }
        .padding(.top, Spacing.small)
    }

    private func liveRow(_ row: LiveRowMock) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
            Circle().fill(row.tone).frame(width: IconSize.stateDot, height: IconSize.stateDot)
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text("\(row.provider): \(row.status)").font(.callout)
                if let reason = row.reason {
                    Text(reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Spacing.medium)
            Text(row.checked).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func problem(_ text: String, action: String?) -> some View {
        HStack(alignment: .top, spacing: Spacing.regular) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tone.warning)
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Spacing.regular)
            if let action { Button(action) {}.buttonStyle(.kitSecondary) }
        }
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
        [.empty, .ready, .badToken, .notAllowed, .addLinkEmpty, .addLinkBusy, .addLinkError].contains(frame)
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
            case .badToken, .notAllowed:
                Button(Copy.cancel) {}.buttonStyle(.kitSecondary)
                Button(Copy.tryAgain) {}.buttonStyle(.kitPrimary)
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

/// The real `FeatureEmptyState` of the Digests tab; the new readiness line
/// and its button stand in `extra` until `Readiness.needsFullSlack` exists.
private struct NeedsFullSlackDigestsMock: View {
    var tab = "digests"

    var body: some View {
        if let row = EmptyStateCopyTable.copy(for: tab, briefingHour: 8) {
            // `needsFullSlack` replaces the tab's own action (as `needsSource` does today).
            let copy = EmptyStateCopy(
                icon: row.icon, title: row.title, landsHere: row.landsHere, feature: row.feature, primaryAction: nil)
            FeatureEmptyState(
                copy: copy, readiness: nil, syncLine: nil, turnOnError: nil, isTurningOn: false,
                onAction: { _ in },
                extra: {
                    Text(Copy.needsFullLine).font(.callout).multilineTextAlignment(.center)
                    Button(Copy.needsFullAction) {}.buttonStyle(.kitPrimary)
                }
            )
            .detailBackground()
        }
    }
}

private struct NeedsFullSlackHomeCardMock: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            HStack(spacing: Spacing.regular) {
                Image(systemName: "doc.text.magnifyingglass").foregroundStyle(.secondary)
                Text("Digests").font(.headline)
            }
            Text(Copy.needsFullLine).font(.callout).fixedSize(horizontal: false, vertical: true)
            Button(Copy.needsFullAction) {}.buttonStyle(.kitSecondary)
        }
        .controlSize(.small)
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .padding(Spacing.large)
        .detailBackground()
    }
}

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
                Text(Copy.knowledgeNote)
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
