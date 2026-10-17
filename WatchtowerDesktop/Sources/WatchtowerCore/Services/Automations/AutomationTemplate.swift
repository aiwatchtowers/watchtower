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

    /// A workbench a workbench template can go into.
    package struct Workbench: Equatable, Sendable, Identifiable {
        package let id: Int64
        package let name: String

        package init(id: Int64, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// What **Use template** does (#582). The gallery passes no `--param`:
    /// `install-template` chooses a param's value itself.
    package enum InstallChoice: Equatable, Sendable {
        /// Install at once (a personal template, or the only workbench).
        case install(workbenchID: Int64?)
        /// A workbench template with several workbenches: the button is a menu of them.
        case pickWorkbench([Workbench])
        /// A workbench template and no workbench yet: the button is off.
        case needsWorkbench
    }

    /// "Covers: PAY, OPS" from `install-template --json` `params`, values in
    /// install order, keys sorted; nil when the template had no param.
    package static func coverageLine(_ params: [String: [String]]) -> String? {
        let values = params.keys.sorted().flatMap { params[$0] ?? [] }
        return values.isEmpty ? nil : "Covers: " + values.joined(separator: ", ")
    }

    package static func installChoice(_ template: AutomationTemplate, workbenches: [Workbench]) -> InstallChoice {
        guard template.scope == "workbench" else { return .install(workbenchID: nil) }
        switch workbenches.count {
        case 0: return .needsWorkbench
        case 1: return .install(workbenchID: workbenches[0].id)
        default: return .pickWorkbench(workbenches)
        }
    }
}
