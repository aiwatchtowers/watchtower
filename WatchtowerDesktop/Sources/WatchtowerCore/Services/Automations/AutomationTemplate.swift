import Foundation

/// One entry of `automations templates --json` (P6 part 2's
/// `cmd/automations_templates.go` `templateJSON`; `files` is ignored).
package struct AutomationTemplate: Decodable, Identifiable, Equatable, Sendable {
    /// A `<KEY>` placeholder; `install-template` chooses its value when the
    /// gallery installs without `--param` (#582).
    package struct Param: Decodable, Equatable, Sendable {
        package let key: String
        package let label: String
        package let example: String
    }

    package let name: String
    package let title: String
    package let description: String
    package let scope: String
    package let triggerText: String
    package let permissions: [String]
    package let outputs: [String]
    package let params: [Param]
    package let notes: [String]

    package var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, title, description, scope, permissions, outputs, params, notes
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
        params = try c.decodeIfPresent([Param].self, forKey: .params) ?? []
        notes = try c.decodeIfPresent([String].self, forKey: .notes) ?? []
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
