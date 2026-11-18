import Foundation

/// How a provider words its own plan-limit codes (#1885). `cloudProviders`
/// maps a `cloud_*` code to its full sentence; a code without an entry falls
/// to the shared "Couldn't update" text.
package struct SubscriptionUsageMessages: Sendable {
    package let cliMissing: String
    package let unsupportedCLI: String
    package let noCredentials: String
    package let unsupportedAuth: String
    package let cloudProviders: [String: String]
}

/// Subscription-specific storage and presentation capabilities, supplied by the
/// session adapter. They describe the published quota contract, not LLM routing.
package struct SubscriptionUsagePolicy: Sendable {
    package enum Layout: Equatable, Sendable { case compact, grouped }
    package let title: String
    package let signInApplication: String
    package let statusTable: String
    package let samplesTable: String
    package enum Storage: Equatable, Sendable { case legacy, identityScoped }
    package let storage: Storage
    package let defaultQuotaBucket: String?
    package let layout: Layout
    package let tint: String
    package let icon: String
    package var scopedIdentity: Bool { storage == .identityScoped }
    package var retainsSavedLimits: Bool { storage == .legacy }
    package let suppliesSurfaceBreakdown: Bool
    package let sendsNotifications: Bool
    package let messages: SubscriptionUsageMessages
    package var legacyDurations: Bool { storage == .legacy }
}
