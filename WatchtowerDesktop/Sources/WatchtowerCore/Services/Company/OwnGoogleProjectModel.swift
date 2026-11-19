import Foundation
import Observation

/// **Use my own Google project** (#1887 C4, company screens spec §5): a page
/// in the Google detail that connects Gmail and Calendar through a Google
/// Cloud project the person owns. Its one command is `watchtower google add
/// --client-id <id> --client-secret-stdin --json`: the secret goes on stdin
/// only, never in argv; Go signs in through the client, stores the personal
/// bundle and ties the account (re-tying the same address's row, which moves
/// a shared-app Gmail account onto the own project, D11) only after the
/// sign-in succeeded, so a refused client, an unreachable Google or a
/// stopped sign-in stores nothing.
///
/// Held by `AppState` so a sign-in outlives the page: leaving it keeps the
/// dropped JSON (in memory, while the app runs) and the running sign-in,
/// whose answer lands here; nothing is written by this model. The
/// organization's `AllowOwnGoogleProject = false` closes the page
/// (`applyPolicy`), and Go refuses the add on its own.
@MainActor
@Observable
package final class OwnGoogleProjectModel {
    package enum Phase: Equatable, Sendable {
        /// No run yet, or a new JSON since the last one.
        case idle
        case checking
        case failed(String)
        case done(email: String)
    }

    /// The dropped client JSON and the name it came under.
    package struct DroppedFile: Equatable, Sendable {
        package let name: String
        package let client: GoogleClientFile
    }

    /// One block of the page under the guide and the drop zone.
    package enum Status: Equatable, Sendable {
        case note(String)
        case busy(String)
        case problem(String)
    }

    /// The page shows (in place of the Google detail's lists).
    package private(set) var isOpen = false
    package private(set) var phase: Phase = .idle
    package private(set) var file: DroppedFile?
    /// The last drop was not a Google OAuth client JSON.
    package private(set) var fileProblem = false
    /// The services the last connect's consent left unapproved.
    package private(set) var notGranted: [String] = []
    /// Spike S2 failed: the done page says Google asks for a weekly sign-in.
    package let weeklyRelogin: Bool

    /// A sign-in of the Google detail or a company chain runs: Connect waits
    /// (two browser sign-ins never start at once).
    @ObservationIgnored package var externalBusy: () -> Bool = { false }
    /// A run connected an account: AppState re-reads the accounts and
    /// re-wires the daemon.
    @ObservationIgnored package var onConnected: (() -> Void)?
    @ObservationIgnored private let makeStreamer: @MainActor () -> (any CLILineStreaming)?

    /// Go's `company.OwnProjectWeeklyRelogin` (spike S2 still open: false);
    /// the weekly frame ships only when both flip.
    package static let weeklyReloginShipped = false

    package init(
        makeStreamer: @escaping @MainActor () -> (any CLILineStreaming)?,
        weeklyRelogin: Bool = OwnGoogleProjectModel.weeklyReloginShipped
    ) {
        self.makeStreamer = makeStreamer
        self.weeklyRelogin = weeklyRelogin
    }

    package var isRunning: Bool { phase == .checking }

    // MARK: Opening and leaving

    /// **Use my own Google project**: opens the page; a finished run's done
    /// page does not greet the next visit.
    package func open() {
        if case .done = phase { reset() }
        isOpen = true
    }

    /// **‹ Google** (or the detail going away): the page closes; the
    /// dropped JSON and a running sign-in stay.
    package func close() { isOpen = false }

    /// **Done**: back to the Google detail, the page empty again.
    package func finish() {
        reset()
        isOpen = false
    }

    /// The organization's policy now: own projects not allowed closes the
    /// page and drops the JSON (the detail shows the lock card instead); a
    /// running sign-in is Go's to refuse.
    package func applyPolicy(allowed: Bool) {
        guard !allowed else { return }
        isOpen = false
        guard !isRunning else { return }
        reset()
    }

    private func reset() {
        phase = .idle
        notGranted = []
        file = nil
        fileProblem = false
    }

    // MARK: The client JSON

    /// The dropped or pasted client JSON; false when it is not one (the
    /// drop zone's problem line), or a sign-in runs.
    @discardableResult
    package func drop(_ data: Data, fileName: String) -> Bool {
        guard !isRunning else { return false }
        guard let client = GoogleClientFile(data: data) else {
            fileProblem = true
            return false
        }
        fileProblem = false
        file = DroppedFile(name: fileName, client: client)
        phase = .idle
        return true
    }

    // MARK: Connect

    /// `google add` for the own project: both services (§5.2 "Gmail and
    /// Calendar"), the client id in argv, the secret on stdin.
    package static func connectArgs(clientID: String) -> [String] {
        ["google", "add", "--app-return", "--calendar", "--gmail",
         "--client-id", clientID, "--client-secret-stdin", "--json"]
    }

    package var canConnect: Bool { file != nil && !isRunning && !externalBusy() }

    /// **Connect** / **Try again**: the sign-in through the dropped client.
    package func connect() async {
        guard canConnect, let file else { return }
        phase = .checking
        let stdin = Data((file.client.clientSecret + "\n").utf8)
        var last: String?
        var failure: String?
        if let streamer = makeStreamer() {
            do {
                for try await line in streamer.lines(args: Self.connectArgs(clientID: file.client.clientID), stdin: stdin) {
                    let text = line.trimmingCharacters(in: .whitespaces)
                    if text.hasPrefix("{") { last = text }
                }
            } catch {
                failure = error.localizedDescription
            }
        } else {
            failure = CLIRunnerError.binaryNotFound.localizedDescription
        }
        guard let last, let result = try? JSONDecoder().decode(CompanyCheckResult.self, from: Data(last.utf8)) else {
            phase = .failed(Self.failedLine(failure ?? ""))
            return
        }
        apply(result)
    }

    /// Refusals that are not Google's verdict on the client: Go's own
    /// (the sign-in lacks a service the same address's row syncs, its purge
    /// runs); their message says what to do, not "download the JSON again".
    private static let refusalsNotAboutTheClient: Set<String> = ["grant_too_narrow", "purge_running"]

    private func apply(_ result: CompanyCheckResult) {
        switch result.result {
        case "ok":
            notGranted = result.notGranted
            phase = .done(email: result.email)
            onConnected?()
        case "network":
            phase = .failed(CompanySetupWizardModel.networkLine(.google, result.message))
        case "cancelled":
            phase = .failed(CompanySetupWizardModel.cancelledLine(result.message))
        default:
            // Only a code Google sent back (invalid_client, …) is a refused client.
            if result.code.isEmpty || Self.refusalsNotAboutTheClient.contains(result.code) {
                phase = .failed(Self.failedLine(result.message))
            } else {
                phase = .failed(CompanySetupWizardModel.rejectedLine(.google, code: result.code, tenant: ""))
            }
        }
    }

    // MARK: What the page shows

    /// "client_secret_….json · project my-watchtower"
    package var droppedLine: String? {
        file.map { $0.client.projectID.isEmpty ? $0.name : "\($0.name) · project \($0.client.projectID)" }
    }

    /// The line under the drop zone: the unverified-app note before a run,
    /// the busy line during it, the refusal after a failed one.
    package var status: Status {
        switch phase {
        case .idle, .done: .note(Self.unverifiedNote)
        case .checking: .busy(Self.checkingLine)
        case .failed(let text): .problem(text)
        }
    }

    package var primaryTitle: String {
        switch phase {
        case .failed: Self.tryAgainTitle
        case .done: Self.doneTitle
        case .idle, .checking: Self.connectTitle
        }
    }

    package var primaryEnabled: Bool {
        if case .done = phase { return true }
        return canConnect
    }

    package var doneLines: (title: String, body: String)? {
        guard case .done(let email) = phase else { return nil }
        return (Self.connectedTitle(email), Self.connectedBody)
    }

    /// A partial consent: the services left unapproved, under the done lines.
    package var notGrantedNote: String? {
        guard case .done = phase, !notGranted.isEmpty else { return nil }
        return Self.notGrantedLine(notGranted)
    }

    /// The weekly sign-in note under the done lines, only when S2 failed.
    package var weeklyNote: String? {
        guard weeklyRelogin, case .done = phase else { return nil }
        return Self.weeklyLine
    }
}

