import Foundation
import GRDB
import WatchtowerCore

/// Read-only status mirror for Gmail connection state — only `isConnected`
/// (via `checkStatus()`/`checkStatusAsync()`) is used anywhere in the app
/// (`GoogleConnectFlow.gmail`, read by `InboxFeedView`/
/// `GoogleConnectOptionsView`). Unlike its `GoogleAuthService` sibling, no
/// call site drives a standalone Gmail-only OAuth flow — that always goes
/// through `GoogleConnectFlow.connect()`'s combined consent — so this class
/// intentionally has no `connect()`/`cancelConnect()`.
@MainActor
@Observable
final class GmailAuthService {
    var isConnected: Bool = false

    private var dbPool: DatabasePool?

    init() {}

    /// Wires DB access once AppState's pool is available — see
    /// `GoogleAuthService.configure(dbPool:)` for why this can't happen at
    /// init. Called from `AppState.initGoogleAccounts`.
    func configure(dbPool: DatabasePool) {
        self.dbPool = dbPool
        checkStatus()
    }

    // MARK: - Status

    /// Fire-and-forget status refresh — DB-derived (any `google_accounts` row
    /// with `gmail_enabled=1 AND status='ok'`), unlike the old per-account-#1
    /// token-file stat, which only ever reflected a single account and
    /// couldn't distinguish Gmail from Calendar.
    func checkStatus() {
        Task { await checkStatusAsync() }
    }

    /// The awaitable body of `checkStatus()` — see `GoogleAuthService.
    /// checkStatusAsync()` for why callers needing a fresh value must await
    /// this directly instead of racing the fire-and-forget `checkStatus()`.
    func checkStatusAsync() async {
        guard let dbPool else {
            isConnected = false
            return
        }
        do {
            isConnected = try await dbPool.read { db in try GoogleAccountQueries.hasConnectedGmailAccount(db) }
        } catch {
            isConnected = false
        }
    }
}
