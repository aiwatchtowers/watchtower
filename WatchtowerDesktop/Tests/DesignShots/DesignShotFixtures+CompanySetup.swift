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
        /// The code field's "No code?" block with a workspace, a foreign host
        /// and an Enterprise Grid organization address typed in.
        case slackValid, slackInvalid, slackOrganization
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

    /// Slack, Linear and Outlook (Task 25a), Google and Jira (Tasks 25b, 26,
    /// 27) from the production sections and groups.
    private static var paneShots: [DesignShot] {
        let details = CompanyDetailScenes.panes
        return CompaniesZoneScenes.panes.map { name, view in shot(name, 640) { view } }
            + details.map { name, view in shot(name, 640) { view } }
            + ["google-detail", "jira-detail"].compactMap { name in
                details.first { $0.0 == name }.map { scene in shot("\(name)-narrow", 360) { scene.1 } }
            }
    }

    /// The own Google project page (Task 26) and the API token sheet (Task
    /// 27), both production.
    private static var sheetShots: [DesignShot] {
        let token = CompanyTokenShots.scenes
        var shots = OwnGoogleLive.scenes.map { name in shot("ownGoogle-\(name)", 640) { OwnGoogleLive.page(name) } }
        shots.append(shot("ownGoogle-empty-narrow", 360) { OwnGoogleLive.page("empty") })
        shots += token.map { name, model in shot("token-\(name)", 520) { AtlassianTokenSheet(model: model()) } }
        if let empty = token.first(where: { $0.0 == "empty" }) {
            shots.append(shot("token-empty-narrow", 380) { AtlassianTokenSheet(model: empty.1()) })
        }
        return shots + gmailShots
    }

    /// Gmail off the shared Google app (D11): the Add Google Account sheet on
    /// the public build (Gmail off, the note; and under the own-project
    /// lock), and Email's Add Account sheet whose Gmail card leaves for
    /// Connections → Google. Production views.
    private static var gmailShots: [DesignShot] {
        [
            shot("googleSheet-shared", 480) { AddGoogleAccountView(offersGmail: false).environment(AppState.isolated()) },
            shot("googleSheet-shared-locked", 480) {
                AddGoogleAccountView(offersGmail: false).environment(lockedOwnProject())
            },
            shot("emailSheet-gmail", 480) { AddEmailAccountView().environment(AppState.isolated()) }
        ]
    }

    private static func lockedOwnProject() -> AppState {
        let appState = AppState.isolated(managedPolicy: ["AllowOwnGoogleProject": false])
        appState.managedPolicy.refresh()
        return appState
    }

    private static var policyShots: [DesignShot] {
        [
            shot("policy-privacy", 640) { PolicyPrivacyMock() },
            shot("policy-blockedNotice", 640) { BlockedNoticeMock() }
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