// MARK: - Copy (company screens spec §5.2)

extension OwnGoogleProjectModel {
    package static let backTitle = "Google"
    package static let title = "Use my own Google project"
    package static let intro = "Gmail and Calendar through a Google Cloud project you own. About ten minutes, once."
    /// The guide; unlike the company step (Internal), an own project is External and published.
    package static let guide: [(text: String, link: URL?)] = [
        ("Create a project", URL(string: "https://console.cloud.google.com/projectcreate")),
        ("Turn on the Gmail API and the Google Calendar API", URL(string: "https://console.cloud.google.com/apis/library")),
        ("OAuth consent screen: user type External, and add yourself as a test user",
         URL(string: "https://console.cloud.google.com/apis/credentials/consent")),
        ("Publish the app to production. Google calls it unverified; that is expected for your own project",
         URL(string: "https://console.cloud.google.com/apis/credentials/consent")),
        ("Credentials → Create OAuth client → Desktop app, then download its JSON",
         URL(string: "https://console.cloud.google.com/apis/credentials"))
    ]
    package static let unverifiedNote = "The first sign-in shows “Google hasn't verified this app”. Choose Advanced → "
        + "Go to your project: it is your own."
    package static let checkingLine = CompanySetupWizardModel.checkingGoogle
    package static let connectTitle = "Connect"
    package static let tryAgainTitle = "Try again"
    package static let doneTitle = "Done"
    /// A Calendar-only consent reads no address: "your Google account".
    package static func connectedTitle(_ email: String) -> String {
        "Connected \(email.isEmpty ? "your Google account" : email) through your own project"
    }

    /// "Gmail was not approved on Google's consent screen, so it does not sync. Connect again and approve every permission Google asks for."
    package static func notGrantedLine(_ services: [String]) -> String {
        let names = services.map { $0 == "gmail" ? "Gmail" : "Google Calendar" }.joined(separator: " and ")
        let (verb, rest) = services.count > 1 ? ("were", "they do not sync") : ("was", "it does not sync")
        return "\(names) \(verb) not approved on Google's consent screen, so \(rest). "
            + "Connect again and approve every permission Google asks for."
    }
    package static let connectedBody = "The first sync starts now."
    package static let weeklyLine = "Google asks a project like this to sign in again every 7 days. "
        + "Watchtower reminds you when it is time."

    /// A run that ended without an answer (the CLI failed before one, or
    /// after the sign-in, when Go reports what it kept).
    static func failedLine(_ detail: String) -> String {
        let why = detail.isEmpty ? "" : ": \(detail)"
        return "Could not connect your Google project\(why)."
    }
}
