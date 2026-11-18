import Foundation

extension SlackModePresentation {
    /// Connections → Slack, the **Connect your workspace's app** section
    /// (screens spec §4.2, §4.4): its static lines, the MDM rows and whether
    /// it is folded. The flow's own strings live in `SlackConnectFlowModel`.
    package struct ConnectSection: Equatable, Sendable {
        /// One `SlackApps` entry not yet connected.
        package struct OrganizationRow: Equatable, Sendable, Identifiable {
            package var id: String { target.teamID }
            package let target: SlackConnectTarget
            package let title: String
        }

        package let organizationRows: [OrganizationRow]
        /// The warning line while the listener cannot bind 18551; nil otherwise.
        package let portBusyLine: String?
        /// Full: the section hides behind **Connect another workspace…**.
        package let isFolded: Bool
        /// Full: the quiet button under Workspaces that opens the fold.
        package let showsFoldButton: Bool

        package let title = "Connect your workspace's app"
        package let caption = "Open Watchtower's app in Slack, go to its About tab and click the connect link. "
            + "No clickable link? Paste the link or the connect code here."
        package let organizationTitle = "Set up by your organization"
        package let fieldPlaceholder = "Connect link or code"
        package let connect = "Connect"
        package let noAppYet = "No Watchtower app in your workspace yet?"
        package let setUpForCompany = "Set up for my company"
        package let foldButton = "Connect another workspace…"
        /// The LLM-provider disclosure every connecting member sees before a
        /// paste or MDM **Connect** (policy hygiene spec §6), with its link.
        package let disclosure = SlackDisclosureCopy.connectLine(workspace: "your workspace")
        package let privacyLink = SlackDisclosureCopy.privacyLink
        package let privacyURL = SlackDisclosureCopy.privacyURL

        /// - Parameters:
        ///   - display: the pane's mode; Full and Full · Live fold the section.
        ///   - expanded: the owner opened the fold (or a Reconnect asked for it).
        ///   - organizationApps: MDM `SlackApps`; nil when the key is absent.
        ///   - accounts: an entry whose team is connected with its client id
        ///     (any row not removed or purged) has no row.
        package init(
            display: Display,
            portBusy: Bool,
            expanded: Bool,
            organizationApps: [ManagedPolicy.SlackApp]?,
            accounts: [SlackAccount]
        ) {
            let live = accounts.filter { !$0.isGone }
            let open = (organizationApps ?? []).filter { app in
                !live.contains { $0.teamID == app.teamID && $0.clientID == app.clientID }
            }
            organizationRows = open.map { app in
                OrganizationRow(target: SlackConnectTarget(teamID: app.teamID, clientID: app.clientID),
                                title: "Workspace \(app.teamID)")
            }
            portBusyLine = portBusy
                ? "The connect link cannot reach Watchtower: port 18551 is busy. Quit the app holding port 18551, "
                    + "then open Connections → Slack again to retry."
                : nil
            let full = display == .full || display == .fullLive
            // The busy line must be seen, so the fold opens by itself (§4.4).
            isFolded = full && !expanded && !portBusy
            showsFoldButton = full
        }
    }
}
