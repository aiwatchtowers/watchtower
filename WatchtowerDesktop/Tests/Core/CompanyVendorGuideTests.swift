import XCTest
@testable import WatchtowerCore

@MainActor
final class CompanyVendorGuideTests: XCTestCase {
    private typealias Guide = CompanyVendorGuide

    func testEveryVendorHasEveryString() {
        for v in CompanyVendor.allCases {
            XCTAssertFalse(Guide.name(v).isEmpty, v.rawValue)
            XCTAssertFalse(Guide.servicesRow(v).title.isEmpty, v.rawValue)
            XCTAssertFalse(Guide.servicesRow(v).detail.isEmpty, v.rawValue)
            XCTAssertFalse(Guide.guideLines(v).isEmpty, v.rawValue)
            XCTAssertTrue(Guide.notSure(v).hasPrefix("Not sure? "), v.rawValue)
            XCTAssertFalse(Guide.alreadyHaveFields(v).isEmpty, v.rawValue)
            XCTAssertFalse(Guide.reuseCaption(v).isEmpty, v.rawValue)
            XCTAssertTrue(Guide.looking(v).hasPrefix("Looking for \(Guide.name(v)) apps"), v.rawValue)
            for index in Guide.guideCopyButtons(v).keys {
                XCTAssertLessThan(index, Guide.guideLines(v).count, v.rawValue)
            }
        }
        XCTAssertEqual(CompanyVendor.allCases.map { Guide.servicesRow($0).title },
                       ["Slack", "Google Workspace — Gmail and Calendar", "Atlassian — Jira and Confluence", "Linear",
                        "Microsoft 365 — Outlook"])
        XCTAssertEqual(CompanyVendor.allCases.map { Guide.servicesRow($0).detail },
                       ["Messages, digests and the Inbox", "Mail and calendar through your company's Google project",
                        "Issues and pages through your company's Atlassian app", "Issues through your company's Linear app",
                        "Mail through your company's Entra app"])
        XCTAssertEqual(Guide.guideLines(.google).map(\.text), [
            "Create a project",
            "Turn on the Gmail API and the Google Calendar API",
            "OAuth consent screen: user type Internal",
            "Credentials → Create OAuth client → Desktop app, then download its JSON"
        ])
        XCTAssertEqual(Guide.guideLines(.atlassian).map(\.text), [
            "Create an OAuth 2.0 integration",
            "Permissions: add the Jira API and the Confluence API with Watchtower's scopes, and report:personal-data",
            "Authorization: add Watchtower's callback URLs",
            "Distribution: turn Sharing on and answer Yes to “Does your app store personal data?”",
            "Add a second admin as an owner, so the app outlives one person"
        ])
        XCTAssertEqual(Guide.guideCopyButtons(.atlassian), [1: "Copy scopes", 2: "Copy callback URLs"])
        XCTAssertEqual(Guide.guideLines(.linear).map(\.text), ["Settings → API → OAuth applications → New application",
                                                               "Callback URL: paste Watchtower's"])
        XCTAssertEqual(Guide.guideCopyButtons(.linear), [1: "Copy callback URL"])
        XCTAssertEqual(Guide.guideLines(.microsoft).map(\.text), [
            "App registrations → New registration: Accounts in this organizational directory only",
            "Platform: Mobile and desktop applications, redirect URI http://localhost",
            "API permissions: add the Outlook permissions, then Grant admin consent"
        ])
        XCTAssertEqual(Guide.guideCopyButtons(.microsoft), [2: "Copy permissions"])
        XCTAssertEqual(Guide.fieldsNote(.linear), "No secret: Watchtower signs in with PKCE.")
        XCTAssertEqual(Guide.fieldsNote(.microsoft), "No secret: Watchtower signs in with PKCE against your tenant.")
        XCTAssertEqual(Guide.notSure(.slack), "Not sure? In Slack, open Apps and search for Watchtower. If it is there, "
            + "someone already created it.")
        XCTAssertEqual(Guide.notSure(.google), "Not sure? Look in Google Cloud Console → APIs & Services → Credentials, under "
            + "OAuth 2.0 Client IDs.")
        XCTAssertEqual(Guide.notSure(.atlassian), "Not sure? Look in the Atlassian developer console → My apps.")
        XCTAssertEqual(Guide.notSure(.linear), "Not sure? Look in Linear → Settings → API → OAuth applications.")
        XCTAssertEqual(Guide.notSure(.microsoft), "Not sure? Look in the Microsoft Entra admin center → App registrations → "
            + "All applications.")
        XCTAssertEqual(Guide.alreadyHaveFields(.slack).map(\.label), ["App settings link", "Client ID"])
        XCTAssertEqual(Guide.alreadyHaveFields(.slack).last?.help, "Needed when no account on this Mac uses the app yet: "
            + "Basic Information → App Credentials on api.slack.com.")
        XCTAssertEqual(Guide.alreadyHaveFields(.slack).first?.help,
                       "Open the app on api.slack.com and copy the address of its settings page.")
        XCTAssertEqual(Guide.alreadyHaveFields(.google).map(\.label), ["Client ID", "Client secret"])
        XCTAssertEqual(Guide.alreadyHaveFields(.google).map(\.secure), [false, true])
        XCTAssertEqual(Guide.alreadyHaveFields(.atlassian).map(\.label), ["Client ID", "Client secret"])
        XCTAssertEqual(Guide.alreadyHaveFields(.linear).map(\.label), ["Client ID"])
        XCTAssertEqual(Guide.alreadyHaveFields(.microsoft).map(\.label), ["Application (client) ID", "Directory (tenant) ID"])
        XCTAssertEqual(Guide.looking(.slack), "Looking for Slack apps this Mac already knows…")
        XCTAssertNil(Guide.notFound(.slack), "the Slack step's first open has no line")
        XCTAssertEqual(Guide.notFound(.google), "No Google client found on this Mac.")
        XCTAssertEqual(Guide.reuseCaption(.slack), "Reusing keeps the app and its ids; nothing new is created. A configuration "
            + "token is still needed to check and update its settings.")
        XCTAssertEqual(Guide.reuseCaption(.google), "Reusing keeps the client and its id; nothing new is created.")
    }

