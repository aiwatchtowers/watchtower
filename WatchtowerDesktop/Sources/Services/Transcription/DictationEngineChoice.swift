import Foundation

/// The dictation-model picker's domain: which engine dictation runs on.
///
/// Deliberately decoupled from the meeting Engine/Model settings
/// (`transcription.provider`/`transcription.model`) — the meeting model is
/// picked for 30 s windows and full-quality recap, which is wrong for
/// dictation twice over (ten-second lumps, minute-plus cold load). Dictation
/// resolves only its own `dictation.model` key and never reads the meeting
/// keys, so changing one surface can never silently change the other.
enum DictationEngineChoice: Equatable {
    case apple
    case whisper(model: String)   // "large-v3-v20240930" | "small" | "base"

    /// Raw values stored under UserDefaults key "dictation.model".
    static let defaultsKey = "dictation.model"

    /// The only Whisper variants suitable for dictation's ~4 s windows.
    /// Full `large-v3` (load cost), `distil` (English-only), Parakeet
    /// (batch-only) and Qwen3 (heavy MLX) are excluded by design.
    static let whisperModels = ["large-v3-v20240930", "small", "base"]

    /// Picker labels keyed by model id. `pickerOptions` derives its Whisper
    /// rows from `whisperModels` through this map, so a model resolvable but
    /// not offered (or offered but not resolvable) is impossible by
    /// construction — `whisperModels` is the single source of truth.
    private static let whisperLabels: [String: String] = [
        "large-v3-v20240930": "Whisper large-v3 turbo",
        "small": "Whisper small (fast)",
        "base": "Whisper base (fastest)"
    ]

    /// Absent/unknown key → .apple when appleSupported, else .whisper("small").
    /// Unknown values fall back to the default rather than erroring so a
    /// stale key from a newer/older build degrades to a working engine.
    /// "apple" stored but appleSupported false (OS downgrade / synced prefs)
    /// → .whisper("small"), the fastest sensible Whisper.
    static func resolve(rawValue: String?, appleSupported: Bool) -> Self {
        switch rawValue {
        case "apple" where appleSupported:
            return .apple
        case let raw? where whisperModels.contains(raw):
            return .whisper(model: raw)
        default:
            return appleSupported ? .apple : .whisper(model: "small")
        }
    }

    /// Convenience used by DictationCenter: reads the injected defaults and
    /// AppleDictationSession.isSupported (parameterized for tests).
    static func current(defaults: UserDefaults, appleSupported: Bool) -> Self {
        resolve(rawValue: defaults.string(forKey: defaultsKey), appleSupported: appleSupported)
    }

    /// One row of the Settings "Dictation model" picker: the raw value
    /// stored under `defaultsKey` plus its display label.
    struct PickerOption: Equatable, Identifiable {
        let id: String
        let label: String
    }

    /// The Settings picker's option list, pure so tests can drive both
    /// support states. The Apple row exists only where
    /// `AppleDictationSession.isSupported` (macOS 26+); the Whisper trio is
    /// always offered, fastest-last.
    static func pickerOptions(appleSupported: Bool) -> [PickerOption] {
        var options: [PickerOption] = []
        if appleSupported {
            options.append(PickerOption(id: "apple", label: "Apple (realtime)"))
        }
        options.append(contentsOf: whisperModels.map {
            PickerOption(id: $0, label: whisperLabels[$0] ?? $0)
        })
        return options
    }

    /// The raw value the Settings picker stores for this choice — the
    /// read side of the picker's resolved-value proxy, so absent storage
    /// selects the resolved default rather than an empty row.
    var storedRawValue: String {
        switch self {
        case .apple:
            return "apple"
        case .whisper(let model):
            return model
        }
    }

    /// Stable engine-slot key ("apple" / "whisper|<model>") — replaces the
    /// meeting-keys engineKey() in DictationCenter's warm logic, so a
    /// Settings change invalidates the warm slot only when the *dictation*
    /// choice actually moved.
    var engineKey: String {
        switch self {
        case .apple:
            return "apple"
        case .whisper(let model):
            return "whisper|\(model)"
        }
    }
}
