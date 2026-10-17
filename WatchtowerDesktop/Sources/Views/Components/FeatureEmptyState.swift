import SwiftUI
import WatchtowerCore

/// A tab's honest empty state: what lands here, when it will, and the one
/// thing to do now. No `@Environment(AppState.self)`: values and closures
/// only, so ViewInspector can drive it (the `BriefingsEmptyState` pattern).
struct FeatureEmptyState<Extra: View>: View {
    let copy: EmptyStateCopy
    /// nil until `ReadinessCenter` has evaluated: no readiness line and no
    /// state-gated button.
    let readiness: Readiness?
    /// `SyncProgress.summary` while preparing or waiting for the first sync.
    let syncLine: String?
    let turnOnError: String?
    let isTurningOn: Bool
    /// What Turn on switches on (`FeatureReadiness.turnOnFeatureID`); nil =
    /// the copy's own feature.
    let turnOnFeatureID: String?
    let onAction: (EmptyStateAction) -> Void
    /// Tab-specific content kept inside (cheat sheet, `NoOwnerEmptyState`, Generate).
    let extra: Extra

    init(
        copy: EmptyStateCopy,
        readiness: Readiness?,
        syncLine: String?,
        turnOnError: String?,
        isTurningOn: Bool,
        turnOnFeatureID: String? = nil,
        onAction: @escaping (EmptyStateAction) -> Void,
        @ViewBuilder extra: () -> Extra
    ) {
        self.copy = copy
        self.readiness = readiness
        self.syncLine = syncLine
        self.turnOnError = turnOnError
        self.isTurningOn = isTurningOn
        self.turnOnFeatureID = turnOnFeatureID
        self.onAction = onAction
        self.extra = extra()
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: copy.icon)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(copy.title)
                .font(.headline)
            Text(copy.landsHere)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if let line = Self.readinessLine(readiness) {
                Text(line)
                    .font(.callout)
            }
            if let syncLine = Self.visibleSyncLine(readiness, syncLine) {
                Text(syncLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let action = Self.visibleAction(
                copy: copy, readiness: readiness, turnOnError: turnOnError, turnOnFeatureID: turnOnFeatureID
            ) {
                HStack(spacing: 8) {
                    Button(Self.label(for: action, retry: turnOnError != nil, ownFeatureID: copy.feature?.featureID)) {
                        onAction(action)
                    }
                        .buttonStyle(.borderedProminent)
                        .disabled(isTurningOn)
                    if isTurningOn, case .turnOn = action {
                        ProgressView().controlSize(.small)
                    }
                }
                if case .turnOn = action, let turnOnError {
                    Text(turnOnError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            }
            extra
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    /// Hidden while ready (the tab shows its content) and before the first evaluation.
    static func readinessLine(_ readiness: Readiness?) -> String? {
        guard let readiness, readiness != .ready else { return nil }
        return FeatureReadiness.line(readiness)
    }

    /// The live sync line while preparing or waiting, unless the readiness
    /// line already carries it.
    static func visibleSyncLine(_ readiness: Readiness?, _ syncLine: String?) -> String? {
        guard let syncLine, !syncLine.isEmpty else { return nil }
        switch readiness {
        case .preparing, .waitingForSync:
            return readinessLine(readiness)?.contains(syncLine) == true ? nil : syncLine
        default:
            return nil
        }
    }

    /// The one button: Turn on while off (for a feature with a switch), Turn
    /// on Slack Digests while the feature waits on it, Connect while its
    /// source is missing, otherwise (daemon down included: Start lives in
    /// the app-wide banner) the tab's own action —
    /// never a Turn on or Connect the state doesn't call for. A failed Turn
    /// on keeps its retry: an enable whose restart failed leaves the feature
    /// on (no longer `.off`), and only the retry restarts the daemon.
    static func visibleAction(
        copy: EmptyStateCopy, readiness: Readiness?, turnOnError: String? = nil, turnOnFeatureID: String? = nil
    ) -> EmptyStateAction? {
        guard let readiness else {
            return copy.primaryAction.flatMap { isStateGated($0) ? nil : $0 }
        }
        let turnOnID = turnOnFeatureID ?? copy.feature?.featureID
        switch readiness {
        case .off, .needsDigests:
            return turnOnID.map { .turnOn(featureID: $0) }
        case .needsSource(let source):
            return .connect(source)
        default:
            if turnOnError != nil, let featureID = turnOnID {
                return .turnOn(featureID: featureID)
            }
            return copy.primaryAction.flatMap { isStateGated($0) ? nil : $0 }
        }
    }

    /// A Turn on of another feature names it: on Tracks or People it starts
    /// Slack Digests, a heavy one (#575).
    static func label(for action: EmptyStateAction, retry: Bool = false, ownFeatureID: String? = nil) -> String {
        switch action {
        case .turnOn(let featureID):
            if retry {
                "Try again"
            } else if featureID != ownFeatureID, featureID == ReadinessFeature.digests.featureID {
                "Turn on Slack Digests"
            } else {
                "Turn on"
            }
        case .connect(let source): "Connect \(source.displayName)"
        case .openSettings(_, let label): label
        case .tabAction(let label): label
        }
    }

    private static func isStateGated(_ action: EmptyStateAction) -> Bool {
        switch action {
        case .turnOn, .connect: true
        case .openSettings, .tabAction: false
        }
    }
}

extension FeatureEmptyState where Extra == EmptyView {
    init(
        copy: EmptyStateCopy,
        readiness: Readiness?,
        syncLine: String?,
        turnOnError: String?,
        isTurningOn: Bool,
        onAction: @escaping (EmptyStateAction) -> Void
    ) {
        self.init(
            copy: copy, readiness: readiness, syncLine: syncLine, turnOnError: turnOnError,
            isTurningOn: isTurningOn, onAction: onAction
        ) { EmptyView() }
    }
}

extension SettingsTab {
    /// The tab an `EmptyStateAction.openSettings(tab:label:)` names; nil for a
    /// name no tab has, so a typo in the copy table fails a test instead of
    /// opening the wrong tab.
    init?(emptyStateTab name: String) {
        switch name {
        case "general": self = .general
        case "connections": self = .connections
        case "features": self = .features
        case "meetings": self = .meetings
        case "system": self = .system
        case "mobile": self = .mobile
        case "profile": self = .profile
        default: return nil
        }
    }
}
