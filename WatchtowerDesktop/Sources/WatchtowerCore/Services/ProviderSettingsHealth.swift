import Foundation
import Observation

/// Saved-route metadata only. A timestamp passing is never a successful probe.
@MainActor
@Observable
package final class ProviderSettingsHealth {
    package private(set) var status: ChatRoutingStatus?
    package private(set) var busy = false
    package private(set) var failed = false
    private var operation = 0
    /// The rows the pair is read from (`reserve_peer`).
    @ObservationIgnored private let catalog: AIModelCatalog
    package init(catalog: AIModelCatalog = .shared) { self.catalog = catalog }
    package func invalidate() { operation += 1; status = nil; busy = false; failed = false }
    package func refresh(read: () async throws -> ChatRoutingStatus) async {
        operation += 1
        let current = operation
        busy = true; failed = false
        do {
            let value = try await read()
            guard current == operation else { return }
            status = value; busy = false
        } catch {
            guard current == operation else { return }
            status = nil; busy = false; failed = true
        }
    }
    package static let title = "Saved provider limits"
    package static let check = "Check again"
    package static let retry = "Retry limits check"
    package static let explanation = "Reads local quota metadata for the saved settings. Without a waiting safe task, no AI request is sent."
    package var copy: ProviderFallbackPreview.Copy? {
        if busy {
            return .init(title: "Checking saved provider limits…", detail: Self.explanation,
                         action: nil, emphasis: .neutral, busy: true)
        }
        if failed {
            return .init(title: "Couldn't read provider limits", detail: Self.explanation,
                         action: Self.retry, emphasis: .error)
        }
        guard let status else { return nil }
        if status.providers.contains(where: { $0.manualAllowed == .throttled }) {
            return .init(title: "Limits checked recently", detail: "Wait a minute before checking again. "
                            + "Saved quota blocks remain until a real request succeeds.",
                         action: Self.check, emphasis: .neutral)
        }
        let pair = catalog.fallbackPair(preferred: status.preferredProvider)
        let preferred = pair?.preferred ?? catalog.fallbackSide(status.preferredProvider)
        let primary = status.provider(status.preferredProvider)
        let reserve = pair.flatMap { status.provider($0.reserve.id) }
        let next = primary?.nextProbeAt?.formatted(date: .abbreviated, time: .shortened)
        if let pair, primary?.state == "quota_wait", reserve?.state == "quota_wait", status.enabled {
            return ProviderFallbackPreview(pair: pair, state: .bothLimited, nextCheck: next).copy
        }
        if primary?.state == "probe_leased" {
            if let pair, status.enabled, reserve?.state == "available" {
                return ProviderFallbackPreview(pair: pair, state: .probing, nextCheck: next).copy
            }
            return .init(title: "Checking \(preferred.name)'s recovery",
                         detail: "A waiting safe request is checking availability. Other requests may remain unavailable.",
                         action: nil, emphasis: .neutral, busy: true)
        }
        if primary?.state == "quota_wait" {
            return .init(title: "\(preferred.name) reached its limit",
                         detail: "Supported new requests may use the reserve when enabled."
                            + (next.map { " Next recovery check: \($0)." } ?? " The reset time is unknown."),
                         action: Self.check, emphasis: .warning)
        }
        if let pair, reserve?.state == "quota_wait" {
            return .init(title: "\(pair.reserve.name) reached its limit",
                         detail: "The preferred provider has no saved quota block. Reserve availability is checked on real requests.",
                         action: Self.check, emphasis: .warning)
        }
        return .init(title: "No saved quota block", detail: "Model access and quota are checked on real requests. This is not a connection test.",
                     action: nil, emphasis: .neutral)
    }
}
