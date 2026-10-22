import Foundation
import WatchtowerCore

/// A `CustomTrackControlling` that only records what the card or the Inbox
/// view model asked of it, in order; `failure` makes every call throw.
@MainActor
package final class RecordingCustomTrackControls: CustomTrackControlling {
    package enum Call: Equatable {
        case saveInstruction(trackID: Int, text: String)
        case setCollecting(trackID: Int, on: Bool)
        case scan(trackID: Int, from: Date)
        case stopWatching(trackID: Int)
    }

    package private(set) var calls: [Call] = []
    package var failure: Error?

    package init() {}

    package func saveInstruction(_ track: Track, text: String) async throws {
        try record(.saveInstruction(trackID: track.id, text: text))
    }

    package func setCollecting(_ track: Track, on: Bool) async throws {
        try record(.setCollecting(trackID: track.id, on: on))
    }

    package func scan(_ track: Track, from: Date) async throws {
        try record(.scan(trackID: track.id, from: from))
    }

    package func stopWatching(_ track: Track) async throws {
        try record(.stopWatching(trackID: track.id))
    }

    private func record(_ call: Call) throws {
        calls.append(call)
        if let failure { throw failure }
    }
}
