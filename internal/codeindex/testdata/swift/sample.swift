import Foundation

/// A shape with an area.
protocol Shape: Sendable {
    /// The area in square units.
    var area: Double { get }
    func describe() -> String
    init(size: Int)
}

/// A point on a grid. Immutable.
struct Point: Equatable {
    let x: Int
    var y: Int = 0
    var sum: Int { x + y }

    /// Returns the point moved by one step.
    func moved(by step: Int = 1) -> Point {
        Point(x: x + step, y: y)
    }
}

// A plain comment is not a doc.
enum Direction {
    case up, down

    /// The opposite direction.
    func flipped() -> Direction {
        self == .up ? .down : .up
    }

    static func all() -> [Direction] { [.up, .down] }
}

/**
 Keeps values by key.
 */
actor Cache<Key: Hashable & Sendable, Value: Sendable> {
    private var store: [Key: Value] = [:]

    func value(for key: Key) -> Value? { store[key] }
}

extension Point {
    /// The origin.
    static let origin = Point(x: 0, y: 0)

    func distance(to other: Point) -> Int {
        abs(other.x - x) + abs(other.y - y)
    }
}

typealias Grid = [[Point]]

/// A view model the main actor owns.
@MainActor
final class CounterModel {
    private(set) var count = 0

    init() {}

    func increment(by step: Int = 1) async throws -> Int {
        let previous = count
        count += step
        #expect(count > previous)
        return count
    }

    func reset() {
        count = 0
    }
}

let 🙂 = 1; func après() {}

var counter = 0
