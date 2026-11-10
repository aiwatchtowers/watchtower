import Foundation

/// The editor chat's Inbox folder suggestion: `draft_automation`'s `folder`
/// argument, cached with the draft (Go `authoring.FolderSuggestion`,
/// inbox builder B "Creating a folder from the editor"). A folder title and
/// the slug of the folder it sits in ("" = the root). Placement, not part of
/// the recipe: it never reaches the approval hash.
package struct AutomationFolderSuggestion: Decodable, Equatable, Sendable {
    package let title: String
    package let parentSlug: String

    package init(title: String, parentSlug: String = "") {
        self.title = title
        self.parentSlug = parentSlug
    }

    enum CodingKeys: String, CodingKey {
        case title, parentSlug = "parent_slug"
    }

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title).trimmingCharacters(in: .whitespacesAndNewlines)
        parentSlug = try c.decodeIfPresent(String.self, forKey: .parentSlug) ?? ""
        guard !title.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .title, in: c, debugDescription: "an empty folder title")
        }
    }

    /// Where a save puts the automation's cards (the line and the route):
    /// a folder of this title already in the parent (ignoring case) is
    /// reused, else a new one is made there. The parent is the folder of
    /// `parentSlug`, or the root when the slug is empty, unknown or Needs
    /// approval's (no folder sits under it).
    package func route(in tree: InboxFolderTree) -> InboxNewArtifactRoute {
        let parent = tree.folders.first { !parentSlug.isEmpty && $0.slug == parentSlug && $0.kind != .approvals }
            ?? tree.root
        if let existing = tree.folders.first(where: {
            $0.kind == .owner && $0.parentID == parent.id && $0.title.caseInsensitiveCompare(title) == .orderedSame
        }) {
            return InboxNewArtifactRoute(folderID: existing.id, title: existing.title)
        }
        return InboxNewArtifactRoute(newFolder: title, parentID: parent.kind == .root ? nil : parent.id,
                                     parentTitle: parent.title)
    }
}
