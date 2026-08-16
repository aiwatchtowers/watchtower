import Foundation

/// App-wide store of which feature ids are currently disabled, read by the
/// sidebar filter, the navigation fallback, and the Dashboard banner to
/// decide what to show. Deliberately minimal: this store only holds the
/// state — a parallel lane wires in the service that populates
/// `disabledFeatureIDs` from the Feature Manager config. Until that's wired,
/// the set stays empty and every tab is visible (fail-open).
@MainActor
@Observable
final class FeatureVisibilityStore {
    var disabledFeatureIDs: Set<String> = []
}
