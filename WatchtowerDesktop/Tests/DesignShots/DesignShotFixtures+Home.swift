import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// Home on fixed sample data (#717): every zone filled — a feed with each
/// row kind, a read row and a failed Done, the meeting in progress, later
/// today and tomorrow; two workbenches with sessions, an ask and the
/// instruction suggestion; the links; today in numbers. The clock and the
/// zone are fixed (Monday 2026-10-19 10:40 UTC), so the times never move.
@MainActor
enum HomeShotFixtures {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }()

    private static let now = Date(timeIntervalSince1970: 1_792_406_400) // 2026-10-19 10:40 UTC

    /// `gettingReady`: a first run still preparing, as on a new install.
    static func home(gettingReady: Bool = false, purges: [AccountPurge] = [], learn: LearnSelection? = nil) -> AnyView {
        do {
            return AnyView(HomeContent(
                snapshot: try snapshot(gettingReady: gettingReady ? Self.gettingReady : .hidden),
                today: now, calendar: calendar,
                feedErrors: [.target(4): "The database is locked."],
                onLink: { _ in }, onHideGettingReady: {}, purges: purges, learn: learn,
                aiSpend: HomeAISpend(value: "≥ $6.40", tooltip: LLMUsagePresentation.homeAISpendTooltip)))
        } catch {
            XCTFail("home shot fixture failed: \(error)")
            return AnyView(Text("fixture failed: \(String(describing: error))").foregroundStyle(.red))
        }
    }

    /// Five features ready, five still preparing, one failed, and Jira to connect.
    private static let gettingReady: GettingReadyZone = {
        func card(_ feature: ReadinessFeature, _ title: String, _ readiness: Readiness) -> GettingReadyCard {
            GettingReadyCard(
                feature: feature, copy: FeatureCardCopy(title: title, whatItIs: "\(title) sentence."),
                readiness: readiness)
        }
        let cards = [
            card(.slackSync, "Slack sync", .scheduled(.nextCycle(minutes: 15))),
            card(.digests, "Digests", .preparing(detail: "Messages · 3/10 channels")),
            card(.streamDigests, "Stream digests", .scheduled(.inHours(5))),
            card(.tracks, "Tracks", .scheduled(.nextCycle(minutes: 15))),
            card(.peopleCards, "People cards", .scheduled(.nextCycle(minutes: 15))),
            card(.briefing, "Briefing", .ready),
            card(.dayPlan, "Day plan", .ready),
            card(.ideas, "Ideas", .ready),
            card(.inbox, "Inbox", .ready),
            card(.knowledgeIndex, "Knowledge search", .ready),
            card(.calendar, "Calendar", .error(message: "Calendar API returned 403: the token lacks the calendar.readonly scope"))
        ]
        return .shown(cards: cards, sourceRows: [GettingReadySourceRow(source: .jira, features: [.jira])])
    }()

    private static func snapshot(gettingReady: GettingReadyZone) throws -> HomeSnapshot {
        let asks = try TestDatabase.create().write { db in
            let acme = try TestDatabase.insertWorkbench(db, name: "acme", folder: "/tmp/acme")
            XCTAssertEqual(acme, 1, "the sessions' workbench")
            let api = try TestDatabase.insertWorkbench(db, name: "acme-api", folder: "/tmp/acme-api")
            try TestDatabase.insertOwnerAsk(db, projectID: api, kind: "question", title: "Which date format for the export?")
            return try OwnerAskQueries.openAsksAllWorkbenches(db)
        }
        let sessions = [
            session(1, "Fix the login redirect", .working),
            session(2, "Export invoices to CSV", .needsApproval),
            session(3, "Rate limiter for the API", .readyToCheck)
        ]
        var numbers = HomeNumbers()
        numbers.messagesToMe = 38
        numbers.messagesSent = 12
        numbers.meetings = 4
        numbers.meetingHours = 3.5
        numbers.plan5h = 41
        numbers.planWeek = 63
        numbers.workbenchCreated = 5
        numbers.workbenchDone = 3
        numbers.meetingsRecorded = 1
        return HomeSnapshot(
            gettingReady: gettingReady, firstSync: nil, feed: feed(),
            workbench: HomeWorkbenchBuilder.blocks(sessions: sessions, asks: asks),
            suggestion: HomeInstructionSuggestion(id: 5, text: "run the linter before committing"),
            links: [
                HomeLinkRow(kind: .briefing, title: "Briefing", status: "ready 08:12", highlighted: false,
                            link: .briefing(id: 7)),
                HomeLinkRow(kind: .catchUp, title: "Catch-Up", status: "new recap", highlighted: true, link: .catchUp),
                HomeLinkRow(kind: .dayPlan, title: "Day plan", status: "2 of 6 done", highlighted: false,
                            link: .feature(.dayPlan)),
                HomeLinkRow(kind: .digests, title: "Digests", status: nil, highlighted: false, link: .feature(.digests))
            ],
            numbers: numbers)
    }

    private static func session(
        _ id: Int64, _ title: String, _ kind: SessionSwitcherPresentation.State.Kind
    ) -> SessionAgentStatus {
        SessionAgentStatus(
            sessionID: id, workbenchID: 1, workbenchName: "acme", title: title,
            state: SessionSwitcherPresentation.State(kind: kind, live: true), at: nil)
    }

    private static func feed() -> HomeFeed {
        let link = HomeLink.permalink(URL(string: "https://acme.example.com/p/1") ?? URL(fileURLWithPath: "/"))
        func row(
            _ ref: FeedRef,
            _ kind: FeedKind,
            _ chip: String,
            _ who: String,
            _ whereText: String?,
            _ text: String,
            minutesAgo: Double,
            read: Bool = false,
            actions: Set<FeedAction> = [.done, .hide]
        ) -> FeedRow {
            FeedRow(id: ref, kind: kind, chip: chip, who: who, whereText: whereText, text: text,
                    stamp: now.addingTimeInterval(-minutesAgo * 60), read: read, actions: actions, link: link)
        }
        func event(
            _ id: String,
            _ title: String,
            minutes: Double,
            length: Double = 30,
            chip: String = "Meeting",
            prep: Bool = false,
            isNext: Bool = false,
            ongoing: Bool = false
        ) -> FeedEvent {
            let start = now.addingTimeInterval(minutes * 60)
            return FeedEvent(id: .event(id), start: start, end: start.addingTimeInterval(length * 60), title: title,
                             chip: chip, prepReady: prep, isNext: isNext, isOngoing: ongoing,
                             link: .calendarEvent(id: id))
        }
        let waiting = [
            row(.inbox(1), .slack, "Mention", "Ann", "#billing", "Can you look at the acme invoice totals?", minutesAgo: 12),
            row(.inbox(2), .slack, "DM", "Bob", nil, "Is the export ready for the review?", minutesAgo: 95, read: true),
            row(.inbox(3), .jira, "Jira", "ACME-142", "assigned to you", "Invoice PDF layout breaks on long names",
                minutesAgo: 180),
            row(.proposal(9), .proposal, "Proposal", "Reply to Ann in #billing", nil,
                "Drafted by the assistant \u{00B7} review in Inbox", minutesAgo: 30, actions: []),
            row(.output(7), .automation, "Automation", "Two threads need you", "Mail summary",
                "Ann and Bob wait on a reply about the acme export.", minutesAgo: 45),
            row(.target(4), .target, "Overdue", "Send the Q4 plan to Bob", nil, "My target", minutesAgo: 1500),
            row(.inbox(5), .email, "Email", "billing@example.com", "Invoice #2041", "Your invoice is ready",
                minutesAgo: 240)
        ]
        return HomeFeed(
            waiting: waiting, hiddenWaiting: 2, nowLabel: "10:40",
            ongoing: event("standup", "acme daily standup", minutes: -10, length: 25, chip: "until 10:55", ongoing: true),
            laterToday: [
                event("review", "Billing export review", minutes: 35, chip: "in 35 min", prep: true, isNext: true),
                event("design", "Design critique", minutes: 200, length: 60)
            ],
            nextDay: FeedDay(title: "Tomorrow", events: [
                event("sync", "acme weekly sync", minutes: 1340, length: 60),
                event("one", "1:1 with Bob", minutes: 1460)
            ]),
            failed: [])
    }
}

