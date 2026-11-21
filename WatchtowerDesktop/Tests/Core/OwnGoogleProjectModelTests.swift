import Foundation
import WatchtowerCore
import WatchtowerTestSupport
import XCTest

/// **Use my own Google project** (#1887 C4, company screens spec §5.2, §10
/// "Own Google" rows): the page's states over a scripted `google add`.
@MainActor
final class OwnGoogleProjectModelTests: XCTestCase {
    private typealias Model = OwnGoogleProjectModel

    private static let clientJSON = Data(#"""
    {"installed":{"client_id":"5678-own.apps.googleusercontent.com","client_secret":"own-secret","project_id":"my-watchtower"}}
    """#.utf8)

    private func model(_ replies: [FakeCLILineStream.Reply] = [], weekly: Bool = false) -> (Model, FakeCLILineStream) {
        let cli = FakeCLILineStream(replies: replies)
        return (Model(makeStreamer: { cli }, weeklyRelogin: weekly), cli)
    }

    private func dropped(_ m: Model) {
        XCTAssertTrue(m.drop(Self.clientJSON, fileName: "client_secret_5678-own.json"))
    }

    func testEmptyNeedsJSON() async {
        let (m, cli) = model()
        m.open()
        XCTAssertTrue(m.isOpen)
        XCTAssertNil(m.droppedLine)
        XCTAssertEqual(m.primaryTitle, "Connect")
        XCTAssertFalse(m.primaryEnabled, "Connect waits for a client JSON")
        XCTAssertEqual(m.status, .note(Model.unverifiedNote))
        await m.connect()
        XCTAssertTrue(cli.invocations.isEmpty, "nothing runs without a JSON")

        XCTAssertFalse(m.drop(Data("{\"web\":{}}".utf8), fileName: "notes.json"))
        XCTAssertTrue(m.fileProblem)
        XCTAssertFalse(m.primaryEnabled)

        dropped(m)
        XCTAssertFalse(m.fileProblem)
        XCTAssertEqual(m.droppedLine, "client_secret_5678-own.json · project my-watchtower")
        XCTAssertTrue(m.primaryEnabled)
    }

    func testSecretOnStdinOnly() async throws {
        let (m, cli) = model([.init(lines: [#"{"result":"ok","account_id":4,"email":"bob@example.org"}"#])])
        dropped(m)
        await m.connect()

        let call = try XCTUnwrap(cli.invocations.first)
        XCTAssertEqual(call.args, ["google", "add", "--app-return", "--calendar", "--gmail",
                                   "--client-id", "5678-own.apps.googleusercontent.com", "--client-secret-stdin", "--json"])
        XCTAssertFalse(call.args.contains { $0.contains("own-secret") }, "the secret never goes in argv")
        XCTAssertEqual(call.stdin.flatMap { String(data: $0, encoding: .utf8) }, "own-secret\n")
    }

    func testDoneLine() async {
        let (m, _) = model([.init(lines: ["Opening your browser…", #"{"result":"ok","account_id":4,"email":"bob@example.org"}"#])])
        var connected = 0
        m.onConnected = { connected += 1 }
        m.open()
        dropped(m)
        await m.connect()

        XCTAssertEqual(m.phase, .done(email: "bob@example.org"))
        XCTAssertEqual(m.doneLines?.title, "Connected bob@example.org through your own project")
        XCTAssertEqual(m.doneLines?.body, "The first sync starts now.")
        XCTAssertNil(m.weeklyNote)
        XCTAssertEqual(m.primaryTitle, "Done")
        XCTAssertTrue(m.primaryEnabled)
        XCTAssertEqual(connected, 1, "the accounts are re-read once")

        m.finish()
        XCTAssertFalse(m.isOpen)
        XCTAssertNil(m.droppedLine, "Done leaves the page empty")
        XCTAssertEqual(m.phase, .idle)
    }

    /// A consent that left Gmail unapproved connects Calendar alone: the
    /// done page says so (no address without Gmail).
    func testPartialGrantSaysWhatDidNotConnect() async {
        let (m, _) = model([.init(lines: [#"{"result":"ok","account_id":4,"email":"","not_granted":["gmail"]}"#])])
        dropped(m)
        await m.connect()
        XCTAssertEqual(m.doneLines?.title, "Connected your Google account through your own project")
        XCTAssertEqual(m.notGrantedNote, "Gmail was not approved on Google's consent screen, so it does not sync. "
            + "Connect again and approve every permission Google asks for.")
        XCTAssertEqual(Model.notGrantedLine(["calendar", "gmail"]), "Google Calendar and Gmail were not approved on "
            + "Google's consent screen, so they do not sync. Connect again and approve every permission Google asks for.")
        m.finish()
        XCTAssertNil(m.notGrantedNote)
    }

    /// Go's own refusals (a re-tie the grant does not cover, a running purge)
    /// and an unclassified failure say what happened, never "download the
    /// JSON again", which is about a refused client only.
    func testRefusalsNotAboutTheClient() async {
        let narrow = "the new sign-in lacks a service the account syncs: run again with --calendar --gmail"
        let (m, _) = model([
            .init(lines: [#"{"result":"rejected","code":"grant_too_narrow","message":"\#(narrow)"}"#]),
            .init(lines: [#"{"result":"rejected","code":"purge_running","message":"its data is being deleted"}"#]),
            .init(lines: [#"{"result":"rejected","message":"could not read the Gmail address"}"#])
        ])
        dropped(m)
        await m.connect()
        XCTAssertEqual(m.status, .problem("Could not connect your Google project: \(narrow)."))
        await m.connect()
        XCTAssertEqual(m.status, .problem("Could not connect your Google project: its data is being deleted."))
        await m.connect()
        XCTAssertEqual(m.status, .problem("Could not connect your Google project: could not read the Gmail address."))
    }

    func testRejectedClient() async {
        let (m, _) = model([.init(lines: [#"{"result":"rejected","code":"invalid_client","message":"token exchange failed"}"#])])
        var connected = 0
        m.onConnected = { connected += 1 }
        dropped(m)
        await m.connect()

        XCTAssertEqual(m.status, .problem(
            "Google does not accept this client: invalid_client. Download the JSON again from Credentials."))
        XCTAssertEqual(m.primaryTitle, "Try again")
        XCTAssertTrue(m.primaryEnabled)
        XCTAssertEqual(connected, 0)
        XCTAssertNotNil(m.droppedLine, "the JSON stays for Try again")
    }

    func testNetworkNothingSaved() async {
        let (m, cli) = model([
            .init(lines: [#"{"result":"network","message":"the request timed out"}"#]),
            .init(lines: [#"{"result":"cancelled","code":"timed_out","message":"the sign-in timed out"}"#]),
            .init(lines: [], exitCode: 1, stderr: "own Google projects are not allowed (AllowOwnGoogleProject)")
        ])
        dropped(m)
        await m.connect()
        XCTAssertEqual(m.status, .problem("Could not reach Google: the request timed out. Nothing was saved."))
        await m.connect()
        XCTAssertEqual(m.status, .problem("The sign-in did not finish: the sign-in timed out. Nothing was saved."))
        await m.connect()
        guard case .problem(let line) = m.status else { return XCTFail("a failed run is a problem line") }
        XCTAssertTrue(line.contains("AllowOwnGoogleProject"), line)
        XCTAssertEqual(cli.invocations.map { $0.args.prefix(2) }, Array(repeating: ["google", "add"], count: 3),
                       "the page runs nothing but google add: it stores nothing itself")
    }

    func testBusyHoldsConnect() async {
        let (m, cli) = model()
        dropped(m)
        let run = Task { await m.connect() }
        let session = await cli.session(number: 1)
        XCTAssertTrue(m.isRunning)
        XCTAssertEqual(m.status, .waiting(.google))
        XCTAssertFalse(m.primaryEnabled)
        XCTAssertFalse(m.drop(Self.clientJSON, fileName: "other.json"), "no new JSON while signing in")
        m.close()
        XCTAssertFalse(m.isOpen)
        session.emit(#"{"result":"ok","account_id":4,"email":"bob@example.org"}"#)
        session.exit()
        await run.value
        XCTAssertEqual(m.phase, .done(email: "bob@example.org"), "the answer lands after leaving the page")
        m.open()
        XCTAssertEqual(m.phase, .idle, "a finished run does not greet the next visit")

        m.externalBusy = { true }
        dropped(m)
        XCTAssertFalse(m.primaryEnabled, "another Google sign-in runs")
    }

    func testPolicyLockLeavesPage() {
        let (m, _) = model()
        m.open()
        dropped(m)
        m.applyPolicy(allowed: true)
        XCTAssertTrue(m.isOpen)
        m.applyPolicy(allowed: false)
        XCTAssertFalse(m.isOpen, "the page goes back to the Google detail and its lock card")
        XCTAssertNil(m.droppedLine)
    }

    func testWeeklyFrameOnlyWhenFlagSet() async {
        XCTAssertFalse(Model.weeklyReloginShipped, "spike S2 is open: no weekly frame ships")
        let ok = FakeCLILineStream.Reply(lines: [#"{"result":"ok","email":"bob@example.org"}"#])
        let (plain, _) = model([ok])
        dropped(plain)
        await plain.connect()
        XCTAssertNil(plain.weeklyNote)

        let (weekly, _) = model([ok], weekly: true)
        XCTAssertNil(weekly.weeklyNote, "only on the done page")
        dropped(weekly)
        await weekly.connect()
        XCTAssertEqual(weekly.weeklyNote, "Google asks a project like this to sign in again every 7 days. "
            + "Watchtower reminds you when it is time.")
    }

    // MARK: Cancel (#2132 G5)

    private func blocking() -> (Model, CancelWatchingStream) {
        let cli = CancelWatchingStream()
        let m = Model { cli }
        m.open()
        dropped(m)
        return (m, cli)
    }

    /// Start → the waiting line; Cancel → the form again, its JSON kept,
    /// no error, the stream cancelled (CLILineStream kills the group).
    func testCancelReturnsToTheForm() async {
        let (m, cli) = blocking()
        var connected = 0
        var cancelled = 0
        m.onConnected = { connected += 1 }
        m.onCancelled = { cancelled += 1 }
        let run = Task { await m.connect() }
        _ = await cli.base.session(number: 1)
        XCTAssertTrue(m.isRunning)
        XCTAssertEqual(m.status, .waiting(.google))

        m.cancel()
        XCTAssertEqual(m.phase, .idle, "Cancel resets at once")
        await run.value
        XCTAssertEqual(m.phase, .idle)
        XCTAssertEqual(m.status, .note(Model.unverifiedNote), "a cancel is silent: no problem line")
        XCTAssertEqual(cli.cancelledRuns, 1, "the sign-in's process is killed")
        XCTAssertNotNil(m.droppedLine, "the JSON stays for the next Connect")
        XCTAssertEqual(m.primaryTitle, "Connect")
        XCTAssertTrue(m.primaryEnabled)
        XCTAssertEqual(connected, 0, "a cancel never re-wires the daemon")
        XCTAssertEqual(cancelled, 1, "what Go saved before the kill is re-read once")
    }

    /// The CLI exits as the owner presses Cancel: its answer, already
    /// buffered in the stream, is dropped; the page is the form, no error.
    func testCancelDropsTheBufferedAnswer() async {
        let (m, cli) = blocking()
        let run = Task { await m.connect() }
        let session = await cli.base.session(number: 1)
        session.emit(#"{"result":"rejected","code":"invalid_client"}"#)
        session.exit(code: 1)
        m.cancel()
        await run.value
        XCTAssertEqual(m.phase, .idle)
        XCTAssertEqual(m.status, .note(Model.unverifiedNote))
    }

    /// Cancel, Connect again, then the first run ends: its end does not
    /// touch the second run, which still waits.
    func testStaleRunDoesNotResetTheNextOne() async {
        let (m, cli) = blocking()
        let first = Task { await m.connect() }
        let one = await cli.base.session(number: 1)
        m.cancel()
        let second = Task { await m.connect() }
        let two = await cli.base.session(number: 2)
        one.exit(code: 1) // the first child dies after its kill; a cancelled stream delivers nothing more
        await first.value
        XCTAssertTrue(m.isRunning, "the first run's end is ignored")
        XCTAssertEqual(m.status, .waiting(.google))

        two.emit(#"{"result":"ok","account_id":4,"email":"bob@example.org"}"#)
        two.exit()
        await second.value
        XCTAssertEqual(m.phase, .done(email: "bob@example.org"))
        XCTAssertEqual(cli.cancelledRuns, 1)
    }

    /// Cancel does nothing once a run has ended: its result stays, nothing
    /// is re-read.
    func testCancelLeavesAFinishedRun() async {
        let (m, _) = model([.init(lines: [#"{"result":"rejected","code":"invalid_client"}"#])])
        var cancelled = 0
        m.onCancelled = { cancelled += 1 }
        m.cancel()
        dropped(m)
        await m.connect()
        m.cancel()
        XCTAssertEqual(cancelled, 0, "Cancel with nothing running re-reads nothing")
        XCTAssertEqual(m.primaryTitle, "Try again")
        guard case .problem = m.status else { return XCTFail("the refusal stays") }
    }
}

/// `FakeCLILineStream` with every one-shot run wrapped, to see the model
/// cancel it: a cancelled stream is what `CLILineStream` turns into a kill
/// of the child's process group.
private final class CancelWatchingStream: CLILineStreaming, @unchecked Sendable {
    let base = FakeCLILineStream()
    private let lock = NSLock()
    private var cancelled = 0

    var cancelledRuns: Int {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func lines(args: [String], stdin: Data?) -> AsyncThrowingStream<String, Error> {
        let inner = base.lines(args: args, stdin: stdin)
        let (stream, sink) = AsyncThrowingStream.makeStream(of: String.self)
        let pump = Task {
            do {
                for try await line in inner { sink.yield(line) }
                sink.finish()
            } catch {
                sink.finish(throwing: error)
            }
        }
        sink.onTermination = { [weak self] termination in
            pump.cancel()
            if case .cancelled = termination { self?.markCancelled() }
        }
        return stream
    }

    func session(args: [String]) -> any CLILineSession { base.session(args: args) }

    private func markCancelled() {
        lock.lock(); cancelled += 1; lock.unlock()
    }
}
