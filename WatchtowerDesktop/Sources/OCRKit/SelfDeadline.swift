import Foundation

/// The helper's own deadline. The Go parent kills it after 60 s, but a parent
/// that is itself SIGKILLed leaves the helper orphaned; this timer ends the
/// orphan on its own shortly after the parent would have.
public enum SelfDeadline {
    /// The parent's 60 s OCR timeout plus a 10 s margin.
    public static let seconds: TimeInterval = 70

    /// Calls `exit(2)` once `after` seconds pass, from a background queue —
    /// Vision's synchronous work on the main thread cannot hold it up.
    public static func arm(after: TimeInterval = seconds, exit: @escaping @Sendable (Int32) -> Void) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + after) { exit(2) }
    }
}
