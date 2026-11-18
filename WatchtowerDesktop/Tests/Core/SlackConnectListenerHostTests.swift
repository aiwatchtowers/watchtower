import WatchtowerTestSupport
import XCTest
@testable import WatchtowerCore

@MainActor
final class SlackConnectListenerHostTests: XCTestCase {
    private let listening = #"{"event":"listening","port":18551}"#
    private let portBusy = #"{"event":"port_busy","port":18551}"#

    private func makeHost() -> (SlackConnectListenerHost, FakeCLILineStream) {
        let fake = FakeCLILineStream()
        return (SlackConnectListenerHost(streamer: fake), fake)
    }

    // MARK: Events

    /// The Go side's fixture (plan B Task 7 writes it): every line decodes.
    func testDecodesEveryEvent() throws {
        let fixture = URL(fileURLWithPath: #filePath) // …/WatchtowerDesktop/Tests/Core/<this file>
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("internal/slackconnect/testdata/serve_events.jsonl")
        let lines = try String(contentsOf: fixture, encoding: .utf8).split(separator: "\n")
        let events = try lines.map { try JSONDecoder().decode(SlackConnectEvent.self, from: Data($0.utf8)) }

        XCTAssertTrue(events.contains(.listening(port: 18551)))
        XCTAssertTrue(events.contains(.portBusy(port: 18551)))
        XCTAssertTrue(events.contains { if case .link = $0 { true } else { false } })
        XCTAssertTrue(events.contains { if case .browser = $0 { true } else { false } })
        XCTAssertTrue(events.contains { if case .connected = $0 { true } else { false } })
        XCTAssertTrue(events.contains { if case .busy = $0 { true } else { false } })
        let reasons = Set(events.compactMap { if case let .failed(_, reason, _) = $0 { reason } else { nil } })
        XCTAssertEqual(reasons, [.teamMismatch, .otherUser, .denied, .cancelled, .exchange, .policy, .purgeRunning, .other])

        // Each decodes back to itself through the Swift encoder.
        for event in events {
            XCTAssertEqual(try JSONDecoder().decode(SlackConnectEvent.self, from: JSONEncoder().encode(event)), event)
        }
    }

    func testDecodesFieldValues() throws {
        let line = #"{"event":"connected","flow":"f1","account_id":7,"team_id":"T0ACME","team_name":"Acme","rebound_from":""}"#
        let event = try JSONDecoder().decode(SlackConnectEvent.self, from: Data(line.utf8))
        XCTAssertEqual(event, .connected(SlackConnectedAccount(flow: "f1", accountID: 7, teamID: "T0ACME", teamName: "Acme", reboundFrom: "")))
        let link = #"{"event":"link","flow":"f2","team_id":"T0ACME","client_id":"1111.2222"}"#
        XCTAssertEqual(try JSONDecoder().decode(SlackConnectEvent.self, from: Data(link.utf8)),
                       .link(flow: "f2", teamID: "T0ACME", clientID: "1111.2222"))
    }

    func testUnknownFailureReasonIsOther() throws {
        let line = #"{"event":"failed","flow":"f","reason":"brand_new","message":"m"}"#
        XCTAssertEqual(try JSONDecoder().decode(SlackConnectEvent.self, from: Data(line.utf8)),
                       .failed(flow: "f", reason: .other, message: "m"))
    }

    private func text(_ cmd: SlackConnectCommand) throws -> String? {
        String(bytes: try cmd.line(), encoding: .utf8)
    }

    func testCommandLines() throws {
        XCTAssertEqual(try text(.start(teamID: "T0ACME", clientID: "1.2", accountID: 4)),
                       #"{"account_id":4,"client_id":"1.2","cmd":"start","team_id":"T0ACME"}"# + "\n")
        XCTAssertEqual(try text(.start(teamID: "T0ACME", clientID: "1.2", accountID: nil)),
                       #"{"client_id":"1.2","cmd":"start","team_id":"T0ACME"}"# + "\n")
        XCTAssertEqual(try text(.confirm(flow: "f1")), #"{"cmd":"confirm","flow":"f1"}"# + "\n")
        XCTAssertEqual(try text(.cancel(flow: "f1")), #"{"cmd":"cancel","flow":"f1"}"# + "\n")
    }

    // MARK: Host

    func testStartsServeAndForwardsEvents() async {
        let (host, fake) = makeHost()
        XCTAssertEqual(host.state, .idle)
        host.ensureRunning()
        let child = await fake.session(number: 1)
        XCTAssertEqual(child.args, ["slack", "connect", "serve"])

        child.emit("not json")
        child.emit(listening)
        child.emit(#"{"event":"browser","flow":"f1"}"#)
        var events = host.events.makeAsyncIterator()
        let first = await events.next(), second = await events.next()
        XCTAssertEqual(first, .listening(port: 18551))
        XCTAssertEqual(second, .browser(flow: "f1"))
        XCTAssertEqual(host.state, .listening)

        host.ensureRunning() // already running: no second child
        XCTAssertEqual(fake.sessions.count, 1)
    }

    func testSendWritesCommandLines() async {
        let (host, fake) = makeHost()
        XCTAssertFalse(host.send(.confirm(flow: "f1")), "no child yet")
        host.ensureRunning()
        let child = await fake.session(number: 1)
        XCTAssertTrue(host.send(.start(teamID: "T0ACME", clientID: "1.2", accountID: nil)))
        XCTAssertTrue(host.send(.cancel(flow: "f1")))
        XCTAssertEqual(child.writtenLines, [
            #"{"client_id":"1.2","cmd":"start","team_id":"T0ACME"}"#,
            #"{"cmd":"cancel","flow":"f1"}"#
        ])
    }

    func testPortBusyState() async {
        let (host, fake) = makeHost()
        host.ensureRunning()
        let child = await fake.session(number: 1)
        child.emit(portBusy)
        await untilObserved { host.state == .portBusy }
        var events = host.events.makeAsyncIterator()
        let event = await events.next()
        XCTAssertEqual(event, .portBusy(port: 18551))

        child.exit(code: 3)
        await untilObserved { !host.isChildRunning }
        XCTAssertEqual(host.state, .portBusy, "exit 3 after port_busy is no crash: no restart")
        XCTAssertEqual(fake.sessions.count, 1)
    }

    func testUnexpectedExitRestartsOnce() async {
        let (host, fake) = makeHost()
        host.ensureRunning()
        let first = await fake.session(number: 1)
        first.emit(listening)
        await untilObserved { host.state == .listening }

        first.exit(code: 1)
        let second = await fake.session(number: 2)
        XCTAssertEqual(host.state, .idle)

        // The restart dies before binding the port: no second restart.
        second.exit(code: 0)
        await untilObserved { host.state == .stopped }
        XCTAssertFalse(host.isChildRunning)
        XCTAssertEqual(fake.sessions.count, 2, "one restart only")

        // ensureRunning gives a fresh restart budget.
        host.ensureRunning()
        let third = await fake.session(number: 3)
        third.exit(code: 1)
        _ = await fake.session(number: 4)
    }

    /// A10: binding the port does not refill the restart budget — a child
    /// that binds and then crashes again stops after the one automatic
    /// restart; only `ensureRunning()` (the Slack pane opening) retries.
    func testCrashAfterListeningAgainStopsUntilEnsureRunning() async {
        let (host, fake) = makeHost()
        host.ensureRunning()
        for number in 1...2 {
            let child = await fake.session(number: number)
            child.emit(listening)
            await untilObserved { host.state == .listening }
            child.exit(code: 1)
        }
        await untilObserved { host.state == .stopped }
        XCTAssertEqual(fake.sessions.count, 2, "one automatic restart only")

        host.ensureRunning()
        let third = await fake.session(number: 3)
        third.emit(listening)
        await untilObserved { host.state == .listening }
    }

    func testEnsureRunningWhileStartingThenPortBusyRelaunches() async {
        let (host, fake) = makeHost()
        host.ensureRunning()
        let first = await fake.session(number: 1)
        XCTAssertEqual(host.state, .idle)
        host.ensureRunning() // the child has not reported yet
        XCTAssertEqual(fake.sessions.count, 1)

        first.emit(portBusy)
        await untilObserved { host.state == .portBusy }
        first.exit(code: 3)
        let second = await fake.session(number: 2)
        second.emit(listening)
        await untilObserved { host.state == .listening }
    }

    func testEnsureRunningWhileStartingThenListeningKeepsChild() async {
        let (host, fake) = makeHost()
        host.ensureRunning()
        let first = await fake.session(number: 1)
        host.ensureRunning()
        first.emit(listening)
        await untilObserved { host.state == .listening }

        // The bound child answered the retry (no relaunch flag left): its crash
        // uses the one automatic restart, and the restart's crash stops the host.
        first.exit(code: 1)
        let second = await fake.session(number: 2)
        second.exit(code: 1)
        await untilObserved { host.state == .stopped }
        XCTAssertEqual(fake.sessions.count, 2)
    }

    func testEnsureRunningRebindsAfterPortBusy() async {
        let (host, fake) = makeHost()
        host.ensureRunning()
        let first = await fake.session(number: 1)
        first.emit(portBusy)
        await untilObserved { host.state == .portBusy }
        first.exit(code: 3)
        await untilObserved { !host.isChildRunning }

        host.ensureRunning()
        let second = await fake.session(number: 2)
        XCTAssertEqual(host.state, .idle)
        second.emit(listening)
        await untilObserved { host.state == .listening }
    }

    func testEnsureRunningWhilePortBusyChildExitsRelaunches() async {
        let (host, fake) = makeHost()
        host.ensureRunning()
        let first = await fake.session(number: 1)
        first.emit(portBusy)
        await untilObserved { host.state == .portBusy }

        host.ensureRunning() // the busy child has not exited yet
        XCTAssertEqual(fake.sessions.count, 1)
        first.exit(code: 3)
        let second = await fake.session(number: 2)
        second.emit(listening)
        await untilObserved { host.state == .listening }
    }

    func testStdinEOFOnStop() async {
        let (host, fake) = makeHost()
        host.ensureRunning()
        let child = await fake.session(number: 1)
        child.emit(listening)
        await untilObserved { host.state == .listening }

        host.stop()
        XCTAssertTrue(child.inputClosed, "stop closes stdin: serve exits on EOF")
        XCTAssertFalse(child.terminated, "no kill: the child closes its listener itself")
        XCTAssertEqual(host.state, .stopped)
        XCTAssertFalse(host.send(.confirm(flow: "f1")))

        child.exit(code: 0)
        await untilObserved { !host.isChildRunning }
        XCTAssertEqual(host.state, .stopped)
        XCTAssertEqual(fake.sessions.count, 1, "a stopped child is not restarted")
    }
}
