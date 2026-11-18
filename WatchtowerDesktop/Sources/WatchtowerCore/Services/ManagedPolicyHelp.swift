import Foundation

/// The IT guide (D21): the public page that lists every key a configuration
/// profile can force, with a sample profile. Every link to it goes through
/// here; `itGuideURL` equals Go's `policy.ITGuideURL`, which the Go side
/// golden-writes to `docs/mdm/site.json` (`ManagedPolicyHelpTests`).
package enum ManagedPolicyHelp {
    // A fixed https string always parses.
    package static let itGuideURL = URL(string: "https://aiwatchtowers.com/guide/mdm/")!
    package static let label = "What IT can set"
    package static let rowTitle = "IT guide"
    package static let rowCaption = "Every setting a configuration profile can force, with a sample profile."
}