/// The account purge notice (board #601): a revoked Slack workspace and a
/// removed Jira site on the lease.
extension HomeShotFixtures {
    static let purges: [AccountPurge] = [
        AccountPurge(id: 2, source: "slack", accountID: 1, accountLabel: "Acme",
                     dueAt: now.addingTimeInterval(60 * 3600)),
        AccountPurge(id: 1, source: "jira", accountID: 2, accountLabel: "acme.example.com", accountStatus: "removed",
                     accessOkAt: now.addingTimeInterval(-31 * 86400), reason: "lease",
                     dueAt: now.addingTimeInterval(70 * 3600))
    ]

    /// Settings → System → Privacy and the connection lines, in the grouped form they sit in.
    static func privacySettings() -> AnyView {
        AnyView(Form {
            PrivacySettingsContent(
                isOn: .constant(true), status: AccountPurgeStatus(enabled: true, enabledBy: "build"), statusError: nil)
            Section("Slack Workspaces") {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Acme")
                    AccountPurgeLine(text: AccountPurgeNoticePolicy.line(purges[0], zone: calendar.timeZone))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Acme Labs")
                    AccountPurgeLine(text: AccountPurgeNoticePolicy.purgedLine(nil), deleted: true)
                }
            }
        }
        .formStyle(.grouped))
    }
}

