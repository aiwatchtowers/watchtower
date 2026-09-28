import Foundation

/// The chat's right-side inspector shows one of two panels.
package enum ChatInspectorMode: String, CaseIterable, Equatable, Sendable {
    case artifacts
    case sources
}

/// The sources panel's content: one finished answer's deduplicated sources.
package struct ChatSourcesSelection: Equatable, Sendable {
    package let messageID: Int64
    package let sources: [ChatSource]

    package init(messageID: Int64, sources: [ChatSource]) {
        self.messageID = messageID
        self.sources = ChatSource.dedupe(sources)
    }
}

/// The rule for sharing the one `.inspector` slot between the artifact panel
/// and the sources panel:
/// - the two are independent — opening one never closes the other, so an
///   artifact that was open (with its version pick) is still there when the
///   owner switches back from Sources, and vice versa;
/// - the tab the owner (or a streaming artifact) opened last is shown;
/// - closing the shown panel falls back to the other one if it is open;
/// - dismissing the whole inspector closes both.
package enum ChatInspectorPolicy {
    /// The panel to show, or nil when the inspector is closed.
    package static func visibleMode(
        preferred: ChatInspectorMode,
        artifactOpen: Bool,
        sourcesOpen: Bool
    ) -> ChatInspectorMode? {
        let open: (ChatInspectorMode) -> Bool = { $0 == .artifacts ? artifactOpen : sourcesOpen }
        if open(preferred) { return preferred }
        let other: ChatInspectorMode = preferred == .artifacts ? .sources : .artifacts
        return open(other) ? other : nil
    }

    /// Tabs appear only when both panels are open.
    package static func showsTabs(artifactOpen: Bool, sourcesOpen: Bool) -> Bool {
        artifactOpen && sourcesOpen
    }
}
