import SwiftUI

/// What the app adds to every composer field beyond ChatUI's own (environment `\.chatComposerServices`): the Mac's
/// dictation (its mic button and the highlight of the field being dictated into). The default adds nothing.
public struct ChatComposerServices {
    /// Wraps the field with the app's dictation for `targetID`, writing into `text`; nil draws the field alone.
    public var dictation: ((_ field: AnyView, _ text: Binding<String>, _ targetID: String) -> AnyView)?

    public init(dictation: ((_ field: AnyView, _ text: Binding<String>, _ targetID: String) -> AnyView)? = nil) {
        self.dictation = dictation
    }
}

private struct ChatComposerServicesKey: EnvironmentKey {
    static let defaultValue = ChatComposerServices()
}

extension EnvironmentValues {
    public var chatComposerServices: ChatComposerServices {
        get { self[ChatComposerServicesKey.self] }
        set { self[ChatComposerServicesKey.self] = newValue }
    }
}
