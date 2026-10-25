import Foundation
import Testing
@testable import WatchtowerCore

@Suite("PolicySourceMap")
struct PolicySourceMapTests {
    @Test("every account kind maps to its policy source")
    func everyAccountKindMaps() {
        let want: [String: String?] = [
            "slack": "slack", "google": "google", "gmail": "google", "email": "imap", "imap": "imap",
            "outlook": "imap", "calendar": "caldav", "caldav": "caldav", "ics": "caldav", "jira": "jira",
            "confluence": "jira", "linear": "linear", "quickConnections": nil
        ]
        for (kind, source) in want {
            #expect(PolicySourceMap.policySource(forAccountKind: kind) == source, "\(kind)")
        }
        for source in ManagedPolicy.knownSources {
            #expect(PolicySourceMap.policySource(forAccountKind: source) == source)
        }
    }

    @Test("allowed follows AllowedSources; no source is never blocked")
    func allowedFollowsPolicy() {
        let p = ManagedPolicy.normalize(["AllowedSources": ["slack"]])
        #expect(PolicySourceMap.allowed("slack", policy: p))
        #expect(!PolicySourceMap.allowed("email", policy: p))
        #expect(PolicySourceMap.allowed("quickConnections", policy: p))
        #expect(PolicySourceMap.allowed("jira", policy: .none))
    }

    @Test("onboarding and the sidebar row never offer a forbidden source")
    func connectOffersFollowPolicy() {
        let p = ManagedPolicy.normalize(["AllowedSources": ["google", "linear"]])
        #expect(OnboardingConnectPlan.sources(for: [.workCommunication, .tasksAndJira], policy: p) == [.google, .linear])
        let none = ConnectedSources(slack: false, mail: false, calendar: false, jira: false, linear: false)
        #expect(SourceConnectPrompt.rowTitle(connected: none, dismissed: false, policy: p) == "+ Connect Mail, Jira…")
        let slackOnly = ManagedPolicy.normalize(["AllowedSources": ["slack"]])
        #expect(SourceConnectPrompt.rowTitle(connected: none, dismissed: false, policy: slackOnly) == "+ Connect Slack…")
    }
}
