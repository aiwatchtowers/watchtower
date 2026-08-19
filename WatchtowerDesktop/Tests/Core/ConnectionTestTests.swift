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
}
