import AppKit
import DesignKit
import SwiftUI
import WatchtowerCore
@testable import WatchtowerDesktop

private typealias Copy = CompanySetupMockCopy

/// Design-only scenes for the company setup screens (#1887, spec
/// `docs/superpowers/specs/2026-11-18-company-setup-screens-design.md`).
/// Nothing here is wired into the app; the strings are
/// `CompanySetupMockCopy`. Sample data only (`Acme`, `example.com`, made-up ids).
@MainActor
enum CompanySetupShotFixtures {
    /// Connections overview frames (the Companies zone).
    enum Overview: String, CaseIterable {
        case companies, mdm, relogin, empty, loading, readFailed, codePaste, portBusy, setupInProgress
    }

    /// One narrow wizard frame per distinct step layout: the services checklist,
    /// the found/not-found choices, the Slack token form, a guide with a drop zone,
    /// a guide with fields (Atlassian, Linear, Microsoft share it), and Publish's
    /// values. Every other wizard step reuses one of these layouts.
    static let narrowWizardSteps = ["services", "slack-found", "slack-create", "google-create", "atlassian-create", "publish-done"]

    /// Every screen family with its narrow frame (the exact set the spec lists).
    static let narrowShots = narrowWizardSteps.map { "company-wizard-\($0)-narrow" } + [
        "company-connect-confirm-narrow", "company-overview-companies-narrow", "company-google-detail-narrow",
        "company-jira-detail-narrow", "company-ownGoogle-empty-narrow", "company-token-empty-narrow"
    ]

    static var shots: [DesignShot] {
        wizardShots + connectShots + pageShots + overviewShots + paneShots + sheetShots + policyShots
    }

    private static func shot(_ name: String, _ width: CGFloat, _ make: @escaping () -> some View) -> DesignShot {
        DesignShot(name: "company-\(name)", size: NSSize(width: width, height: 0)) { AnyView(make()) }
    }

    private static var wizardShots: [DesignShot] {
        // The production page (Task 22) over a model driven to each scene's state.
        let names = CompanyWizardScenes.scenes.map(\.name) + CompanyWizardLive.extraScenes
        var shots = names.map { name in shot("wizard-\(name)", 720) { CompanyWizardLive.page(name) } }
        for name in narrowWizardSteps where names.contains(name) {
            shots.append(shot("wizard-\(name)-narrow", 420) { CompanyWizardLive.page(name, narrow: true) })
        }
        return shots
    }

    /// The production sheet (Task 23) over a model held in each state.
    private static var connectShots: [DesignShot] {
        let scenes = CompanyConnectShots.scenes
        var shots = scenes.map { name, model in shot("connect-\(name)", 460) { CompanyConnectSheet(flow: model()) } }
        if let confirm = scenes.first(where: { $0.0 == "confirm" }) {
            shots.append(shot("connect-confirm-narrow", 360) { CompanyConnectSheet(flow: confirm.1()) })
        }
        return shots
    }

    /// The Go pages' texts, read from Go's fixture (`cmd/testdata/company/pages.json`).
    private static var pageShots: [DesignShot] {
        guard let pages = try? CompanyPagesFixture.load() else { return [] }
        return [
            shot("page-open", 560) {
                BrowserPageMock(icon: "arrow.up.forward.app", tone: Tone.success,
                                heading: pages.open.heading, message: pages.open.messageAcme ?? "")
            },
            shot("page-refused", 560) {
                BrowserPageMock(icon: "xmark.octagon", tone: Tone.error, heading: pages.refused.heading,
                                message: pages.refused.reasons?["damaged"] ?? "", hint: pages.refused.hint)
            },
            shot("page-newerVersion", 560) {
                BrowserPageMock(icon: "arrow.down.circle", tone: Tone.warning,
                                heading: pages.newer.heading, message: pages.newer.message ?? "")
            }
        ]
    }

    /// The production overview with its Companies zone (Task 25a).
    private static var overviewShots: [DesignShot] {
        Overview.allCases.map { frame in shot("overview-\(frame.rawValue)", 900) { CompaniesZoneScenes.overview(frame) } }
            + [shot("overview-companies-narrow", 420) { CompaniesZoneScenes.overview(.companies) }]
    }

    /// Slack, Linear and Outlook (Task 25a), Google and Jira (Task 25b)
    /// from the production sections and groups; the `-locked` and
    /// `-tokenError` frames stay mocks until Tasks 26 and 27.
    private static var paneShots: [DesignShot] {
        let details = CompanyDetailScenes.panes
        return CompaniesZoneScenes.panes.map { name, view in shot(name, 640) { view } }
            + details.map { name, view in shot(name, 640) { view } }
            + CompanyPaneScenes.scenes.map { name, sections in shot(name, 640) { MockPane(sections: sections) } }
            + ["google-detail", "jira-detail"].compactMap { name in
                details.first { $0.0 == name }.map { scene in shot("\(name)-narrow", 360) { scene.1 } }
            }
    }

