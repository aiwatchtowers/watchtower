import Foundation

/// One entry of `automations templates --json` (P6's contract, pinned in plan
/// Task 13). P6 may add `files`, `params` and `installed`; they are ignored.
package struct AutomationTemplate: Decodable, Identifiable, Equatable, Sendable {
    package let name: String
    package let title: String
    package let description: String
    package let scope: String
    package let triggerText: String
    package let permissions: [String]
    package let outputs: [String]

    package var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, title, description, scope, permissions, outputs
        case triggerText = "trigger_text"
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? name
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        scope = try c.decodeIfPresent(String.self, forKey: .scope) ?? "personal"
        triggerText = try c.decodeIfPresent(String.self, forKey: .triggerText) ?? ""
        permissions = try c.decodeIfPresent([String].self, forKey: .permissions) ?? []
        outputs = try c.decodeIfPresent([String].self, forKey: .outputs) ?? []
    }
}

/// What a gallery card says about a template.
package enum AutomationTemplateGallery {
    /// The card's one line: when it runs, then what it may read or do
    /// (P6's `trigger_text` and `permissions`), empty parts left out.
    package static func summaryLine(_ template: AutomationTemplate) -> String {
        ([template.triggerText] + template.permissions)
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}
