import XCTest
import GRDB
@testable import WatchtowerDesktop

// MARK: - IdeasViewModel Tests

@MainActor
final class IdeasViewModelTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!

    override func setUp() {
        super.setUp()
        do {
            (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
        } catch {
            XCTFail("setUp failed: \(error)")
        }
    }

    override func tearDown() {
        TestDatabase.cleanup(path: dbPath)
        super.tearDown()
    }

    // MARK: - load()

    func testLoadSplitsReviewVsRegistry() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertIdea(db, title: "Proposed", status: "proposed")
            try TestDatabase.insertIdea(db, title: "Active, settled", status: "active")
            try TestDatabase.insertIdea(db, title: "Rejected but flagged", status: "rejected", needsReview: true)
        }

        let vm = IdeasViewModel(dbManager: dbManager)
        vm.load()

        XCTAssertEqual(Set(vm.reviewItems.map(\.title)), ["Proposed", "Rejected but flagged"])
        XCTAssertEqual(vm.registryItems.map(\.title), ["Active, settled"])
        XCTAssertNil(vm.errorMessage)
    }

    func testLoadOnEmptyDBYieldsEmptyLists() throws {
        let vm = IdeasViewModel(dbManager: dbManager)
        vm.load()

        XCTAssertTrue(vm.reviewItems.isEmpty)
        XCTAssertTrue(vm.registryItems.isEmpty)
        XCTAssertNil(vm.errorMessage)
    }

    // MARK: - approve()

    func testApproveMovesItemOutOfReviewAndKeepsSelectionValid() throws {
        let id = try dbManager.dbPool.write {
            try TestDatabase.insertIdea($0, title: "Proposed", status: "proposed")
        }
        let vm = IdeasViewModel(dbManager: dbManager)
        vm.load()
        let idea = try XCTUnwrap(vm.reviewItems.first)
        vm.select(idea.id)

        vm.approve(idea)

        XCTAssertTrue(vm.reviewItems.isEmpty)
        XCTAssertEqual(vm.registryItems.map(\.id), [Int(id)])
        XCTAssertEqual(vm.registryItems.first?.status, .active)
        XCTAssertEqual(vm.selectedID, Int(id))
        XCTAssertNil(vm.errorMessage)
    }

    func testApproveOnUnselectedItemLeavesSelectionAlone() throws {
        let (selectedIdeaID, otherID) = try dbManager.dbPool.write { db -> (Int64, Int64) in
            let selected = try TestDatabase.insertIdea(db, title: "Selected", status: "proposed")
            let other = try TestDatabase.insertIdea(db, title: "Other", status: "proposed")
            return (selected, other)
        }
        let vm = IdeasViewModel(dbManager: dbManager)
        vm.load()
        vm.select(Int(selectedIdeaID))
        let other = try XCTUnwrap(vm.reviewItems.first { $0.id == Int(otherID) })

        vm.approve(other)

        XCTAssertEqual(vm.selectedID, Int(selectedIdeaID))
        XCTAssertEqual(vm.reviewItems.map(\.id), [Int(selectedIdeaID)])
    }

    // MARK: - reject() / drop() / reverse()

    func testRejectSetsStatusRejected() throws {
        let id = try dbManager.dbPool.write {
            try TestDatabase.insertIdea($0, status: "proposed")
        }
        let vm = IdeasViewModel(dbManager: dbManager)
        vm.load()
        let idea = try XCTUnwrap(vm.reviewItems.first)

        vm.reject(idea)

        let all = vm.registryItems + vm.reviewItems
        XCTAssertEqual(all.first { $0.id == Int(id) }?.status, .rejected)
    }

    func testDropSetsStatusDropped() throws {
        let id = try dbManager.dbPool.write {
            try TestDatabase.insertIdea($0, status: "active")
        }
        let vm = IdeasViewModel(dbManager: dbManager)
        vm.load()
        let idea = try XCTUnwrap(vm.registryItems.first)

        vm.drop(idea)

        XCTAssertEqual(vm.registryItems.first { $0.id == Int(id) }?.status, .dropped)
    }

    // MARK: - createManual()

    func testCreateManualAddsAnActiveOwnerIdeaToTheRegistry() throws {
        let vm = IdeasViewModel(dbManager: dbManager)
        vm.load()

        let newID = vm.createManual(kind: "decision", title: "Ship it", essence: "Because it's ready")

        XCTAssertNotNil(newID)
        XCTAssertEqual(vm.registryItems.map(\.title), ["Ship it"])
        XCTAssertEqual(vm.registryItems.first?.status, .active)
        XCTAssertNil(vm.errorMessage)
    }

    // MARK: - convertToTarget()

    func testConvertToTargetCreatesTargetAndMarksIdeaConverted() throws {
        let ideaID = try dbManager.dbPool.write {
            try TestDatabase.insertIdea($0, title: "Adopt the new onboarding flow", essence: "Cuts drop-off", status: "active")
        }
        let vm = IdeasViewModel(dbManager: dbManager)
        vm.load()
        let idea = try XCTUnwrap(vm.registryItems.first)

        let targetID = vm.convertToTarget(idea)

        let newTargetID = try XCTUnwrap(targetID)
        XCTAssertNil(vm.errorMessage)
        let target = try dbManager.dbPool.read { try TargetQueries.fetchByID($0, id: newTargetID) }
        XCTAssertEqual(target?.text, "Adopt the new onboarding flow")
        XCTAssertEqual(target?.sourceType, "idea")
        XCTAssertEqual(target?.sourceID, String(ideaID))

        let convertedIdea = try dbManager.dbPool.read { try IdeaQueries.fetchOne($0, id: Int(ideaID)) }
        XCTAssertEqual(convertedIdea?.status, .converted)
        XCTAssertEqual(convertedIdea?.convertedTargetID, newTargetID)
    }
}
