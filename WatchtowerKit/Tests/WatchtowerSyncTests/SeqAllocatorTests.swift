import XCTest
@testable import WatchtowerSync

final class SeqAllocatorTests: XCTestCase {
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: UInt64 = 0
        var failStore = false
        var value: UInt64 { lock.withLock { stored } }
        func load() -> UInt64 { lock.withLock { stored } }
        func store(_ v: UInt64) throws {
            try lock.withLock {
                if failStore { throw KeyStoreError.unexpected(-1) }
                stored = v
            }
        }
    }

    private func allocator(_ box: Box, block: UInt64 = 4) -> SeqAllocator {
        SeqAllocator(blockSize: block, load: { box.load() }, store: { try box.store($0) })
    }

    func testValuesAreStrictlyIncreasingAcrossARestart() throws {
        let box = Box()
        let first = allocator(box)
        var last: UInt64 = 0
        for _ in 0..<6 { last = try first.next() }
        let second = allocator(box)
        XCTAssertGreaterThan(try second.next(), last)
        XCTAssertEqual(box.value % 4, 0)
    }

    func testANewAllocatorStartsAtTheStoredCeiling() throws {
        let box = Box()
        _ = try allocator(box).next()
        XCTAssertEqual(box.value, 4)
        XCTAssertEqual(try allocator(box).next(), 4)
    }

    func testTheCeilingIsPersistedBeforeAValueOfTheBlockIsReturned() {
        let box = Box()
        box.failStore = true
        let alloc = allocator(box)
        XCTAssertThrowsError(try alloc.next())
        box.failStore = false
        XCTAssertEqual(try alloc.next(), 0)
        XCTAssertEqual(box.value, 4)
    }

    func testConcurrentCallersNeverGetTheSameValue() async throws {
        let box = Box()
        let alloc = allocator(box, block: 16)
        let values = try await withThrowingTaskGroup(of: UInt64.self) { group in
            for _ in 0..<200 { group.addTask { try alloc.next() } }
            var all: [UInt64] = []
            for try await v in group { all.append(v) }
            return all
        }
        XCTAssertEqual(Set(values).count, 200)
    }
}
