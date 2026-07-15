import Foundation

/// The single list of transcription engines. Add a provider = add one line here.
enum TranscriptionProviderRegistry {
    static let fallbackProviderID = "whisperkit"

    static var all: [any TranscriptionProvider] = [WhisperKitProvider(), ParakeetProvider(), Qwen3Provider(), AppleProvider()]

    static func provider(id: String) -> (any TranscriptionProvider)? {
        all.first { type(of: $0).id == id }
    }

    static func availableProviders() -> [any TranscriptionProvider] {
        all.filter { $0.availability() == .available }
    }

    /// Never fails: an unknown or unavailable id degrades to WhisperKit.
    static func resolve(providerID: String) -> any TranscriptionProvider {
        if let p = provider(id: providerID), p.availability() == .available { return p }
        return provider(id: fallbackProviderID) ?? all[0]
    }
}