    private static var sheetShots: [DesignShot] {
        let own = CompanySheetScenes.ownGoogle
        let token = CompanySheetScenes.token
        var shots = own.map { name, blocks in shot("ownGoogle-\(name)", 640) { MockPage(back: Copy.backToGoogle, blocks: blocks) } }
        shots += token.map { name, blocks in shot("token-\(name)", 520) { MockSheet(blocks: blocks) } }
        if let empty = own.first(where: { $0.0 == "empty" }) {
            shots.append(shot("ownGoogle-empty-narrow", 360) { MockPage(back: Copy.backToGoogle, blocks: empty.1) })
        }
        if let empty = token.first(where: { $0.0 == "empty" }) {
            shots.append(shot("token-empty-narrow", 380) { MockSheet(blocks: empty.1) })
        }
        return shots
    }

    private static var policyShots: [DesignShot] {
        [
            shot("policy-privacy", 640) { PolicyPrivacyMock() },
            shot("policy-blockedNotice", 640) { BlockedNoticeMock() }
        ]
    }
}

// MARK: - Detail panes left as mocks (Tasks 26 and 27)

/// The Google and Jira frames whose states later tasks build: the policy
/// locks (Tasks 26, 27) and the dead API token (Task 27). The rest of those
/// details renders production views (`CompanyDetailScenes`).
@MainActor
enum CompanyPaneScenes {
    private static func ok(_ title: String, tag: String? = nil) -> MockBlock {
        .account(MockAccount(title: title, status: Copy.syncing, tone: Tone.success, tag: tag))
    }

    private static func stopped(_ title: String, tag: String? = nil) -> MockBlock {
        .account(MockAccount(title: title, status: Copy.stoppedByPolicy, tone: Tone.status("gray"), tag: tag))
    }

    private static let lockBlocks: (String) -> [MockBlock] = { text in
        [.notice(MockNotice(icon: "lock.fill", tone: Tone.status("gray"), title: nil, body: text)),
         .buttons(leading: [MockButton(title: Copy.itGuideLink, kind: .quiet)], trailing: []),
         .managedBadge]
    }

    static var scenes: [(String, [MockPaneSection])] { googleScenes + jiraScenes }

    private static var googleScenes: [(String, [MockPaneSection])] {
        let acme = MockPaneSection(title: "Acme", caption: Copy.groupAcmeGoogle, blocks: [ok("alice@example.com")])
        let paste = MockButton(title: Copy.pasteCode, kind: .quiet)
        return [
            ("google-detail-locked", [
                acme,
                MockPaneSection(title: Copy.groupOwnGoogle, caption: Copy.groupOwnGoogleCaption,
                                blocks: [stopped("alice@example.net")] + lockBlocks(Copy.ownGoogleLocked)),
                MockPaneSection(title: Copy.addAccountTitle, blocks: [
                    .buttons(leading: [MockButton(title: Copy.connectCalendar), paste], trailing: [])
                ])
            ])
        ]
    }

    private static var jiraScenes: [(String, [MockPaneSection])] {
        let acme = MockPaneSection(title: "Acme", caption: Copy.groupAcmeAtlassian,
                                   blocks: [ok("alice@example.com · acme.atlassian.net")])
        let deadToken = MockPaneSection(
            title: Copy.groupTokens, caption: Copy.groupTokensCaption,
            blocks: [.account(MockAccount(title: "bob@example.com · beta.atlassian.net", status: Copy.tokenDead,
                                          tone: Tone.error, tag: Copy.tokenTag,
                                          button: MockButton(title: Copy.pasteNewToken, kind: .primary),
                                          note: Copy.tokenLease, statusIsProblem: true))])
        let add = MockPaneSection(title: Copy.addAccountTitle, blocks: [
            .buttons(leading: [MockButton(title: Copy.connectCompanyAtlassian), MockButton(title: Copy.connectTokenButton)],
                     trailing: [])
        ])
        return [
            ("jira-detail-tokenError", [acme, deadToken, add]),
            ("jira-detail-locked", [
                acme,
                MockPaneSection(title: Copy.groupTokens, caption: Copy.groupTokensCaption,
                                blocks: [stopped("bob@example.com · beta.atlassian.net", tag: Copy.tokenTag)]
                                    + lockBlocks(Copy.tokenLocked)),
                MockPaneSection(title: Copy.addAccountTitle, blocks: [
                    .buttons(leading: [MockButton(title: Copy.connectCompanyAtlassian)], trailing: [])
                ])
            ])
        ]
    }
}

// MARK: - Own Google project page and API token sheet

@MainActor
enum CompanySheetScenes {
    private static let ownHead = MockBlock.title(Copy.ownTitle, Copy.ownIntro)
    private static let ownGuide = MockBlock.guide(Copy.ownGuide, extras: [:])
    private static let ownFile = MockBlock.drop("client_secret_9876-home.json · project my-watchtower")

    private static func buttons(_ primary: String, disabled: Bool = false) -> MockBlock {
        .buttons(leading: [], trailing: [MockButton(title: Copy.cancel), MockButton(title: primary, kind: .primary, disabled: disabled)])
    }

