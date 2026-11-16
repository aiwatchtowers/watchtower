/// `TowerClient`'s timing (mobile Inbox spec §3 "Reconnecting").
public enum TowerTiming {
    /// The first reconnect attempt after a drop; each next one waits twice as long.
    public static let retryStart: Duration = .milliseconds(200)
    /// The longest wait between two reconnect attempts.
    public static let retryMax: Duration = .seconds(2)
    /// "Reconnecting to Watchtower…" shows only once the tower has been down
    /// this long, so an ordinary daemon restart shows nothing.
    public static let reconnectingLineAfter: Duration = .seconds(1)
    /// Down this long, the client gives up: `failed` with Retry.
    public static let failAfter: Duration = .seconds(15)
}
