/// Every user-facing string of the tower client and the screens that share
/// it (mockup §6 phone, §7 Mac Inbox states, §8 tray and other screens).
/// `TowerTextTests` pins each one.
public enum TowerText {
    /// Shown once the tower has been down for `TowerTiming.reconnectingLineAfter`.
    public static let reconnecting = "Reconnecting to Watchtower…"
    /// `failed(.down)`: the tower stayed down for `TowerTiming.failAfter`.
    public static let daemonDown = "Watchtower's background service isn't running"
    /// `failed(.version)`: `tower.hello` answered another interface version.
    public static let differentVersion = "Watchtower's background service is a different version."
    public static let retry = "Retry"
    public static let restart = "Restart"
    /// An action answered `unknown`, on the Mac (mockup §8): the screen re-reads.
    public static let didntConfirmMac = "Didn't confirm — checking again…"
    /// An action answered `unknown`, on the phone (mockup §6).
    public static let didntConfirmPhone = "Didn't confirm — check on the Mac."
    public static let refresh = "Refresh"
    /// The tray's status line while the owner's pause holds.
    public static let syncPaused = "Sync paused"
    public static let pauseSync = "Pause Sync"
    public static let resumeSync = "Resume Sync"
    /// An `ok` answer whose result does not decode (a client and daemon out of step).
    public static let unreadableAnswer = "Watchtower sent an answer this app can't read."
    /// A request whose params did not encode.
    public static let couldNotSend = "This request couldn't be sent to Watchtower."
}
