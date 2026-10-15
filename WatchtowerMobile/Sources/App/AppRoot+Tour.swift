import Foundation
import Observation
import os

/// The signed build's demo (#174): Welcome's Try the Demo opens the demo
/// Macs without a Mac of one's own (App Review has none), and Exit Demo
/// returns to Welcome. The tour is its own root beside the live one: the
/// demo environment, its files in one sandbox directory and its settings
/// in one defaults suite, both cleared on entry, on exit and at launch, no
/// badge and no battery counts. The live root is untouched meanwhile (it
/// shows onboarding: no hub).
extension AppRoot {
    /// The tour's files: replicas, recordings and the hold.
    nonisolated static func tourDirectory() throws -> URL {
        try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("demo-tour", isDirectory: true)
    }

    /// The tour's settings suite.
    nonisolated static let tourDefaultsSuite = "demo-tour"

    /// A fresh tour: an earlier one's leftovers are removed first, so the
    /// seed always lands on empty replicas. Never while another tour's
    /// sessions are open (`DemoTour` waits for the last `endTour`).
    static func tour() throws -> AppRoot {
        let directory = try tourDirectory()
        clearTour(directory: directory)
        try FileProtection.protectDirectory(directory)
        guard let defaults = UserDefaults(suiteName: tourDefaultsSuite) else {
            throw CocoaError(.featureUnsupported)
        }
        let env = try AppEnvironment.demo(sandbox: directory, defaults: defaults) { _ in }
        return try demo(env, defaults: defaults)
    }

    /// Ends a tour: a demo recording running is stopped, every session shut
    /// down and its databases closed, then the tour's files and settings go.
    /// The caller has taken the tour off screen first.
    func endTour() async {
        for hubID in env.order {
            guard let session = env.session(hubID) else { continue }
            _ = await session.recorder.stopForWipe()
            await session.shutDown()
            session.closeDatabases()
        }
        Self.clearTourLeftovers()
    }

    /// Removes what a tour killed mid-way left (the live launch runs it: no
    /// tour is open then).
    nonisolated static func clearTourLeftovers() {
        do {
            clearTour(directory: try tourDirectory())
        } catch {
            tourLogger.error("demo tour directory unresolved: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated private static func clearTour(directory: URL) {
        UserDefaults().removePersistentDomain(forName: tourDefaultsSuite)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            tourLogger.error("demo tour files not removed: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated fileprivate static let tourLogger = Logger(subsystem: "WatchtowerMobile", category: "DemoTour")
}

/// The tour over a live root, as the app shows it: `start` puts a tour on
/// screen once the last one has ended (both use the same directory and
/// suite), `exit` takes it off and ends it. A link URL the tour receives
/// ends it and goes to the live root. A tour that cannot start leaves
/// `failure` for the owner.
@MainActor
@Observable
final class DemoTour {
    private(set) var root: AppRoot?
    private(set) var failure: String?

    @ObservationIgnored private let make: @MainActor () throws -> AppRoot
    /// The last `endTour` running: the next `start` waits for it.
    @ObservationIgnored private(set) var ending: Task<Void, Never>?

    init(make: @escaping @MainActor () throws -> AppRoot = { try AppRoot.tour() }) {
        self.make = make
    }

    /// Try the Demo over `live`. A second call while a tour is on screen or
    /// starting does nothing.
    func start(over live: AppRoot) async {
        guard root == nil else { return }
        await ending?.value
        guard root == nil else { return }
        do {
            let tour = try make()
            tour.forwardsLinks = { [weak self, weak live] url in
                self?.exit()
                Task { await live?.open(url) }
            }
            root = tour
        } catch {
            AppRoot.tourLogger.error("demo tour not started: \(error.localizedDescription, privacy: .public)")
            failure = "The demo could not start (\(error.localizedDescription))."
        }
    }

    /// Exit Demo: back to the live root, then the tour's sessions and files go.
    func exit() {
        guard let tour = root else { return }
        root = nil
        ending = Task { await tour.endTour() }
    }

    func dismissFailure() {
        failure = nil
    }
}
