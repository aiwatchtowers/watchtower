import Foundation

package struct PlansPopupQuota: Identifiable, Equatable, Sendable {
    package let id: String
    package let duration: String
    package let percent: String
    package let reset: String
    package let forecast: String?
    package let tone: PlanUsageTone
    package let isSelected: Bool
}

package struct PlansPopupGroup: Identifiable, Equatable, Sendable {
    package let id: String
    package let title: String
    package var quotas: [PlansPopupQuota]
}

package struct PlansPopupProvider: Identifiable, Equatable, Sendable {
    package let id: PlanUsageProvider
    package let title: String
    package let plan: String
    package let freshness: String
    package let message: String?
    package let messageTone: PlanUsageTone
    package let action: String
    package let canRefresh: Bool
    package let compactUsage: String?
    package let primaryForecast: String?
    package let primaryTone: PlanUsageTone
    package let groups: [PlansPopupGroup]
}

/// Typed data for the production menu window. Quota calculations remain in Go.
package struct PlansPopupPresentation: Sendable {
    package let providers: [PlansPopupProvider]
    package let freshness: String
    package let refreshTitle: String
    package let canRefresh: Bool

    package init(screen: PlansScreenPresentation) {
        let menu = PlansMenuPresentation(screen: screen)
        refreshTitle = screen.refreshTitle
        canRefresh = screen.enabled && !screen.isRefreshing
        if screen.isRefreshing {
            freshness = PlansPopupCopy.refreshing
        } else if screen.providers.contains(where: { $0.hasError || ($0.status != nil && $0.presentation.isStale) }) {
            freshness = PlansPopupCopy.attention
        } else if Set(screen.providers.map { $0.presentation.freshness }).count == 1 {
            freshness = screen.providers.first?.presentation.freshness ?? PlansPopupCopy.notUpdated
        } else {
            freshness = PlansPopupCopy.independentUpdates
        }
        providers = screen.providers.enumerated().map { index, provider in
            let state = menu.providers[index]
            let selected: String?
            var selectionFailed = false
            if provider.id.subscription.layout == .grouped, let status = provider.status, screen.enabled {
                do { selected = try PlansPresentation.mostRestrictive(status, now: screen.now)?.key } catch {
                    selected = nil
                    selectionFailed = true
                }
            } else { selected = nil }
            let message = selectionFailed ? PlansPresentation.errorText("storage", provider: provider.id) : state.message
            let groups = selectionFailed ? [] : Self.groups(provider: provider, selected: selected, message: message)
            return PlansPopupProvider(id: provider.id, title: provider.presentation.title, plan: provider.planLabel,
                                      freshness: provider.presentation.freshness, message: message,
                                      messageTone: screen.enabled && (provider.hasError || selectionFailed ||
                                        provider.status?.ordinaryUsageAllowed == false) ? .warning : .muted,
                                      action: selectionFailed ? "Retry \(provider.presentation.title)" : state.action,
                                      canRefresh: state.canRefresh,
                                      compactUsage: provider.id.subscription.layout == .compact && screen.enabled ?
                                        PlanUsagePresentation.menuBarText(provider.status) : nil,
                                      primaryForecast: message == nil ? provider.primary?.forecast : nil,
                                      primaryTone: provider.primary?.line == nil && provider.primary?.tone == .normal ?
                                        .muted : provider.primary?.tone ?? .muted, groups: groups)
        }
    }

    private static func groups(provider: PlansScreenProvider, selected: String?, message: String?) -> [PlansPopupGroup] {
        var groups: [PlansPopupGroup] = []
        // Source durations, not primary/secondary positions, define the window label.
        let limits = provider.presentation.limits.sorted { lhs, rhs in
            let left = provider.status?.limits.first { $0.key == lhs.key }?.windowDurationMinutes ?? Int.max
            let right = provider.status?.limits.first { $0.key == rhs.key }?.windowDurationMinutes ?? Int.max
            return left == right ? lhs.key < rhs.key : left < right
        }
        for item in limits {
            guard let raw = provider.status?.limits.first(where: { $0.key == item.key }) else { continue }
            let bucket = provider.id.subscription.layout == .grouped ? PlansQuotaBucket.identifier(item.key) : nil
            let groupID = bucket.map { "bucket:\($0)" } ?? "opaque:\(item.key)"
            let title = bucket.map {
                bucketTitle($0, label: raw.label, minutes: raw.windowDurationMinutes, policy: provider.id.subscription)
            } ?? raw.label
            let quota = PlansPopupQuota(
                id: item.key, duration: PlansPresentation.duration(raw.windowDurationMinutes),
                percent: item.percent, reset: item.reset,
                forecast: item.forecast == message ? nil : item.forecast,
                tone: item.tone == .normal && item.line == nil ? .muted : item.tone,
                isSelected: item.key == selected
            )
            if let index = groups.firstIndex(where: { $0.id == groupID }) {
                groups[index].quotas.append(quota)
            } else { groups.append(PlansPopupGroup(id: groupID, title: title, quotas: [quota])) }
        }
        if let bucket = provider.id.subscription.defaultQuotaBucket,
           let index = groups.firstIndex(where: { $0.id == "bucket:\(bucket)" }), index != 0 {
            let main = groups.remove(at: index)
            groups.insert(main, at: 0)
        }
        return groups
    }

    private static func bucketTitle(_ bucket: String, label: String, minutes: Int?, policy: SubscriptionUsagePolicy) -> String {
        let parts = label.components(separatedBy: " · ")
        if parts.count > 1 {
            let windowNames = ["Weekly", "5 hours", "5-hour window", "\(minutes ?? 0) minutes"]
            if windowNames.contains(parts[0]) { return parts.dropFirst().joined(separator: " · ") }
            if let last = parts.last, windowNames.contains(last) { return parts.dropLast().joined(separator: " · ") }
        }
        return bucket == policy.defaultQuotaBucket ? policy.title : bucket
    }
}

/// The Go reader prefixes the bucket's UTF-8 byte count, so ':' and Unicode
/// identifiers cannot collide. Opaque/older keys stay separate; no quota is dropped.
package enum PlansQuotaBucket {
    package static func identifier(_ key: String) -> String? {
        let bytes = Array(key.utf8)
        guard let separator = bytes.firstIndex(of: 58), separator > 0,
              let prefix = String(bytes: bytes[..<separator], encoding: .utf8),
              let length = Int(prefix), length > 0,
              length < bytes.count - separator else { return nil }
        let start = separator + 1
        let end = start + length
        guard end < bytes.count, bytes[end] == 58,
              let bucket = String(bytes: bytes[start..<end], encoding: .utf8) else { return nil }
        guard let tail = String(bytes: bytes[(end + 1)...], encoding: .utf8) else { return nil }
        let suffix = tail.split(separator: ":", omittingEmptySubsequences: false)
        guard suffix.count == 2, ["primary", "secondary"].contains(String(suffix[0])),
              suffix[1] == "unknown" || (Int64(suffix[1]).map { $0 > 0 } ?? false) else { return nil }
        return bucket
    }
}

package enum PlansPopupCopy {
    package static let title = "Plans & limits"
    package static let actions = "Watchtower actions"
    package static let selected = "In menu bar"
    package static let refreshing = "Refreshing…"
    package static let attention = "Needs attention"
    package static let notUpdated = "Not updated yet"
    package static let independentUpdates = "Updated independently"
}
