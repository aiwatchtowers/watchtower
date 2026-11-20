import Foundation
import WatchtowerCore
@testable import WatchtowerDesktop

/// The API-token sheet (#1887 Task 27, screens spec §6.2), rendered by the
/// production `AtlassianTokenSheet` over a model held in each state. Sample
/// data only (`acme`, `example.com`, a made-up token).
@MainActor
enum CompanyTokenShots {
    private static let token = "sample-token"

    private static func filled(
        _ phase: AtlassianTokenFormModel.Phase, site: String = "acme.atlassian.net"
    ) -> AtlassianTokenFormModel {
        AtlassianTokenFormModel.preview(phase, email: "alice@example.com", site: site, token: token)
    }

    /// Each scene's name (`company-token-<name>`) and its model.
    static var scenes: [(String, () -> AtlassianTokenFormModel)] {
        [
            ("empty", { AtlassianTokenFormModel.preview(.form, email: "", site: "", token: "") }),
            ("ready", { filled(.form) }),
            ("checking", { filled(.checking) }),
            ("unauthorized", { filled(.problem(.unauthorized)) }),
            ("missingScope", { filled(.problem(.missingScope("read:jira-work"))) }),
            ("notCloud", { filled(.problem(.notCloud("acme.example.com")), site: "acme.example.com") }),
            ("network", { filled(.problem(.network(host: "acme.atlassian.net", detail: "the request timed out"))) }),
            ("done", { filled(.done(host: "acme.atlassian.net", email: "alice@example.com")) }),
            ("replace", {
                let mode = AtlassianTokenFormModel.Mode.replace(accountID: 2, email: "bob@example.com",
                                                                site: "https://beta.atlassian.net")
                return AtlassianTokenFormModel.preview(.form, mode: mode, email: "bob@example.com",
                                                       site: "beta.atlassian.net", token: "")
            })
        ]
    }
}
