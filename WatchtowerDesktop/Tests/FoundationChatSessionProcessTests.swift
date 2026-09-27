import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

/// The real `Process` wrapper, driven by `/bin/sh` scripts standing in for
/// `watchtower ai session`: NDJSON parsing, stdin commands, the synthesized
/// `.exited` event with the stderr tail, and the SIGTERM → SIGKILL ladder.
final class FoundationChatSessionProcessTests: XCTestCase {
    private func collect(_ process: any ChatSessionProcess, timeout: Duration = .seconds(10)) async -> [ChatEvent] {
        await withTaskGroup(of: [ChatEvent]?.self) { group in
            group.addTask {
                var events: [ChatEvent] = []
                for await event in process.events { events.append(event) }
                return events
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next()
            group.cancelAll()
            if case let .some(.some(events)) = first { return events }
            return []
        }
    }

    func testParsesStdoutAndReportsExitWithStderrTail() async throws {
        let script = #"""
        echo '{"type":"session_ready","session_id":"s1","provider":"claude","model":"m"}'
        echo 'garbage line'
        read line
        echo "got:$line" >&2
        exit 3
        """#
        let process = try FoundationChatSessionProcess(executable: "/bin/sh", arguments: ["-c", script])
        try process.send(.close)
        let events = await collect(process)
        XCTAssertEqual(events.first, .sessionReady(sessionID: "s1", provider: "claude", model: "m"))
        guard case let .exited(status, stderrTail)? = events.last else {
            return XCTFail("expected .exited last, got \(events)")
        }
        XCTAssertEqual(status, 3)
        XCTAssertTrue(stderrTail.contains(#"got:{"type":"close"}"#), stderrTail)
        XCTAssertEqual(events.count, 2, "the garbage line is dropped")
    }

    /// Go's `json.Marshal` leaves U+0085 (NEL) raw; framing on anything but
    /// byte 0x0A would split this event and drop it. Also a final line with
    /// no trailing newline still arrives.
    func testNELBearingLineArrivesAsOneEvent() async throws {
        let script = #"""
        printf '{"type":"text_delta","turn_id":"t","text":"a\302\205b\342\200\250c"}\n'
        printf '{"type":"turn_done","turn_id":"t","status":"complete"}'
        """#
        let process = try FoundationChatSessionProcess(executable: "/bin/sh", arguments: ["-c", script])
        let events = await collect(process)
        XCTAssertEqual(events.count, 3, "\(events)")
        XCTAssertEqual(events.first, .textDelta(turnID: "t", text: "a\u{85}b\u{2028}c"))
        XCTAssertEqual(events.dropFirst().first, .turnDone(turnID: "t", status: .complete, sessionID: nil))
    }

    func testSendAfterExitThrowsInsteadOfCrashing() async throws {
        let process = try FoundationChatSessionProcess(executable: "/bin/sh", arguments: ["-c", "exit 0"])
        _ = await collect(process)
        XCTAssertThrowsError(try process.send(.cancel))
    }

    func testKillEndsAProcessThatIgnoresSIGTERM() async throws {
        let script = "trap '' TERM; echo '{\"type\":\"turn_start\",\"turn_id\":\"t\"}'; while :; do sleep 1; done"
        let process = try FoundationChatSessionProcess(executable: "/bin/sh", arguments: ["-c", script])
        var iterator = process.events.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first, .turnStart(turnID: "t"))
        process.terminate()
        process.kill()
        var last: ChatEvent?
        while let event = await iterator.next() { last = event }
        guard case let .exited(status, _)? = last else { return XCTFail("expected .exited, got \(String(describing: last))") }
        XCTAssertEqual(status, SIGKILL)
    }
}
