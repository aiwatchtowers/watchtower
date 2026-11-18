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

    static var shots: [DesignShot] {
        wizardShots + connectShots + pageShots + overviewShots + paneShots + sheetShots + policyShots
    }

    private static func shot(_ name: String, _ width: CGFloat, _ make: @escaping () -> some View) -> DesignShot {
        DesignShot(name: "company-\(name)", size: NSSize(width: width, height: 0)) { AnyView(make()) }
    }

    private static var wizardShots: [DesignShot] {
        let scenes = CompanyWizardScenes.scenes
        var shots = scenes.map { scene in shot("wizard-\(scene.name)", 720) { CompanyWizardMock(scene: scene) } }
        for name in ["services", "google-create", "publish-done"] {
            if let scene = scenes.first(where: { $0.name == name }) {
                shots.append(shot("wizard-\(name)-narrow", 420) { CompanyWizardMock(scene: scene, narrow: true) })
            }
        }
        return shots
    }

    private static var connectShots: [DesignShot] {
        let scenes = CompanyConnectScenes.scenes
        var shots = scenes.map { name, blocks in shot("connect-\(name)", 460) { MockSheet(blocks: blocks) } }
        if let confirm = scenes.first(where: { $0.0 == "confirm" }) {
            shots.append(shot("connect-confirm-narrow", 360) { MockSheet(blocks: confirm.1) })
        }
        return shots
    }

    private static var pageShots: [DesignShot] {
        [
            shot("page-open", 560) {
                BrowserPageMock(icon: "arrow.up.forward.app", tone: Tone.success,
                                heading: Copy.pageOpenHeading, message: Copy.pageOpenBody)
            },
            shot("page-refused", 560) {
                BrowserPageMock(icon: "xmark.octagon", tone: Tone.error, heading: Copy.pageRefusedHeading,
                                message: Copy.pageRefusedBody, hint: Copy.pageRefusedHint)
            },
            shot("page-newerVersion", 560) {
                BrowserPageMock(icon: "arrow.down.circle", tone: Tone.warning,
                                heading: Copy.pageNewerHeading, message: Copy.pageNewerBody)
            }
        ]
    }

    private static var overviewShots: [DesignShot] {
        Overview.allCases.map { frame in shot("overview-\(frame.rawValue)", 900) { CompanyOverviewMock(frame: frame) } }
            + [shot("overview-companies-narrow", 420) { CompanyOverviewMock(frame: .companies) }]
    }

    private static var paneShots: [DesignShot] {
        CompanyPaneScenes.scenes.map { name, sections in shot(name, 640) { MockPane(sections: sections) } }
            + ["google-detail", "jira-detail"].compactMap { name in
                CompanyPaneScenes.scenes.first { $0.0 == name }.map { scene in
                    shot("\(name)-narrow", 360) { MockPane(sections: scene.1) }
                }
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

// MARK: - Connections overview: the Companies zone

private struct CompanyOverviewMock: View {
    let frame: CompanySetupShotFixtures.Overview

    private static let columns = [GridItem(.adaptive(minimum: PaneWidth.gridCardMin), spacing: Spacing.medium, alignment: .top)]

    private var summaries: [ConnectionSummary] {
        let jiraState = frame == .relogin
            ? ConnectionAccountState(name: "acme.atlassian.net", isOK: false, status: "error", error: Copy.reloginChanged)
            : ConnectionAccountState(name: "acme.atlassian.net", isOK: true, status: "ok", error: "")
        return [
            ConnectionSummary(service: .slack, accounts: [
                ConnectionAccountState(name: "acme", isOK: true, status: "ok", error: "")
            ], blocked: false),
            ConnectionSummary(service: .google, accounts: [], blocked: false),
            ConnectionSummary(service: .jira, accounts: [jiraState], blocked: false)
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            HStack {
                Text(Copy.connectionsTitle).font(.title2.weight(.bold))
                Spacer()
                Button {} label: { Label(Copy.connectMenu, systemImage: "plus") }.buttonStyle(.kitSecondary)
            }
            ForEach(summaries.filter(\.needsAttention)) { summary in
                ConnectionAttentionBanner(summary: summary) {}
            }
            VStack(alignment: .leading, spacing: Spacing.regular) {
                HomeZoneTitle(title: Copy.companiesTitle)
                companies
            }
            VStack(alignment: .leading, spacing: Spacing.regular) {
                HomeZoneTitle(title: Copy.sourcesTitle)
                LazyVGrid(columns: Self.columns, alignment: .leading, spacing: Spacing.medium) {
                    ForEach(summaries) { summary in ConnectionCard(summary: summary) {} }
                }
            }
        }
        .controlSize(.small)
        .padding(Spacing.page)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .detailBackground()
    }

    @ViewBuilder private var companies: some View {
        switch frame {
        case .loading:
            MockBlockView(block: .busy(Copy.companiesLoading))
        case .readFailed:
            MockBlockView(block: .problem(Copy.companiesReadFailed, MockButton(title: Copy.tryAgain)))
        case .empty:
            MockBlockView(block: .caption(Copy.companiesEmpty))
            zoneButtons
        case .mdm:
            companyCard(managed: true, line: Copy.companyMDMLine, problem: nil,
                        button: MockButton(title: Copy.connectAll, kind: .primary))
            zoneButtons
        case .relogin:
            companyCard(managed: false, line: Copy.companyCount, problem: Copy.companyRelogin,
                        button: MockButton(title: Copy.relogin))
            zoneButtons
        case .setupInProgress:
            setupRow
            companyCard(managed: false, line: Copy.companyCount, problem: nil, button: MockButton(title: Copy.connectRest))
            zoneButtons
        case .companies, .codePaste, .portBusy:
            companyCard(managed: false, line: Copy.companyCount, problem: nil, button: MockButton(title: Copy.connectRest))
            if frame == .companies { zoneButtons } else { codeField }
        }
    }

    private func companyCard(managed: Bool, line: String, problem: String?, button: MockButton) -> some View {
        HStack(alignment: .top, spacing: Spacing.regular) {
            Image(systemName: "building.2").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: Spacing.small) {
                Text("Acme").font(.headline)
                if managed { ManagedByOrganizationBadge() }
                Text(line).font(.caption).foregroundStyle(.secondary)
                Text(problem ?? Copy.companyMissing)
                    .font(.caption)
                    .foregroundStyle(problem == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Tone.error))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Spacing.regular)
            MockButtonView(button: button)
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var setupRow: some View {
        HStack(spacing: Spacing.regular) {
            Image(systemName: "wrench.and.screwdriver").foregroundStyle(Tone.warning)
            Text(Copy.setupInProgress).font(.callout)
            Spacer(minLength: Spacing.regular)
            Button(Copy.continueSetup) {}.buttonStyle(.kitPrimary)
        }
        .padding(Spacing.medium)
        .card()
    }

    private var zoneButtons: some View {
        HStack(spacing: Spacing.regular) {
            Button(Copy.setUpForCompany) {}.buttonStyle(.kitQuiet)
            Button(Copy.connectWithCode) {}.buttonStyle(.kitQuiet)
        }
    }

    private var codeField: some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            if frame == .portBusy { MockBlockView(block: .problem(Copy.portBusy, nil)) }
            HStack(spacing: Spacing.regular) {
                TextField(Copy.codePlaceholder, text: .constant(frame == .codePaste ? "acme-onboarding-2026" : ""))
                    .textFieldStyle(.kit)
                Button(Copy.connect) {}.buttonStyle(.kitSecondary).disabled(frame != .codePaste)
            }
            if frame == .codePaste {
                Text(Copy.codeInvalid).font(.caption).foregroundStyle(Tone.error).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Detail panes grouped by company

@MainActor
enum CompanyPaneScenes {
    private static func ok(_ title: String, _ status: String = Copy.syncing, tag: String? = nil) -> MockBlock {
        .account(MockAccount(title: title, status: status, tone: Tone.success, tag: tag))
    }

    private static func notConnected(_ title: String) -> MockBlock {
        .account(MockAccount(title: title, status: Copy.rowNotConnected, tone: Tone.status("gray"),
                             button: MockButton(title: Copy.connect)))
    }

    private static func stopped(_ title: String, tag: String? = nil) -> MockBlock {
        .account(MockAccount(title: title, status: Copy.stoppedByPolicy, tone: Tone.status("gray"), tag: tag))
    }

    private static func problem(
        _ title: String,
        _ status: String,
        _ button: MockButton,
        note: String? = nil,
        tag: String? = nil
    ) -> MockBlock {
        .account(MockAccount(title: title, status: status, tone: Tone.error, tag: tag, button: button, note: note,
                             statusIsProblem: true))
    }

    private static let lockBlocks: (String) -> [MockBlock] = { text in
        [.notice(MockNotice(icon: "lock.fill", tone: Tone.status("gray"), title: nil, body: text)),
         .buttons(leading: [MockButton(title: Copy.itGuideLink, kind: .quiet)], trailing: []),
         .managedBadge]
    }

    private static let googleBanner = MockPaneSection(
        title: Copy.googleBannerTitle, style: .banner,
        blocks: [.body(Copy.googleBannerBody),
                 .buttons(leading: [MockButton(title: Copy.useOwnGoogle), MockButton(title: Copy.pasteCode, kind: .quiet)],
                          trailing: [])])

    private static let atlassianBanner = MockPaneSection(
        title: Copy.atlassianBannerTitle, style: .banner,
        blocks: [.body(Copy.atlassianBannerBody),
                 .buttons(leading: [MockButton(title: Copy.setUpForCompany),
                                    MockButton(title: Copy.connectTokenButton, kind: .quiet)], trailing: [])])

    static var scenes: [(String, [MockPaneSection])] { googleScenes + jiraScenes + otherScenes }

    private static var googleScenes: [(String, [MockPaneSection])] {
        let acme = MockPaneSection(title: "Acme", caption: Copy.groupAcmeGoogle,
                                   blocks: [ok("alice@example.com")])
        let own = MockPaneSection(title: Copy.groupOwnGoogle, caption: Copy.groupOwnGoogleCaption,
                                  blocks: [ok("alice@example.net")])
        let shared = MockPaneSection(title: Copy.groupShared, caption: Copy.groupSharedGoogleCaption,
                                     blocks: [ok("bob@example.org", Copy.sharedSyncing, tag: Copy.sharedTag)])
        let add = MockPaneSection(title: Copy.addAccountTitle, blocks: [
            .buttons(leading: [MockButton(title: Copy.connectCalendar), MockButton(title: Copy.useOwnGoogle),
                               MockButton(title: Copy.pasteCode, kind: .quiet)], trailing: [])
        ])
        let relogin = MockButton(title: Copy.relogin, kind: .primary)
        let paste = MockButton(title: Copy.pasteCode, kind: .quiet)
        return [
            ("google-detail", [googleBanner, acme, own, shared, add]),
            ("google-detail-relogin", [
                MockPaneSection(title: "Acme", caption: Copy.groupAcmeGoogle, blocks: [
                    problem("alice@example.com", Copy.reloginChanged, relogin),
                    problem("dave@example.com", Copy.reloginNewLink, paste)
                ]),
                MockPaneSection(title: Copy.groupUnknown, caption: Copy.groupUnknownCaption, blocks: [
                    problem("erin@example.com", Copy.reloginUntied, MockButton(title: Copy.pasteCode))
                ])
            ]),
            ("google-detail-empty", [MockPaneSection(title: Copy.googleTitle, blocks: [
                .body(Copy.googleEmpty),
                .buttons(leading: [MockButton(title: Copy.connectCalendar, kind: .primary),
                                   MockButton(title: Copy.useOwnGoogle), paste], trailing: [])
            ])]),
            ("google-detail-loading", [MockPaneSection(title: Copy.accountsTitle, blocks: [.busy(Copy.googleLoading)])]),
            ("google-detail-readFailed", [MockPaneSection(title: Copy.accountsTitle, blocks: [
                .problem(Copy.googleReadFailed, MockButton(title: Copy.tryAgain))
            ])]),
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
        let tokens = MockPaneSection(title: Copy.groupTokens, caption: Copy.groupTokensCaption,
                                     blocks: [ok("bob@example.com · beta.atlassian.net", tag: Copy.tokenTag)])
        let shared = MockPaneSection(title: Copy.groupShared, blocks: [ok("old.atlassian.net", Copy.sharedSyncing, tag: Copy.sharedTag)])
        let deadToken = MockPaneSection(
            title: Copy.groupTokens, caption: Copy.groupTokensCaption,
            blocks: [problem("bob@example.com · beta.atlassian.net", Copy.tokenDead,
                             MockButton(title: Copy.pasteNewToken, kind: .primary), note: Copy.tokenLease, tag: Copy.tokenTag)])
        let add = MockPaneSection(title: Copy.addAccountTitle, blocks: [
            .buttons(leading: [MockButton(title: Copy.connectCompanyAtlassian), MockButton(title: Copy.connectTokenButton)],
                     trailing: [])
        ])
        return [
            ("jira-detail", [atlassianBanner, acme, tokens, shared, add]),
            ("jira-detail-tokenError", [acme, deadToken, add]),
            ("jira-detail-empty", [MockPaneSection(title: Copy.jiraTitle, blocks: [
                .body(Copy.jiraEmpty),
                .buttons(leading: [MockButton(title: Copy.connectTokenButton, kind: .primary),
                                   MockButton(title: Copy.pasteCode, kind: .quiet)], trailing: [])
            ])]),
            ("jira-detail-loading", [MockPaneSection(title: Copy.accountsTitle, blocks: [.busy(Copy.jiraLoading)])]),
            ("jira-detail-readFailed", [MockPaneSection(title: Copy.accountsTitle, blocks: [
                .problem(Copy.jiraReadFailed, MockButton(title: Copy.tryAgain))
            ])]),
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

    private static var otherScenes: [(String, [MockPaneSection])] {
        [
            ("slack-workspaces", [
                MockPaneSection(title: "Acme", caption: Copy.groupAcmeSlack, blocks: [ok("acme")]),
                MockPaneSection(title: Copy.groupUnknown, caption: Copy.groupUnknownCaption, blocks: [
                    problem("acme-labs", Copy.reloginUntied, MockButton(title: Copy.pasteCode))
                ])
            ]),
            ("linear-detail", [
                MockPaneSection(title: "Acme", caption: Copy.groupAcmeLinear, blocks: [notConnected("Linear")]),
                MockPaneSection(title: Copy.groupSharedLinear, blocks: [ok("Side project")])
            ]),
            ("outlook-detail", [
                MockPaneSection(title: "Acme", caption: Copy.groupAcmeMicrosoft, blocks: [ok("alice@example.com")]),
                MockPaneSection(title: Copy.groupSharedMicrosoft, blocks: [ok("alice@example.org")])
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
