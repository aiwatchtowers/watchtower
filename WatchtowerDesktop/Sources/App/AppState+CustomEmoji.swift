import WatchtowerCore

extension AppState {
    /// The workspace's custom emoji, read once the database is open (moved
    /// out of `AppState.swift` to keep it under the file length limit).
    func loadCustomEmoji(from manager: DatabaseManager) {
        Task.detached {
            let map = try? await manager.dbPool.read { db in
                try CustomEmojiQueries.fetchEmojiMap(db)
            }
            await MainActor.run {
                self.customEmojiMap = map ?? [:]
            }
        }
    }
}
