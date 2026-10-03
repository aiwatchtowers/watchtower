import Foundation

/// One language the assistant can write in. `englishName` is what goes into
/// `digest.language` — Go's `prompts.Directive` takes any language name, so
/// the English name is the stored value whatever the UI shows.
package struct AssistantLanguage: Hashable, Identifiable, Sendable {
    /// The language code, plus the script for a written variant the
    /// catalog keeps apart ("zh-Hant", "sr-Latn").
    package let id: String
    /// Bare ISO language code ("ru", "pt", "fil"); a script variant shares
    /// its language's code.
    package let code: String
    package let englishName: String
    /// The language's name in itself ("Русский", "Polski").
    package let nativeName: String

    package init(id: String? = nil, code: String, englishName: String, nativeName: String) {
        self.id = id ?? code
        self.code = code
        self.englishName = englishName
        self.nativeName = nativeName
    }
}

/// The pure side of the assistant-language setting: the macOS default, the
/// picker's list and search, and the transcription langset seed.
package enum AssistantLanguageCatalog {
    /// Mirrors Go's `config.DefaultDigestLang`: what the pipelines use while
    /// `digest.language` is absent.
    package static let fallbackName = "English"

    package static let english = AssistantLanguage(code: "en", englishName: "English", nativeName: "English")

    /// Written variants that are told apart, by `<code>-<script>`: someone
    /// reading Traditional Chinese or Latin-script Serbian wants it written
    /// that way. Every other script folds into its language.
    private static let scriptVariants: [String: String] = [
        "zh-Hant": "Chinese (Traditional)",
        "sr-Latn": "Serbian (Latin)"
    ]

    /// The language behind a locale identifier or BCP 47 tag ("pt-BR",
    /// "zh_Hans_CN"; "zh-TW" implies Traditional), nil when Foundation has
    /// no English name for it.
    package static func language(identifier: String) -> AssistantLanguage? {
        let tag = Locale(identifier: identifier).language
        guard let code = tag.languageCode?.identifier else { return nil }
        if let script = Locale.Language(identifier: tag.maximalIdentifier).script?.identifier,
           let english = scriptVariants["\(code)-\(script)"] {
            let id = "\(code)-\(script)"
            let native = Locale(identifier: id).localizedString(forIdentifier: id) ?? english
            return AssistantLanguage(id: id, code: code, englishName: english, nativeName: capitalized(native, code: code))
        }
        guard let english = Locale(identifier: "en").localizedString(forLanguageCode: code),
              english.caseInsensitiveCompare(code) != .orderedSame else { return nil }
        let native = Locale(identifier: code).localizedString(forLanguageCode: code) ?? english
        return AssistantLanguage(code: code, englishName: english, nativeName: capitalized(native, code: code))
    }

    /// The Mac's preferred languages (`Locale.preferredLanguages` order),
    /// regional variants of one language collapsed into it ("en-GB", "en-US"
    /// → English once).
    package static func preferred(_ tags: [String] = Locale.preferredLanguages) -> [AssistantLanguage] {
        var seen = Set<String>()
        return tags.compactMap(language(identifier:)).filter { seen.insert($0.id).inserted }
    }

    /// The assistant language a fresh install starts with: the first macOS
    /// preferred language, English when there is none Foundation can name.
    package static func systemDefault(_ tags: [String] = Locale.preferredLanguages) -> AssistantLanguage {
        preferred(tags).first ?? english
    }

    /// Every language some installed locale speaks, by English name.
    package static func all(_ identifiers: [String] = Locale.availableIdentifiers) -> [AssistantLanguage] {
        var byID: [String: AssistantLanguage] = [:]
        for identifier in identifiers {
            if let lang = language(identifier: identifier), byID[lang.id] == nil {
                byID[lang.id] = lang
            }
        }
        return byID.values.sorted { $0.englishName.localizedCompare($1.englishName) == .orderedAscending }
    }

    /// `languages` whose native or English name contains `query`, ignoring
    /// case and diacritics; names starting with it come first, each group
    /// keeping `languages`' order. A blank query matches nothing — the picker
    /// shows its macOS chips instead of a 300-row list.
    package static func search(_ query: String, in languages: [AssistantLanguage]) -> [AssistantLanguage] {
        let needle = fold(query.trimmingCharacters(in: .whitespaces))
        guard !needle.isEmpty else { return [] }
        var prefixed: [AssistantLanguage] = []
        var contained: [AssistantLanguage] = []
        for lang in languages {
            let names = [fold(lang.nativeName), fold(lang.englishName)]
            if names.contains(where: { $0.hasPrefix(needle) }) {
                prefixed.append(lang)
            } else if names.contains(where: { $0.contains(needle) }) {
                contained.append(lang)
            }
        }
        return prefixed + contained
    }

    /// The catalog entry a stored `digest.language` value names, nil for a
    /// free-text value (written by hand or by the old Settings field) that
    /// matches no English name.
    package static func language(named name: String, in languages: [AssistantLanguage]) -> AssistantLanguage? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return languages.first { $0.englishName.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// "русский" → "Русский": only the first letter, so "norsk bokmål" keeps
    /// its second word as the language writes it.
    private static func capitalized(_ name: String, code: String) -> String {
        guard let first = name.first else { return name }
        return String(first).uppercased(with: Locale(identifier: code)) + name.dropFirst()
    }
}

/// Seeds `transcription.langset` (the meeting transcriber's per-window
/// language set) from the Mac's languages on a fresh install.
///
/// "The user has not touched it" is the key being absent from UserDefaults:
/// the Meetings settings field is an `@AppStorage`, which writes the key only
/// when edited, so absence means nobody set it. Seeding writes the key, so it
/// runs at most once and never overwrites a value — the user's or its own.
package enum TranscriptionLangsetSeed {
    package static let defaultsKey = "transcription.langset"

    /// Foundation's code → Whisper's, where they differ (Whisper's language
    /// tokens predate the ISO renames).
    private static let whisperAliases = ["nb": "no", "fil": "tl", "jv": "jw", "iw": "he"]

    /// The Mac's language codes in preference order, as the transcriber
    /// names them, kept only where it can detect them (`supported`),
    /// English appended when missing (meetings mix in English often enough
    /// to always detect it).
    package static func seed(_ tags: [String] = Locale.preferredLanguages, supported: Set<String>) -> String {
        var codes: [String] = []
        for lang in AssistantLanguageCatalog.preferred(tags) {
            let code = whisperAliases[lang.code] ?? lang.code
            if supported.contains(code), !codes.contains(code) { codes.append(code) }
        }
        if !codes.contains("en") { codes.append("en") }
        return codes.joined(separator: ",")
    }

    /// Writes `seed(tags, supported:)` when the key is absent. Returns
    /// whether it wrote.
    @discardableResult
    package static func seedIfUntouched(
        _ defaults: UserDefaults,
        supported: Set<String>,
        tags: [String] = Locale.preferredLanguages
    ) -> Bool {
        guard defaults.object(forKey: defaultsKey) == nil else { return false }
        defaults.set(seed(tags, supported: supported), forKey: defaultsKey)
        return true
    }
}
