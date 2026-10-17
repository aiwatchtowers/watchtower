import Foundation
import WatchtowerCore

extension AppState {
    /// What the owner is looking at, for the assistant's never-stored
    /// current-screen block (in-app help).
    ///
    /// `status` is the readiness line while the tab shows its empty state: the
    /// tab has an `EmptyStateCopyTable` row with a feature and that feature is
    /// not `.ready` (the `ContentAwareEmptyState` signal; `.ready` means
    /// content is present). `selected` is the Workbench session on screen; the
    /// Targets, Digests and Calendar selections live in view `@State`, so they
    /// stay nil until that state is hoisted.
    func currentScreenContext() -> ScreenContext {
        let destination = selectedDestination
        let context = emptyStateContext
        var status: String?
        if let feature = EmptyStateCopyTable.copy(
            for: destination.rawValue, briefingHour: context.briefingHour, dayPlanHour: context.dayPlanHour
        )?.feature, let readiness = context.readiness(feature), readiness != .ready {
            status = FeatureReadiness.line(readiness)
        }
        let selected = destination == .workbench ? workbenchesViewModel?.headerSession?.title : nil
        return ScreenContext(tab: destination.title, status: status, selected: selected.flatMap { $0.isEmpty ? nil : $0 })
    }
}
