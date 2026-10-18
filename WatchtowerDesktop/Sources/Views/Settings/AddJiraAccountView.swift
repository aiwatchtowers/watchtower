import SwiftUI
import WatchtowerCore

/// Sheet for connecting a new Atlassian site, presented from Settings → Jira.
/// A workspace can have any number of Jira accounts side by side, each
/// granting access via its own OAuth consent flow — this small form kicks off
/// `watchtower jira add`, which opens the loopback-browser consent. Structural
/// copy of `AddSlackAccountView` (house pattern): the connect is awaited
/// directly, so on success the sheet turns into the board step (#572,
/// `JiraBoardChoiceView`) rather than watching an `isConnecting` transition.
/// The connect's daemon restart is held while that step is up and applied
/// once when the sheet goes away (`JiraAccountsViewModel.finishBoardStep`).
struct AddJiraAccountView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    private var vm: JiraAccountsViewModel? { appState.jiraAccountsViewModel }

    /// `.deferred` from onboarding: the connect must not restart the daemon
    /// mid-setup (`DaemonRestartPolicy`). Settings keeps the default.
    let daemonPolicy: DaemonRestartPolicy

    init(daemonPolicy: DaemonRestartPolicy = .restart) {
        self.daemonPolicy = daemonPolicy
    }

    /// The site picked in the list a grant with several sites brings up
    /// (#574); nil means the first one.
    @State private var chosenSiteURL: String?
    /// Cancel was pressed on that list: the sign-in itself went fine, so it
    /// earns no Confluence untick hint.
    @State private var cancelledAtSiteChoice = false
    /// Set when Cancel is tapped so the awaited connect (which returns
    /// with a cleared error after the SIGTERM) does NOT move on — Cancel
    /// means "let me adjust the form", matching AddSlackAccountView's behavior.
    @State private var cancelled = false
    /// After a successful connect the sheet turns into the board step (#572):
    /// a new site syncs nothing until boards are selected.
    @State private var choosingBoards = false
    /// Account ids read before the connect, so the board step lists the
    /// site it added; nil when the read failed (every enabled site).
    @State private var accountIDsBefore: Set<Int>?
    /// Set on the click, before any await, so a double click starts one connect.
    @State private var starting = false
    /// "Also connect Confluence" (#573): the same consent asks for
    /// Confluence, and the board step selects the spaces the owner works in.
    /// On by default; unchecking it keeps the connect Jira-only. A refusal
    /// never costs the Jira connect: `jira add` retries Jira-only, and the
    /// board step's line says Confluence isn't enabled.
    @State private var withConfluence = JiraAccountsViewModel.alsoConnectConfluenceByDefault
    /// The board step's Confluence selection, made when a connect that
    /// asked for Confluence succeeds.
    @State private var confluenceSelection: ConfluenceConnectSelection?
    /// The last attempt asked for Confluence and was cancelled or timed out
    /// (`ConfluenceConnectStep.suggestsUntick`); cleared by the next Connect.
    @State private var showsUntickHint = false

    var body: some View {
        Group {
            if choosingBoards {
                JiraBoardChoiceView(
                    accountIDsBefore: accountIDsBefore, confluence: confluenceSelection
                ) { dismiss() }
                    .padding(20)
                    .frame(width: 420, height: 420)
            } else if let sites = vm?.siteChoices {
                siteChoiceForm(sites)
            } else {
                connectForm
            }
        }
        // Done, Skip or any other way the sheet closes: one restart for the
        // new site and its boards (nothing under onboarding's `.deferred`).
        .onDisappear {
            // No connect outlives its sheet (#574 review F2): a reopened sheet
            // must be able to start a new one.
            vm?.abandonConnect()
            vm?.finishBoardStep()
        }
    }

    private var connectForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Add Jira Site")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(.plain)
            }

            Text("""
                Opens Atlassian's authorization page in your browser. After you approve, \
                the site is added under its address (acme for acme.atlassian.net) and you choose the boards to sync. \
                If your Atlassian account reaches several sites, you pick one from a list.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Also connect Confluence", isOn: $withConfluence)
                .toggleStyle(.checkbox)
                .disabled(vm?.isConnecting == true || starting)
                .help("The same sign-in also grants Confluence. The spaces you wrote in or viewed lately become searchable.")

            Spacer()

            HStack {
                if vm?.isConnecting == true {
                    ProgressView().controlSize(.small)
                    Text(vm?.connectStatus ?? "Connecting...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") {
                        cancelled = true
                        vm?.cancelConnect()
                    }
                } else {
                    Spacer()
                    Button("Connect") {
                        connect()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(starting)
                }
            }

            if let err = vm?.error {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if showsUntickHint {
                Text(ConfluenceConnectStep.untickHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 360, height: 290)
    }

    private func connect() {
        guard let vm, !starting else { return }
        starting = true
        cancelled = false
        showsUntickHint = false
        let askConfluence = withConfluence
        chosenSiteURL = nil
        cancelledAtSiteChoice = false
        Task {
            let result = await vm.addAccountHoldingRestart(
                withConfluence: askConfluence, daemonPolicy: daemonPolicy
            )
            starting = false
            accountIDsBefore = result.accountIDsBefore
            // An Atlassian error page that never redirects back leaves only
            // Cancel or the login timeout: name the way out, and untick.
            if ConfluenceConnectStep.suggestsUntick(
                askedConfluence: askConfluence,
                connected: result.connected && !cancelled,
                cancelled: (cancelled || result.cancelled) && !cancelledAtSiteChoice,
                timedOut: result.timedOut
            ) {
                showsUntickHint = true
                withConfluence = false
            }
            // A user Cancel clears error (SIGTERM/SIGKILL branch) and returns
            // false; `cancelled` also covers a Cancel before the launch.
            if result.connected && !cancelled {
                if askConfluence, let pool = appState.databaseManager?.dbPool {
                    let features = appState.featureManager
                    confluenceSelection = ConfluenceConnectSelection(
                        dbPool: pool, runner: ProcessCLIRunner.makeDefault()
                    ) { ConfluenceSpacesSection.isFeatureOff(features) }
                }
                choosingBoards = true
            }
        }
    }

    /// The list a grant with several Atlassian sites brings up (#574): the
    /// owner picks one instead of typing its address before the sign-in.
    private func siteChoiceForm(_ sites: [JiraSiteChoice]) -> some View {
        let selection = Binding(
            get: { chosenSiteURL ?? sites.first?.url ?? "" },
            set: { chosenSiteURL = $0 }
        )
        return VStack(alignment: .leading, spacing: 16) {
            Text("Choose a Site")
                .font(.title2)
                .fontWeight(.bold)
            Text("Your Atlassian account reaches several sites. Pick the one to add; add another later the same way.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                Picker("Site", selection: selection) {
                    ForEach(sites) { site in
                        VStack(alignment: .leading) {
                            Text(site.name.isEmpty ? site.url : site.name)
                            Text(site.url).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(site.url)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    cancelled = true
                    cancelledAtSiteChoice = true
                    vm?.declineSiteChoice()
                }
                Button("Continue") {
                    if let site = sites.first(where: { $0.url == selection.wrappedValue }) {
                        vm?.chooseSite(site)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360, height: 290)
    }
}
