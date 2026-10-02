import Foundation
import WatchtowerCore

/// App-wide store of which feature ids are currently disabled, read by the
/// sidebar filter, the navigation fallback, and the Dashboard banner to
/// decide what to show. Deliberately minimal: it only holds the state.
/// `AppState` populates it by wiring `FeatureManagerService.onDisabledChanged`
/// into `disabledFeatureIDs`, so the set stays empty — every tab visible,
/// fail-open — until the first successful `features list` load.
/// `connectedSources` is the second axis (tabs that need Slack/mail,
/// a calendar or Jira); `AppState.refreshConnectedSources()` fills it on DB
/// open and on every account-list reload, fail-open (`.all`) until then.
@MainActor
@Observable
final class FeatureVisibilityStore {
    var disabledFeatureIDs: Set<String> = []
    var connectedSources: ConnectedSources = .all
}
