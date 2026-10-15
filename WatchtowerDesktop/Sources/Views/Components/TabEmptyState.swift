import SwiftUI
import WatchtowerCore

/// What a tab's empty state reads from `AppState`, as values and closures —
/// `AppState.emptyStateContext` builds it, tests pass their own, so the tab
/// empty states stay free of `@Environment(AppState.self)`.
struct EmptyStateContext {
    var readiness: (ReadinessFeature) -> Readiness? = { _ in nil }
    /// The live sync line (`SyncProgress.summary`) while a sync runs.
    var syncLine: String?
    var briefingHour = 8
    var dayPlanHour = 8
    var turnOnError: (String) -> String? = { _ in nil }
    var isTurningOn: (String) -> Bool = { _ in false }
    /// Turn on, Connect and Open Settings; a tab's own action is the tab's.
    var perform: (EmptyStateAction) -> Void = { _ in }

    /// Before `AppState` hands a real one in: no readiness line, no
    /// state-gated button.
    static let neutral = Self()
}

/// `FeatureEmptyState` for one sidebar tab: its copy (`EmptyStateCopyTable`),
/// its feature's readiness and Turn on state from the context, the tab's own
/// action, and what the tab keeps inside (`extra`).
struct TabEmptyState<Extra: View>: View {
    let destination: SidebarDestination
    let context: EmptyStateContext
    let onTabAction: () -> Void
    let extra: Extra

    /// No defaulted closure ahead of `extra` on purpose: a trailing
    /// `{ if … }` would otherwise bind to `onTabAction` (it type-checks as a
    /// Void closure) and silently drop the tab's content.
    init(_ destination: SidebarDestination, context: EmptyStateContext, @ViewBuilder extra: () -> Extra) {
        self.init(destination, context: context, onTabAction: {}, extra: extra)
    }

    init(
        _ destination: SidebarDestination,
        context: EmptyStateContext,
        onTabAction: @escaping () -> Void,
        @ViewBuilder extra: () -> Extra
    ) {
        self.destination = destination
        self.context = context
        self.onTabAction = onTabAction
        self.extra = extra()
    }

    var body: some View {
        if let copy = EmptyStateCopyTable.copy(
            for: destination.rawValue, briefingHour: context.briefingHour, dayPlanHour: context.dayPlanHour
        ) {
            let featureID = copy.feature?.featureID
            FeatureEmptyState(
                copy: copy,
                readiness: copy.feature.flatMap(context.readiness),
                syncLine: context.syncLine,
                turnOnError: featureID.flatMap(context.turnOnError),
                isTurningOn: featureID.map(context.isTurningOn) ?? false,
                onAction: { action in
                    if case .tabAction = action {
                        onTabAction()
                    } else {
                        context.perform(action)
                    }
                },
                extra: { extra }
            )
        } else {
            extra
        }
    }
}

extension TabEmptyState where Extra == EmptyView {
    init(_ destination: SidebarDestination, context: EmptyStateContext) {
        self.init(destination, context: context) { EmptyView() }
    }
}

/// For a tab whose own "nothing here" is news while its feature has content
/// (no blockers, nothing upcoming): that view while the feature is `.ready`,
/// the shared empty state otherwise.
struct ContentAwareEmptyState<Own: View>: View {
    let destination: SidebarDestination
    let context: EmptyStateContext
    let own: Own

    init(_ destination: SidebarDestination, context: EmptyStateContext, @ViewBuilder own: () -> Own) {
        self.destination = destination
        self.context = context
        self.own = own()
    }

    var body: some View {
        if hasContent {
            own
        } else {
            TabEmptyState(destination, context: context)
        }
    }

    private var hasContent: Bool {
        let copy = EmptyStateCopyTable.copy(for: destination.rawValue, briefingHour: 8, dayPlanHour: 8)
        guard let feature = copy?.feature else { return false }
        return context.readiness(feature) == .ready
    }
}
