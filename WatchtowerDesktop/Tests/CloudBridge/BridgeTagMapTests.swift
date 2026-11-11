import CloudBridgeCore
import XCTest

final class BridgeTagMapTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("bridge-tags-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testTagSeqStableAcrossRestarts() throws {
        let zone = "RelayZone-hub-acme"
        var map: BridgeTagMap? = try BridgeTagMap(directory: dir)
        let generation = try XCTUnwrap(map?.generation)
        let first = try XCTUnwrap(map?.record(zone: zone, name: "a-DEVICE-7", changeTag: "tag-1", systemFields: Data([1])))
        let cursor = try XCTUnwrap(map?.cursor(zone: zone, token: Data([9, 9])))
        map = nil

        let reopened = try BridgeTagMap(directory: dir) { XCTFail("a second generation was minted"); return "x" }
        XCTAssertEqual(reopened.generation, generation, "the generation is persisted with bridge.db")
        XCTAssertEqual(try reopened.record(zone: zone, name: "a-DEVICE-7", changeTag: "tag-1", systemFields: Data([1])), first)
        XCTAssertEqual(try reopened.entry(zone: zone, name: "a-DEVICE-7")?.systemFields, Data([1]))
        XCTAssertEqual(try reopened.token(zone: zone, cursor: cursor), Data([9, 9]))
        let next = try reopened.record(zone: zone, name: "a-DEVICE-7", changeTag: "tag-2", systemFields: Data([2]))
        XCTAssertNotEqual(next, first, "a new change tag gets a new number")
        XCTAssertNotEqual(try reopened.record(zone: zone, name: "a-DEVICE-8", changeTag: "tag-1", systemFields: Data()), next)
    }

    func testFilesArePrivate() throws {
        _ = try BridgeTagMap(directory: dir)
        let fm = FileManager.default
        XCTAssertEqual(try fm.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int, 0o700)
        let db = dir.appendingPathComponent("bridge.db").path
        XCTAssertEqual(try fm.attributesOfItem(atPath: db)[.posixPermissions] as? Int, 0o600)
    }

    func testANewDatabaseHasANewGeneration() throws {
        let first = try BridgeTagMap(directory: dir).generation
        XCTAssertEqual(first.count, 16)
        try FileManager.default.removeItem(at: dir)
        XCTAssertNotEqual(try BridgeTagMap(directory: dir).generation, first)
    }

    func testCursorsArePrunedAndUnknownOnesRefused() throws {
        let map = try BridgeTagMap(directory: dir)
        let zone = "DataZone-hub-acme"
        XCTAssertNil(try map.token(zone: zone, cursor: 0))
        let first = try map.cursor(zone: zone, token: Data([0]))
        XCTAssertEqual(try map.cursor(zone: zone, token: Data([0])), first, "the same token keeps its cursor")
        for i in 1...BridgeTagMap.keptCursors {
            _ = try map.cursor(zone: zone, token: Data([UInt8(i)]))
        }
        XCTAssertThrowsError(try map.token(zone: zone, cursor: first)) { error in
            XCTAssertEqual(error as? BridgeTagMap.MapError, .unknownCursor)
        }
        XCTAssertThrowsError(try map.token(zone: "RelayZone-hub-acme", cursor: 999))
    }
}
