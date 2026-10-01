import Foundation

/// The Documents pane's list structure (#81): collapsible groups by kind —
/// Specs, Plans, Docs, then Imported (the setup scan's files, whatever their
/// kind) — filtered by a title search. Order inside a group is the list's own
/// (most recently updated first). Pure.
package enum ProjectDocumentGrouping {
    package enum Group: String, CaseIterable, Sendable {
        case specs, plans, docs, imported

        package var title: String {
            switch self {
            case .specs: "Specs"
            case .plans: "Plans"
            case .docs: "Docs"
            case .imported: "Imported"
            }
        }

        static func of(_ document: ProjectDocument) -> Self {
            if document.origin == "import" { return .imported }
            switch document.kind {
            case "spec": return .specs
            case "plan": return .plans
            default: return .docs
            }
        }
    }

    package struct Section: Identifiable, Equatable, Sendable {
        package let group: Group
        package let items: [ProjectDocumentListItem]

        package var id: Group { group }
    }

    /// Non-empty groups in fixed order. `query` matches the display title or
    /// the path, ignoring case and diacritics; blank = everything.
    package static func sections(_ items: [ProjectDocumentListItem], query: String) -> [Section] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = needle.isEmpty ? items : items.filter { item in
            [item.document.displayTitle, item.document.relPath].contains {
                $0.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
        let grouped = Dictionary(grouping: matching) { Group.of($0.document) }
        return Group.allCases.compactMap { group in
            grouped[group].map { Section(group: group, items: $0) }
        }
    }
}
