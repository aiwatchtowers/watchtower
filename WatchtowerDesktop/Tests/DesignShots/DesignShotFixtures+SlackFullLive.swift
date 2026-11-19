import AppKit
import DesignKit
import GRDB
import SwiftUI
import WatchtowerCore
@testable import WatchtowerDesktop
import WatchtowerTestSupport

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
        case setupPending
    }

    /// The Set up for my company sheet and the Add the link sheet.
    enum Setup: String, CaseIterable {
        case empty, ready, progress, success, badToken, notAllowed, linkFailed, approval
        case addLinkEmpty, addLinkBusy, addLinkError, addLinkDone
        case adopt, adoptAppId, adoptNotCollaborator
        case pendingCreate, pendingConfirmClear, adoptConfirm, adoptAppIdProblem, busy
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
                AnyView(SlackSetupShotFixture.sheet(frame))
            }
        } + [
            DesignShot(name: "slack-fl-setup-ready-narrow", size: NSSize(width: 380, height: 0)) {
                AnyView(SlackSetupShotFixture.sheet(.ready))
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
            DesignShot(name: "slack-fl-needs-full-home-card", size: NSSize(width: 640, height: 0)) {
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
    @FocusState private var fieldFocused: Bool

    private var hasAccount: Bool {
        [.full, .fullLive, .loading, .checking, .probeFailed, .readFailed, .sharedApp].contains(pane)
    }

    private var showsConnect: Bool { !hasAccount || pane == .sharedApp }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            if let banner = SlackPaneModeFixture.presentation(pane).sharedAppBanner {
                // The real banner (`SlackSharedAppBanner`, screens spec §5).
                SlackSharedAppBanner(banner: banner, setUpForCompany: {}, pasteLink: {})
            }
            modeSection
            SlackSetupRecordRows(model: SlackSetupShotFixture.rowsModel(pane))
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

    /// The section after retirement: the build has no Slack app (`builtin_app`
    /// false), so **Connect another workspace…** replaces Add (A8).
    private var section: SlackModePresentation.ConnectSection {
        SlackModePresentation.ConnectSection(
            display: SlackPaneModeFixture.presentation(pane).display,
            portBusy: pane == .portBusy,
            expanded: false,
            organizationApps: pane == .organization ? [ManagedPolicy.SlackApp(teamID: "T0ACME", clientID: "1111.2222")] : nil,
            accounts: [],
            builtinApp: false)
    }

    /// The real connect section (`SlackConnectSection`) on fixture data.
    private var connectSection: some View {
        SlackConnectSection(
            section: section,
            flow: SlackConnectShotFlow.make(paste: pane == .pasteInvalid ? "https://acme.slack.com/apps/A0ACME" : nil),
            setUpForCompany: {},
            fieldFocused: $fieldFocused)
    }

    /// The real row title (`SlackAccountTitle`: tag and shared-app line) and
    /// the real add row (`SlackWorkspacesAddRow`); the row's switch and
    /// buttons are the shipped ones, left out here.
    private var workspaces: some View {
        SettingsSection(title: "Slack Workspaces") {
            HStack {
                SlackAccountTitle(
                    account: SlackPaneModeFixture.acme,
                    sharedAppAccountIDs: pane == .sharedApp ? [1] : [],
                    lastSync: SlackPaneModeFixture.now.addingTimeInterval(-180),
                    now: SlackPaneModeFixture.now)
                Spacer()
                Circle().fill(Tone.success).frame(width: IconSize.stateDot, height: IconSize.stateDot)
            }
            SlackWorkspacesAddRow(section: section, add: {}, openFold: {})
        }
    }
}

// MARK: - Set up for my company / Add the link (the real sheet, plan B Task 13)

/// `SlackAppSetupModel` in each frame's state, for the real
/// `SlackAppSetupSheet` and `SlackSetupRecordRows`.
@MainActor
enum SlackSetupShotFixture {
    typealias Model = SlackAppSetupModel
    static let token = "xoxe.xoxp-1-sample-token"
    static let acme = SlackSetupTarget(teamID: "T0ACME", teamName: "acme", appID: "A0ACME", clientID: "1111.2222",
                                       linkWritten: true)

    static func sheet(_ frame: SlackFullLiveShotFixtures.Setup) -> some View {
        let empty = frame == .empty || frame == .addLinkEmpty
        return SlackAppSetupSheet(model: model(frame), token: empty ? "" : token)
    }

    static func model(_ frame: SlackFullLiveShotFixtures.Setup) -> Model {
        let link = Model.Form.addLink(acme)
        let adopt = Model.Adopt(target: acme)
        var needsID = adopt
        needsID.needsAppID = true
        return switch frame {
        case .empty, .ready: Model(streamer: nil)
        case .progress: Model(streamer: nil, phase: .running, steps: progressSteps)
        case .success: Model(streamer: nil, phase: .finished(.success(acme)))
        case .badToken: Model(streamer: nil, phase: .finished(.problem(.badToken)))
        case .notAllowed: Model(streamer: nil, phase: .finished(.problem(.notAllowed(workspace: "acme"))))
        case .linkFailed: Model(streamer: nil, phase: .finished(.linkFailed(acme)))
        case .approval: Model(streamer: nil, phase: .finished(.approval(acme)))
        case .addLinkEmpty: Model(streamer: nil, form: link)
        case .addLinkBusy: Model(streamer: nil, form: link, phase: .running)
        case .addLinkError: Model(streamer: nil, form: link, phase: .finished(.problem(.badToken)))
        case .addLinkDone: Model(streamer: nil, form: link, phase: .finished(.linkDone))
        case .adopt: Model(streamer: nil, form: .adopt(adopt))
        case .adoptAppId: Model(streamer: nil, form: .adopt(needsID))
        case .adoptNotCollaborator:
            Model(streamer: nil, form: .adopt(adopt), phase: .finished(.problem(.notCollaborator(workspace: "acme"))))
        case .pendingCreate, .pendingConfirmClear, .adoptConfirm, .adoptAppIdProblem, .busy: reviewModel(frame, adopt: needsID)
        }
    }

    /// The states added after the plan B Task 13 review.
    private static func reviewModel(_ frame: SlackFullLiveShotFixtures.Setup, adopt: Model.Adopt) -> Model {
        var confirm = adopt
        confirm.confirm = ("A0ACME", "Watchtower")
        var problem = adopt
        problem.appIDProblem = .format
        let pending = Model.Form.pending(SlackSetupTarget(teamID: "T0ACME", teamName: "acme"))
        if frame == .pendingConfirmClear {
            let model = Model(streamer: nil, form: pending)
            model.clearPending() // the first press asks to check Slack's app page first
            return model
        }
        return switch frame {
        case .pendingCreate: Model(streamer: nil, form: pending)
        case .adoptConfirm: Model(streamer: nil, form: .adopt(confirm))
        case .adoptAppIdProblem: Model(streamer: nil, form: .adopt(problem))
        default: Model(streamer: nil, phase: .finished(.problem(.busy)))
        }
    }

    private static var progressSteps: [Model.StepLine] {
        let marks: [Model.StepMark] = [.done, .done, .running, .waiting]
        return zip(Model.createSteps, marks).map { line, mark in
            var line = line
            line.mark = mark
            return line
        }
    }

    /// The pane's unfinished-setup row for the record frames, none otherwise.
    static func rowsModel(_ pane: SlackFullLiveShotFixtures.Pane) -> Model {
        let stage: String? = switch pane {
        case .setupInstall: "install"
        case .setupApproval: "approval"
        case .linkMissing: "link_missing"
        case .setupPending: "pending_create"
        default: nil
        }
        let records = stage.map { stage in
            [SlackSetupRecord(teamID: "T0ACME", teamName: "acme", appID: "A0ACME", clientID: "1111.2222",
                              connected: stage == "link_missing", linkWritten: stage != "link_missing",
                              installRequested: stage == "approval", stage: stage)]
        } ?? []
        return Model(streamer: nil, records: records)
    }
}

// MARK: - Onboarding: connect Slack without a build-baked app (plan B, A13)

/// The real onboarding sheet (`SlackOnboardingConnectSheet`) for each frame.
private struct SlackOnboardingConnectMock: View {
    let frame: SlackFullLiveShotFixtures.Onboarding

    var body: some View {
        SlackOnboardingConnectSheet(
            section: SlackModePresentation.ConnectSection(
                display: .off,
                portBusy: frame == .portBusy,
                expanded: true,
                organizationApps: frame == .organization
                    ? [ManagedPolicy.SlackApp(teamID: "T0ACME", clientID: "1111.2222")] : nil,
                accounts: [],
                builtinApp: false),
            flow: SlackConnectShotFlow.make(paste: frame == .pasteInvalid ? "https://acme.slack.com/apps/A0ACME" : nil),
            setUpForCompany: {},
            close: {})
    }
}

// MARK: - Connect from a link or code

/// The real connect sheet (`SlackConnectSheet`) for one step of the flow.
private struct SlackConnectSheetMock: View {
    let frame: SlackFullLiveShotFixtures.Connect

    private var step: SlackConnectFlowModel.Step {
        let target = SlackConnectTarget(teamID: "T0ACME", clientID: "1111.2222")
        return switch frame {
        case .confirm: .confirming(flow: "f1", target: target)
        case .browser: .browser(flow: "f1", target: target, since: SlackPaneModeFixture.now)
        case .success: .connected(workspace: "acme")
        case .teamMismatch: .failed(.teamMismatch, retry: target)
        case .denied: .failed(.denied, retry: target)
        }
    }

    var body: some View {
        if let content = SlackConnectSheetContent(step: step) {
            SlackConnectSheet(content: content) { _ in }
        }
    }
}

/// A connect flow for the shots: its host runs no child (a fake streamer),
/// so nothing starts; `paste` leaves that text refused in the field.
@MainActor
private enum SlackConnectShotFlow {
    static func make(paste: String?) -> SlackConnectFlowModel {
        let flow = SlackConnectFlowModel(host: SlackConnectListenerHost(streamer: FakeCLILineStream()))
        if let paste {
            flow.pasteText = paste
            flow.connectPasted()
        }
        return flow
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

/// The real Home → Getting ready zone with Slack Live only: one grouped row
/// (owner, ask #1572).
private struct NeedsFullSlackHomeCardMock: View {
    var body: some View {
        GettingReadyZoneView(
            zone: .shown(cards: [], sourceRows: [
                GettingReadySourceRow(
                    source: .fullSlack, features: [.slackSync, .digests, .tracks, .peopleCards, .ideas, .inbox])
            ]),
            firstSync: nil,
            onLink: { _ in },
            onHide: {}
        )
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

    static let acme = SlackAccount(row: Row([
        "id": 1, "team_id": "T0ACME", "team_name": "acme", "status": "ok", "enabled": true
    ]))

    static func presentation(_ pane: SlackFullLiveShotFixtures.Pane) -> SlackModePresentation {
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