extension HomeShotFixtures {
    /// Settings → System → Privacy under a sample configuration profile.
    static func organizationPolicy() -> AnyView {
        let policy = ManagedPolicy.normalize([
            "AllowedSources": ["slack", "jira"],
            "MobileSync": "workbench_only",
            "AllowedQuickConnections": ["https://mcp.example.com/"],
            "AllowAutomationShell": false,
            "AllowedAIProviders": ["claude"],
            "PurgeRevokedData": true,
            "RetentionDays": 90
        ])
        return AnyView(Form {
            PrivacySettingsContent(
                isOn: .constant(true), status: AccountPurgeStatus(enabled: true, enabledBy: "policy"), statusError: nil)
            OrganizationPolicySection(policy: policy)
        }
        .formStyle(.grouped))
    }
}

extension HomeShotFixtures {
    /// The Connections tab on Jira, forbidden by a sample profile: the
    /// row's lock, the notice and the locked Add button.
    @MainActor static func connectionsBlocked() -> AnyView {
        let appState = AppState { ["AllowedSources": ["slack", "google"]] }
        appState.managedPolicy.refresh()
        appState.selectedConnection = .jira
        appState.sharedConfig = ConfigService(configPath: NSTemporaryDirectory() + "watchtower-shots-config.yaml")
        return AnyView(ConnectionsTabView().environment(appState))
    }

    /// The Connections overview (#899): a Slack workspace with an expired
    /// token (its banner), healthy Google and Jira, nothing else connected.
    @MainActor static func connectionsOverview() -> AnyView {
        func summary(_ service: ConnectionService, _ accounts: [ConnectionAccountState]) -> ConnectionSummary {
            ConnectionSummary(service: service, accounts: accounts, blocked: false)
        }
        let summaries = ConnectionService.allCases.map { service -> ConnectionSummary in
            switch service {
            case .slack:
                summary(.slack, [
                    ConnectionAccountState(name: "acme", isOK: false, status: "revoked", error: "token expired"),
                    ConnectionAccountState(name: "acme-labs", isOK: true, status: "ok", error: "")
                ])
            case .google:
                summary(.google, [ConnectionAccountState(name: "owner@example.com", isOK: true, status: "ok", error: "")])
            case .jira:
                summary(.jira, [ConnectionAccountState(name: "acme.atlassian.net", isOK: true, status: "ok", error: "")])
            case .quickConnections:
                summary(.quickConnections, [ConnectionAccountState(name: "notion", isOK: true, status: "ok", error: "")])
            default:
                summary(service, [])
            }
        }
        return AnyView(ConnectionsOverviewContent(summaries: summaries) { _ in })
    }
}
