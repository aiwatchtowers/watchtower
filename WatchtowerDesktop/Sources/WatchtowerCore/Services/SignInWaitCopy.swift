import Foundation

/// The texts of a browser sign-in that waits for the owner (`SignInWaitLine`):
/// what it waits for, why Cancel may be needed, and the button. One copy for
/// every connector, so the line reads the same wherever a sign-in runs.
package struct SignInWaitCopy: Equatable, Sendable {
    /// Who the browser signs in to: "Google", "Slack", "Atlassian", a
    /// connection's own name.
    package let service: String

    package init(service: String) {
        self.service = service
    }

    package var line: String { "Waiting for the \(service) sign-in in your browser…" }
    package var hint: String { "If the page shows an error or you closed it, press Cancel." }
    package var cancelTitle: String { "Cancel" }

    package static let google = Self(service: "Google")
    package static let slack = Self(service: "Slack")
    package static let atlassian = Self(service: "Atlassian")
    package static let linear = Self(service: "Linear")
    package static let microsoft = Self(service: "Microsoft")
}
