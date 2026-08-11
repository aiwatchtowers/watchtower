import Foundation
import XCTest
@testable import WatchtowerDesktop

// MARK: - Fakes

/// Scriptable `MicRecording`. `start` never touches real hardware; a test
/// drives the stream directly with `emit`/`stop` (the `FakeRecorder`
/// precedent, minus the file: `Tests/Helpers/MeetingRecorderTestSupport.swift:11-49`).
final class FakeMicRecorder: MicRecording, @unchecked Sendable {
    var startError: Error?
    /// Settable: a test simulates "capture silently broke mid-stream" by
    /// setting this before finishing the (empty) stream.
    var lastError: Error?

    private(set) var startCalls = 0
    private(set) var stopCalls = 0

    private var continuation: AsyncStream<[Float]>.Continuation!
    let samples: AsyncStream<[Float]>

    init() {
        var c: AsyncStream<[Float]>.Continuation!
        samples = AsyncStream { c = $0 }
        continuation = c
    }

    /// Emit one chunk of samples (test drives the stream with this).
    func emit(_ samples: [Float]) { continuation.yield(samples) }

    func start() async throws {
        startCalls += 1
        if let startError { throw startError }
    }

    func stop() {
        stopCalls += 1
        continuation.finish()
    }
}
