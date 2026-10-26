import Foundation

/// One row of the project page's Knowledge card (spec 2026-10-26 §7): the
/// project's files and its pinned sources in one list, files first, each
/// part in its stored order, with a kind badge.
package struct ProjectKnowledgeItem: Identifiable, Equatable, Sendable {
    package enum Key: Hashable, Sendable {
        case file(Int64)
        case source(Int64)
    }

    package enum Kind: Equatable, Sendable {
        case pdf, markdown, image
        /// Any other file the attachment store accepts (a text file); the
        /// badge is its extension.
        case file(ext: String)
        case jira, slack, confluence, target, track, person
        /// A source kind this build does not know (a newer CHECK value).
        case otherSource
    }

    package let id: Key
    package let kind: Kind
    package let title: String

    package var isFile: Bool {
        if case .file = id { return true }
        return false
    }

    /// The short uppercase label drawn in the row's chip.
    package var badge: String {
        switch kind {
        case .pdf: "PDF"
        case .markdown: "MD"
        case .image: "IMAGE"
        case .file(let ext): ext.isEmpty || ext.count > 4 ? "FILE" : ext.uppercased()
        case .jira: "JIRA"
        case .slack: "SLACK"
        case .confluence: "CONFLUENCE"
        case .target: "TARGET"
        case .track: "TRACK"
        case .person: "PERSON"
        case .otherSource: "SOURCE"
        }
    }

    package static func merged(files: [ChatAttachment], sources: [ChatProjectSource]) -> [Self] {
        files.map { Self(id: .file($0.id), kind: kind(ofFile: $0), title: $0.name) }
            + sources.map { Self(id: .source($0.id), kind: kind(ofSource: $0), title: $0.label) }
    }

    static func kind(ofFile file: ChatAttachment) -> Kind {
        let ext = (file.name as NSString).pathExtension.lowercased()
        let mime = file.mime.lowercased()
        if mime == "application/pdf" || ext == "pdf" { return .pdf }
        if mime.hasPrefix("image/") { return .image }
        if mime == "text/markdown" || ext == "md" || ext == "markdown" { return .markdown }
        return .file(ext: ext)
    }

    static func kind(ofSource source: ChatProjectSource) -> Kind {
        switch source.sourceKind {
        case .jiraProject: .jira
        case .slackChannel: .slack
        case .confluenceSpace: .confluence
        case .target: .target
        case .track: .track
        case .person: .person
        case nil: .otherSource
        }
    }
}