    func testDeepLinksAreHttpsOnVendorHost() {
        for v in CompanyVendor.allCases {
            let links = Guide.guideLines(v).compactMap(\.link)
            XCTAssertFalse(links.isEmpty, v.rawValue)
            for link in links {
                XCTAssertEqual(link.scheme, "https", link.absoluteString)
                XCTAssertEqual(link.host, Guide.host(v), link.absoluteString)
            }
        }
        XCTAssertEqual(CompanySetupWizardModel.confirmLink?.host, Guide.host(.atlassian))
        XCTAssertEqual(CompanySetupWizardModel.clientURL("1234-abcd")?.host, Guide.host(.google))
    }

    func testMCPNoteOpensQuickConnections() {
        XCTAssertEqual(Guide.mcpNote, "Use something else (Notion, GitHub, a CRM…)? Connect it yourself in Connections → "
            + "Quick Connections (MCP connectors).")
        XCTAssertEqual(Guide.openQuickConnections, "Open Quick Connections")
        // The app's ConnectionService raw value (CompanySetupMockCopyTests holds them equal).
        XCTAssertEqual(Guide.quickConnectionsService, "quickConnections")
        XCTAssertEqual(Guide.servicesTitle, "What does your company use?")
        XCTAssertEqual(Guide.servicesBody, "Tick what your company has. Each ticked service gets its own step; the link deny "
            + "list and Publish always follow.")
    }

    func testEveryVendorNamesItsAdminNeeds() {
        for v in CompanyVendor.allCases {
            XCTAssertTrue(Guide.adminNeeds(v).contains("admin"), v.rawValue)
        }
        XCTAssertTrue(Guide.adminNeeds(.google).contains("Project Creator role"))
        XCTAssertTrue(Guide.adminNeeds(.microsoft).contains("Cloud Application Administrator"))
        XCTAssertTrue(Guide.adminNeeds(.atlassian).hasPrefix("No admin rights needed"))
        // Spike S3: a company's own Linear client needs a Linear admin to create; approvals wait for one.
        XCTAssertEqual(Guide.adminNeeds(.linear), "Creating the OAuth application needs a Linear workspace admin. Where your "
            + "workspace asks for app approvals, the sign-in waits until an admin approves Watchtower.")
    }

    func testNotUsedLinesVerbatim() {
        XCTAssertEqual(CompanyVendor.allCases.map { Guide.notUsedLine($0, skipped: false) }, [
            "Slack · not used: no Slack page carries the link",
            "Google · not used: colleagues can connect Google Calendar; Gmail needs their own Google project",
            "Atlassian · not used: colleagues connect Jira with their own API token",
            "Linear · not used: colleagues use Watchtower's shared Linear app",
            "Microsoft 365 · not used: colleagues use Watchtower's shared Microsoft app, which your tenant may ask an admin "
                + "to approve"
        ])
        XCTAssertEqual(Guide.notUsedLine(.linear, skipped: true), "Linear · skipped: colleagues use Watchtower's shared Linear app")
    }
}
