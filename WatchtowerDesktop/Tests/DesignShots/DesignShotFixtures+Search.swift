import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The Search screen's results while the messages search index is still
/// being rebuilt (#892): the notice line above two `acme` results.
@MainActor
enum SearchShotFixtures {
    static func rebuildPending() -> AnyView {
        do {
            let db = try TestDatabase.create()
            let results = try db.write { d -> [SearchResult] in
                try TestDatabase.insertChannel(d, id: "C001", name: "acme-releases")
                try TestDatabase.insertUser(d, id: "U001", displayName: "Colleague A")
                try TestDatabase.insertMessage(d, ts: "1700000000.000100", text: "The rollout plan for acme is in the doc")
                try TestDatabase.insertMessage(d, ts: "1700000100.000100", text: "Rollout moves to Friday after the review")
                return try SearchQueries.search(d, query: "rollout")
            }
            return AnyView(VStack(spacing: 0) {
                SearchIndexRebuildNotice(isPending: true)
                Divider()
                List(results) { SearchResultRow(result: $0) }
            })
        } catch {
            XCTFail("search shot fixture failed: \(error)")
            return AnyView(Text("fixture failed: \(String(describing: error))").foregroundStyle(.red))
        }
    }
}