    /// The own-project page has no Cancel: leaving it is the way back.
    private static func pageButton(_ primary: String, disabled: Bool = false) -> MockBlock {
        .buttons(leading: [], trailing: [MockButton(title: primary, kind: .primary, disabled: disabled)])
    }

    private static let doneButton = MockBlock.buttons(leading: [], trailing: [MockButton(title: Copy.done, kind: .primary)])

    static var ownGoogle: [(String, [MockBlock])] {
        [
            ("empty", [ownHead, ownGuide, .drop(nil), .caption(Copy.ownUnverifiedNote), pageButton(Copy.connect, disabled: true)]),
            ("ready", [ownHead, ownGuide, ownFile, .caption(Copy.ownUnverifiedNote), pageButton(Copy.connect)]),
            ("checking", [ownHead, ownGuide, ownFile, .busy(Copy.checkingGoogle), pageButton(Copy.connect, disabled: true)]),
            ("checkFailed", [ownHead, ownGuide, ownFile, .problem(Copy.googleRejected, nil), pageButton(Copy.tryAgain)]),
            ("done", [.title(Copy.ownTitle, nil), .success(Copy.ownDoneTitle, Copy.ownDoneBody), doneButton]),
            ("done-weekly", [.title(Copy.ownTitle, nil), .success(Copy.ownDoneTitle, Copy.ownDoneBody),
                             .caption(Copy.ownWeeklyNote), doneButton])
        ]
    }

    private static let tokenHead = MockBlock.title(Copy.tokenTitle, Copy.tokenIntro)
    private static let tokenStep1: [MockBlock] = [
        .body(Copy.tokenStep1),
        .caption(Copy.tokenStep1Help),
        .buttons(leading: [MockButton(title: Copy.openAtlassianTokens), MockButton(title: Copy.copyScopes, kind: .quiet)],
                 trailing: []),
        .body(Copy.tokenStep2)
    ]

    private static func fields(_ email: String, _ site: String, _ token: String, readOnly: Bool = false) -> MockBlock {
        .fields([MockField(label: Copy.atlassianEmail, value: email, readOnly: readOnly),
                 MockField(label: Copy.site, value: site, readOnly: readOnly),
                 MockField(label: Copy.apiToken, value: token, secure: true)], error: nil)
    }

    private static var filled: MockBlock { fields("alice@example.com", "acme.atlassian.net", "sample-token") }

    static var token: [(String, [MockBlock])] {
        let form = [tokenHead] + tokenStep1
        return [
            ("empty", form + [fields("", "", ""), .caption(Copy.scopedHint), buttons(Copy.connect, disabled: true)]),
            ("ready", form + [filled, .caption(Copy.scopedHint), buttons(Copy.connect)]),
            ("checking", form + [filled, .busy(Copy.tokenChecking), buttons(Copy.connect, disabled: true)]),
            ("unauthorized", form + [filled, .problem(Copy.tokenUnauthorized, nil), buttons(Copy.tryAgain)]),
            ("missingScope", form + [filled, .problem(Copy.tokenMissingScope, nil), buttons(Copy.tryAgain)]),
            ("notCloud", form + [fields("alice@example.com", "acme.example.com", "sample-token"),
                                 .problem(Copy.tokenNotCloud, nil), buttons(Copy.tryAgain)]),
            ("network", form + [filled, .problem(Copy.tokenNetwork, nil), buttons(Copy.tryAgain)]),
            ("done", [.title(Copy.tokenTitle, nil), .success(Copy.tokenDoneTitle, Copy.tokenDoneBody), doneButton]),
            ("replace", [.title(Copy.tokenReplaceTitle, Copy.tokenReplaceIntro)] + tokenStep1
                + [fields("bob@example.com", "beta.atlassian.net", "", readOnly: true), buttons(Copy.saveToken, disabled: true)])
        ]
    }
}

// MARK: - The MDM help link (D21)

/// Settings → Privacy → Organization policy with the new IT guide row. The
/// pane keeps its `Form` until it is ported; the rows and footer are these.
private struct PolicyPrivacyMock: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            SettingsSection(title: Copy.policyTitle, footer: Copy.policyFooter) {
                SettingRow(title: "Sources") { Text("Slack, Google, Jira").foregroundStyle(.secondary) }
                SettingRow(title: "Atlassian API tokens") { Text("Not allowed").foregroundStyle(.secondary) }
                SettingRow(title: "Own Google projects") { Text("Allowed").foregroundStyle(.secondary) }
                SettingRow(title: Copy.itGuideRow, caption: Copy.itGuideCaption) {
                    Button(Copy.itGuideLink) {}.buttonStyle(.kitQuiet)
                }
                ManagedByOrganizationBadge()
            }
        }
        .controlSize(.small)
        .padding(Spacing.page)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .detailBackground()
    }
}

/// `SourceBlockedNotice` on a blocked service's detail, with the IT guide link.
private struct BlockedNoticeMock: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Label(Copy.blockedTitle, systemImage: "lock.fill").font(.callout.weight(.medium))
            Text(Copy.blockedBody).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button(Copy.itGuideLink) {}.buttonStyle(.kitQuiet)
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .padding(Spacing.page)
        .detailBackground()
    }
}
