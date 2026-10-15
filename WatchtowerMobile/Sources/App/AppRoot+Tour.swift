import Foundation
import os
import WatchtowerSync

/// The signed build's demo (#174): Welcome's Try the Demo opens the demo
/// Macs without a Mac of one's own (App Review has none), and Exit Demo
/// returns to Welcome. The tour is its own root beside the live one: the
/// demo environment, its files in one sandbox directory and its settings
/// in one defaults suite, both cleared on entry and on exit, and no badge.
/// The live root is untouched meanwhile (it shows onboarding: no hub).
extension AppRoot {
    /// The tour's files: replicas, recordings and the hold.
    nonisolated static func tourDirectory() throws -> URL {
        try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("demo-tour", isDirectory: true)
    }

    /// The tour's settings suite.
    nonisolated static let tourDefaultsSuite = "demo-tour"

    /// A fresh tour: an earlier one's leftovers (a kill mid-tour) are
    /// removed first, so the seed always lands on empty replicas.
    static func tour(energy: EnergyCounter? = nil) throws -> AppRoot {
        let directory = try tourDirectory()
        clearTour(directory: directory)
        try FileProtection.protectDirectory(directory)
        guard let defaults = UserDefaults(suiteName: tourDefaultsSuite) else {
            throw CocoaError(.featureUnsupported)
        }
        let env = try AppEnvironment.demo(sandbox: directory, defaults: defaults, setBadge: { _ in }, energy: energy)
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
        do {
            Self.clearTour(directory: try Self.tourDirectory())
        } catch {
            Self.tourLogger.error("demo tour directory unresolved: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func clearTour(directory: URL) {
        UserDefaults().removePersistentDomain(forName: tourDefaultsSuite)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            tourLogger.error("demo tour files not removed: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated private static let tourLogger = Logger(subsystem: "WatchtowerMobile", category: "DemoTour")
}
