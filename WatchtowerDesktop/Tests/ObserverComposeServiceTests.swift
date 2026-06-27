import XCTest
@testable import WatchtowerDesktop

final class ObserverComposeServiceTests: XCTestCase {
    private struct StubRunner: CLIRunnerProtocol {
        let output: Data
        func run(args: [String]) async throws -> Data { output }
    }

    func testDecodesNameAndInstruction() async throws {
        let json = #"{"name":"Billing refund","instruction":"Watch the HashBank refund decision."}"#
        let svc = ObserverComposeService(runner: StubRunner(output: Data(json.utf8)))
        let draft = try await svc.compose(targetID: 42, input: "refund thing")
        XCTAssertEqual(draft.name, "Billing refund")
        XCTAssertEqual(draft.instruction, "Watch the HashBank refund decision.")
    }

    func testThrowsOnEmptyOutput() async {
        let svc = ObserverComposeService(runner: StubRunner(output: Data()))
        do {
            _ = try await svc.compose(targetID: 1, input: "x")
            XCTFail("expected decode error")
        } catch {
            // expected
        }
    }
}
