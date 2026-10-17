import AppKit
import Observation
import WatchtowerCore

/// Whether any of the app's own windows is on screen (board #731), through
/// the pure `UIVisibilityPolicy`. Owned by `AppState`, which hands each
/// change to the UI pollers (`applyUIVisibility`): off screen — the app in
/// the tray, its windows minimised, hidden or covered — they skip their
/// refreshes, and they refresh once when a window shows again. What must
/// run in the background (notices, the mobile hub, session states,
/// recording) never reads it.
///
/// Every window and app notification that can change the answer schedules
/// one evaluation on the next main-actor turn, so a closing window is
/// already gone from `NSApp.windows` when it runs. Starts on screen until
/// the first evaluation: an unknown visibility must not freeze a view.
@MainActor
@Observable
final class UIVisibilityCenter {
    private(set) var isOnScreen = true

    /// Every change of `isOnScreen`. One subscriber: `AppState`.
    @ObservationIgnored var onChange: ((Bool) -> Void)?

    @ObservationIgnored private let notificationCenter: NotificationCenter
    @ObservationIgnored private let windows: () -> [UIVisibilityPolicy.Window]
    @ObservationIgnored private let appHidden: () -> Bool
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var evaluationScheduled = false

    init(
        notificationCenter: NotificationCenter = .default,
        windows: @escaping () -> [UIVisibilityPolicy.Window] = UIVisibilityCenter.liveWindows,
        appHidden: @escaping () -> Bool = { NSApp?.isHidden ?? false }
    ) {
        self.notificationCenter = notificationCenter
        self.windows = windows
        self.appHidden = appHidden
    }

    static func liveWindows() -> [UIVisibilityPolicy.Window] {
        (NSApp?.windows ?? []).map {
            UIVisibilityPolicy.Window(
                canBecomeMain: $0.canBecomeMain, isVisible: $0.isVisible,
                isMiniaturized: $0.isMiniaturized, isOccluded: !$0.occlusionState.contains(.visible)
            )
        }
    }

    /// Follows the notifications from now on and evaluates once. Idempotent.
    func start() {
        guard observers.isEmpty else { return }
        let names: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.willCloseNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSApplication.didHideNotification,
            NSApplication.didUnhideNotification,
            NSApplication.didBecomeActiveNotification
        ]
        observers = names.map { name in
            notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleEvaluation() }
            }
        }
        evaluate()
    }

    func stop() {
        observers.forEach(notificationCenter.removeObserver)
        observers = []
    }

    /// Computes the answer now; `onChange` only on a change.
    func evaluate() {
        evaluationScheduled = false
        let next = UIVisibilityPolicy.isOnScreen(windows(), appHidden: appHidden())
        guard next != isOnScreen else { return }
        isOnScreen = next
        onChange?(next)
    }

    private func scheduleEvaluation() {
        guard !evaluationScheduled else { return }
        evaluationScheduled = true
        Task { @MainActor [weak self] in self?.evaluate() }
    }
}
