import Foundation
import Observation
import WatchtowerCore

/// Opens the onboarding database: the CLI migrations, then the pool. That
/// can take up to 30 s, so it runs on a thread of its own — never the main
/// actor (the onboarding window stays live) nor the concurrency pool — and
/// `isOpening` drives the progress line. Steps that ask while an open runs
/// (sync done, chat finished, Retry) wait for that same open, and once it
/// succeeded they get the same manager: the migrations run once.
@MainActor
@Observable
final class OnboardingDatabaseOpener {
    private(set) var isOpening = false

    @ObservationIgnored private let openDatabase: @Sendable () throws -> DatabaseManager
    @ObservationIgnored private var inFlight: Task<Result<DatabaseManager, Error>, Never>?
    @ObservationIgnored private var opened: DatabaseManager?

    init(open: @escaping @Sendable () throws -> DatabaseManager = { try DatabaseManager.migrateAndOpen() }) {
        openDatabase = open
    }

    func open() async -> Result<DatabaseManager, Error> {
        if let opened { return .success(opened) }
        if let inFlight { return await inFlight.value }
        let openDatabase = openDatabase
        let task = Task { await ProcessPipes.offPool { Result { try openDatabase() } } }
        inFlight = task
        isOpening = true
        let result = await task.value
        inFlight = nil
        isOpening = false
        opened = try? result.get()
        return result
    }
}
