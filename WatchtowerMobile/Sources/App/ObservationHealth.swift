import Foundation
import Observation

/// The replica observations that failed, by name: what Settings → Diagnostics
/// shows. `ResilientObservation` writes it; nothing else does.
@MainActor
@Observable
final class ObservationHealth {
    struct Failure: Equatable {
        var count: Int
        var lastMessage: String
        var lastAt: Date
        /// A value arrived after the last failure.
        var recovered: Bool
    }

    static let shared = ObservationHealth()

    private(set) var failures: [String: Failure] = [:]

    func recordFailure(_ name: String, error: any Error, at date: Date = Date()) {
        let count = (failures[name]?.count ?? 0) + 1
        failures[name] = Failure(count: count, lastMessage: error.localizedDescription, lastAt: date, recovered: false)
    }

    /// Called on every value; writes only for a name that has failed and not
    /// yet recovered, so a healthy observation never touches the model.
    func recordValue(_ name: String) {
        guard var failure = failures[name], !failure.recovered else { return }
        failure.recovered = true
        failures[name] = failure
    }
}
