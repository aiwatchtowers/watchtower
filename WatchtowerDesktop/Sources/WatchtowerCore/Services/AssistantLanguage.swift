import Foundation

/// One language the assistant can write in. `englishName` is what goes into
/// `digest.language` — Go's `prompts.Directive` takes any language name, so
/// the English name is the stored value whatever the UI shows.
package struct AssistantLanguage: Hashable, Identifiable, Sendable {
    /// Bare ISO language code ("ru", "pt", "fil"), the same shape
    /// `transcription.langset` holds.
    package let code: String
    package let englishName: String
    /// The language's name in itself ("Русский", "Polski").
    package let nativeName: String

    package var id: String { code }
}

/// The pure side of the assistant-language setting: the macOS default, the
/// picker's list and search, and the transcription langset seed.
package enum AssistantLanguageCatalog {
    /// Mirrors Go's `config.DefaultDigestLang`: what the pipelines use while
    /// `digest.language` is absent.
    package static let fallbackName = "English"

    package static let english = AssistantLanguage(code: "en", englishName: "English", nativeName: "English")

    /// The language behind a locale identifier or BCP 47 tag ("pt-BR",
    /// "zh_Hans_CN"), nil when Foundation has no English name for it.
    package static func language(identifier: String) -> AssistantLanguage? {
        guard let code = Locale(identifier: identifier).language.languageCode?.identifier,
              let english = Locale(identifier: "en").localizedString(forLanguageCode: code),
              english.caseInsensitiveCompare(code) != .orderedSame else { return nil }
        let native = Locale(identifier: code).localizedString(forLanguageCode: code) ?? english
        return AssistantLanguage(code: code, englishName: english, nativeName: capitalized(native, code: code))
    }

    /// The Mac's preferred languages (`Locale.preferredLanguages` order),
    /// regional variants of one language collapsed into it ("en-GB", "en-US"
    /// → English once).
    package static func preferred(_ tags: [String] = Locale.preferredLanguages) -> [AssistantLanguage] {
        var seen = Set<String>()
        return tags.compactMap(language(identifier:)).filter { seen.insert($0.code).inserted }
    }

    /// The assistant language a fresh install starts with: the first macOS
    /// preferred language, English when there is none Foundation can name.
    package static func systemDefault(_ tags: [String] = Locale.preferredLanguages) -> AssistantLanguage {
        preferred(tags).first ?? english
    }

    /// Every language some installed locale speaks, by English name.
    package static func all(_ identifiers: [String] = Locale.availableIdentifiers) -> [AssistantLanguage] {
        var byCode: [String: AssistantLanguage] = [:]
        for identifier in identifiers {
            if let lang = language(identifier: identifier), byCode[lang.code] == nil {
                byCode[lang.code] = lang
            }
        }
        return byCode.values.sorted { $0.englishName.localizedCompare($1.englishName) == .orderedAscending }
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

    /// The Mac's language codes in preference order, English appended when
    /// missing (meetings mix in English often enough to always detect it).
    package static func seed(_ tags: [String] = Locale.preferredLanguages) -> String {
        var codes = AssistantLanguageCatalog.preferred(tags).map(\.code)
        if !codes.contains("en") { codes.append("en") }
        return codes.joined(separator: ",")
    }

    /// Writes `seed(tags)` when the key is absent. Returns whether it wrote.
    @discardableResult
    package static func seedIfUntouched(_ defaults: UserDefaults, tags: [String] = Locale.preferredLanguages) -> Bool {
        guard defaults.object(forKey: defaultsKey) == nil else { return false }
        defaults.set(seed(tags), forKey: defaultsKey)
        return true
    }
}
