/// Lets an answer that arrives later (a save panel, a print job) reach the
/// artifact panel only while it still shows what the action was raised on.
/// The panel calls `advance` whenever the shown artifact or version
/// changes; a delivery wrapped by `guarded` before that is dropped.
///
/// A reference type on purpose: the panel view keeps one in `@State`, and a
/// closure that captured a copy of the view struct still reads the live
/// epoch through it (a value captured from the struct would be frozen).
@MainActor
package final class ArtifactNoticeGate {
    private var epoch = 0

    package init() {}

    /// The panel now shows another artifact or version.
    package func advance() { epoch += 1 }

    /// `deliver`, called only if nothing was advanced since this call.
    package func guarded(_ deliver: @escaping (String) -> Void) -> (String) -> Void {
        let raisedOn = epoch
        return { [weak self] message in
            guard let self, self.epoch == raisedOn else { return }
            deliver(message)
        }
    }
}
