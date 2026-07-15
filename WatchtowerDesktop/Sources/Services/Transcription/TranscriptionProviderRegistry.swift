import Foundation

/// The single list of transcription engines. Add a provider = add one line here.
enum TranscriptionProviderRegistry {
    static let fallbackProviderID = "whisperkit"

    // Seeded with a stub until Task 3 substitutes WhisperKitProvider().
    static var all: [any TranscriptionProvider] = [_StubProvider()]

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

private struct _StubProvider: TranscriptionProvider {
    static var id: String { "whisperkit" }
    var displayName: String { "WhisperKit" }
    var models: [TranscriptionModelOption] { [.init(id: "large-v3-v20240930", label: "Large v3 Turbo")] }
    var supportsLive: Bool { true }
    func availability() -> ProviderAvailability { .available }
    func supportedLanguages(model: String) -> Set<String>? { nil }
    func prefetch(model: String, progress: @escaping @Sendable (Double) -> Void) async throws {}
    func makeTranscriber(model: String, progress: @escaping @Sendable (Double) -> Void) async throws -> Transcriber {
        fatalError("stub replaced in Task 3")
    }
}
