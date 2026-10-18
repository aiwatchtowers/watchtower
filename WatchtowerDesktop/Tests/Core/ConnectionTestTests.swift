import Foundation
import Testing
@testable import WatchtowerCore

@Suite("ConnectionTest")
struct ConnectionTestTests {
    @Test("Models to test: light first, deduped, empties dropped")
    func modelsList() {
        #expect(ConnectionTest.models(light: "haiku", strong: "sonnet") == ["haiku", "sonnet"])
        #expect(ConnectionTest.models(light: "sonnet", strong: "sonnet") == ["sonnet"])
        #expect(ConnectionTest.models(light: nil, strong: "sonnet") == ["sonnet"])
        #expect(ConnectionTest.models(light: "", strong: "sonnet") == ["sonnet"])
        #expect(ConnectionTest.models(light: nil, strong: nil).isEmpty)
    }

    @Test("Summary: all passing models render as one Connected line")
    func summaryAllOK() {
        let (ok, message) = ConnectionTest.summary([("haiku", nil), ("sonnet", nil)])
        #expect(ok)
        #expect(message == "Connected (haiku, sonnet)")
    }

    @Test("Summary: a failing model names itself, passing siblings drop out")
    func summaryPartialFailure() {
        let (ok, message) = ConnectionTest.summary([("haiku", "Model not available"), ("sonnet", nil)])
        #expect(!ok)
        #expect(message == "haiku: Model not available")
    }

    @Test("Summary: two failures both listed")
    func summaryBothFail() {
        let (ok, message) = ConnectionTest.summary([("haiku", "Network error"), ("sonnet", "Network error")])
        #expect(!ok)
        #expect(message == "haiku: Network error · sonnet: Network error")
    }

    private struct TurnFailureCase: Decodable {
        let name: String
        let model: String
        let jsonl: String
        let want: String
    }

    /// `internal/codex/testdata/turn_failures.json` pins Go's
    /// `codex.failedTurn` too: the same codex output reads the same in the
    /// app's errors and in Test Connection (dual path).
    private static func turnFailureCases() throws -> [TurnFailureCase] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("internal/codex/testdata/turn_failures.json")
        return try JSONDecoder().decode([TurnFailureCase].self, from: Data(contentsOf: url))
    }

    @Test("codex failures read from stdout JSONL match the Go wording")
    func codexTurnErrorSharedFixture() throws {
        let cases = try Self.turnFailureCases()
        #expect(cases.count >= 7)
        for tc in cases {
            let got = ConnectionTest.codexTurnError(stdout: tc.jsonl, model: tc.model) ?? ""
            #expect(got == tc.want, "\(tc.name)")
        }
    }
}
