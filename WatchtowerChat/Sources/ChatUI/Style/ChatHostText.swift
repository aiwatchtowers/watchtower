import SwiftUI

/// The lines that name the machine holding the chat (#1783): where the whole of a cut message or artifact is, and
/// where a Slack card's workspace is chosen. Each app injects its own (`.environment(\.chatHostText, …)`): the Mac its
/// own words, the phone the tower's name ("your tower" without one, `TowerWordGuardTests`). The default names no
/// machine and is meant for tests and previews.
public struct ChatHostText: Equatable, Sendable {
    public var messageCut: String
    public var artifactCut: String
    public var chooseSlackWorkspace: String

    public init(messageCut: String, artifactCut: String, chooseSlackWorkspace: String) {
        self.messageCut = messageCut
        self.artifactCut = artifactCut
        self.chooseSlackWorkspace = chooseSlackWorkspace
    }

    /// The lines with the machine's name in a sentence ("Acme Mac", "your tower").
    public init(hostName: String) {
        self.init(
            messageCut: "This message is cut here; the whole text is on \(hostName).",
            artifactCut: "This artifact is cut here; the whole text is on \(hostName).",
            chooseSlackWorkspace: "Choose a workspace on \(hostName) before approving"
        )
    }

    public static let plain = ChatHostText(hostName: "your tower")
}

private struct ChatHostTextKey: EnvironmentKey {
    static let defaultValue = ChatHostText.plain
}

extension EnvironmentValues {
    /// The lines that name the machine holding the chat; `ChatHostText.plain` unless the app injects its own.
    public var chatHostText: ChatHostText {
        get { self[ChatHostTextKey.self] }
        set { self[ChatHostTextKey.self] = newValue }
    }
}
