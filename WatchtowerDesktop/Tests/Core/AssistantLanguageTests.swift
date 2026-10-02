import XCTest
@testable import WatchtowerCore

/// The assistant language defaults to the Mac's first preferred language,
/// stored as its English name (`digest.language`); the picker searches every
/// installed language by native or English name.
final class AssistantLanguageTests: XCTestCase {
    // MARK: - preferredLanguages → name

    func testSystemDefaultIsFirstPreferredLanguageByEnglishName() {
        XCTAssertEqual(AssistantLanguageCatalog.systemDefault(["ru-UA", "en-US"]).englishName, "Russian")
        XCTAssertEqual(AssistantLanguageCatalog.systemDefault(["pl-PL"]).englishName, "Polish")
        XCTAssertEqual(AssistantLanguageCatalog.systemDefault(["pt-BR"]).englishName, "Portuguese")
        XCTAssertEqual(AssistantLanguageCatalog.systemDefault(["zh-Hans-CN"]).englishName, "Chinese")
    }

    func testTraditionalChineseIsItsOwnLanguage() {
        for tag in ["zh-Hant-TW", "zh-TW", "zh-HK", "zh-MO"] {
            XCTAssertEqual(AssistantLanguageCatalog.systemDefault([tag]).englishName, "Chinese (Traditional)", tag)
        }
        for tag in ["zh-Hans-CN", "zh-CN", "zh"] {
            XCTAssertEqual(AssistantLanguageCatalog.systemDefault([tag]).englishName, "Chinese", tag)
        }
        let traditional = AssistantLanguageCatalog.systemDefault(["zh-Hant-TW"])
        XCTAssertEqual(traditional.id, "zh-Hant")
        XCTAssertEqual(traditional.code, "zh")
        XCTAssertEqual(AssistantLanguageCatalog.preferred(["zh-Hant-TW", "zh-CN"]).map(\.id), ["zh-Hant", "zh"])
    }

    func testLatinSerbianIsItsOwnLanguage() {
        XCTAssertEqual(AssistantLanguageCatalog.systemDefault(["sr-Latn-RS"]).englishName, "Serbian (Latin)")
        XCTAssertEqual(AssistantLanguageCatalog.systemDefault(["sr-RS"]).englishName, "Serbian")
    }

    func testOtherScriptsFoldIntoTheirLanguage() {
        XCTAssertEqual(AssistantLanguageCatalog.systemDefault(["uz-Cyrl"]).englishName, "Uzbek")
    }

    func testSystemDefaultFallsBackToEnglish() {
        XCTAssertEqual(AssistantLanguageCatalog.systemDefault([]), AssistantLanguageCatalog.english)
        // A tag Foundation cannot name is skipped, not stored as a code.
        XCTAssertEqual(AssistantLanguageCatalog.systemDefault(["qqq"]).englishName, "English")
        XCTAssertEqual(AssistantLanguageCatalog.systemDefault(["qqq", "uk-UA"]).englishName, "Ukrainian")
    }

    func testPreferredCollapsesRegionalVariantsInOrder() {
        let langs = AssistantLanguageCatalog.preferred(["en-GB", "en-UA", "ru-UA", "en-US"])
        XCTAssertEqual(langs.map(\.code), ["en", "ru"])
    }

    func testNativeNameIsCapitalizedInItsOwnScript() {
        let russian = AssistantLanguageCatalog.language(identifier: "ru")
        XCTAssertEqual(russian?.nativeName, "Русский")
        XCTAssertEqual(AssistantLanguageCatalog.language(identifier: "uk")?.nativeName, "Українська")
    }

    // MARK: - search

    private let catalog = AssistantLanguageCatalog.all()

    func testCatalogHasOneEntryPerLanguage() {
        let codes = catalog.filter { $0.id == $0.code }.map(\.code)
        XCTAssertEqual(codes.count, Set(codes).count)
        XCTAssertTrue(codes.contains("pl"))
        let ids = catalog.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
        XCTAssertTrue(ids.contains("zh-Hant"))
        XCTAssertTrue(ids.contains("sr-Latn"))
        XCTAssertGreaterThan(catalog.count, 50)
    }

    func testSearchMatchesEnglishName() {
        XCTAssertEqual(AssistantLanguageCatalog.search("Polish", in: catalog).first?.code, "pl")
    }

    func testSearchMatchesNativeNameIgnoringCaseAndDiacritics() {
        XCTAssertEqual(AssistantLanguageCatalog.search("русск", in: catalog).first?.code, "ru")
        XCTAssertTrue(AssistantLanguageCatalog.search("portugues", in: catalog).map(\.code).contains("pt"))
        XCTAssertTrue(AssistantLanguageCatalog.search("POLSKI", in: catalog).map(\.code).contains("pl"))
    }

    func testSearchRanksPrefixMatchesFirst() {
        let langs = [
            AssistantLanguage(code: "xa", englishName: "Lapol", nativeName: "Lapol"),
            AssistantLanguage(code: "pl", englishName: "Polish", nativeName: "Polski")
        ]
        XCTAssertEqual(AssistantLanguageCatalog.search("pol", in: langs).map(\.code), ["pl", "xa"])
    }

    func testBlankSearchMatchesNothing() {
        XCTAssertEqual(AssistantLanguageCatalog.search("", in: catalog), [])
        XCTAssertEqual(AssistantLanguageCatalog.search("   ", in: catalog), [])
        XCTAssertEqual(AssistantLanguageCatalog.search("zzzzqx", in: catalog), [])
    }

    func testStoredNameResolvesCaseInsensitivelyAndFreeTextDoesNot() {
        XCTAssertEqual(AssistantLanguageCatalog.language(named: "russian", in: catalog)?.code, "ru")
        XCTAssertEqual(AssistantLanguageCatalog.language(named: " English ", in: catalog)?.code, "en")
        XCTAssertNil(AssistantLanguageCatalog.language(named: "Klingon-ish", in: catalog))
        XCTAssertNil(AssistantLanguageCatalog.language(named: "", in: catalog))
    }
}

/// `transcription.langset` is seeded from the Mac's languages once, only
/// while the key is absent.
final class TranscriptionLangsetSeedTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "TranscriptionLangsetSeedTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// A Whisper-shaped code set for the seed's filter.
    private let supported: Set<String> = ["en", "ru", "uk", "de", "pl", "no", "tl", "jw", "he", "zh", "sr"]

    private func seed(_ tags: [String]) -> String {
        TranscriptionLangsetSeed.seed(tags, supported: supported)
    }

    func testSeedIsMacLanguagesPlusEnglish() {
        XCTAssertEqual(seed(["ru-UA", "uk-UA"]), "ru,uk,en")
        XCTAssertEqual(seed(["en-GB", "de-DE"]), "en,de")
        XCTAssertEqual(seed(["pl-PL", "en-US", "pl"]), "pl,en")
        XCTAssertEqual(seed([]), "en")
    }

    func testSeedUsesTheTranscribersCodes() {
        XCTAssertEqual(seed(["nb-NO"]), "no,en")
        XCTAssertEqual(seed(["fil-PH"]), "tl,en")
        XCTAssertEqual(seed(["jv"]), "jw,en")
        XCTAssertEqual(seed(["he-IL"]), "he,en")
        XCTAssertEqual(seed(["iw"]), "he,en")
    }

    /// Script variants share one detector code.
    func testSeedFoldsScriptVariants() {
        XCTAssertEqual(seed(["zh-Hant-TW", "zh-CN"]), "zh,en")
        XCTAssertEqual(seed(["sr-Latn-RS", "sr-RS"]), "sr,en")
    }

    func testSeedDropsLanguagesTheTranscriberCannotDetect() {
        XCTAssertEqual(seed(["chr-US", "de-DE"]), "de,en")
        XCTAssertEqual(seed(["chr-US"]), "en")
    }

    func testAbsentKeyIsSeeded() {
        XCTAssertTrue(TranscriptionLangsetSeed.seedIfUntouched(defaults, supported: supported, tags: ["de-DE"]))
        XCTAssertEqual(defaults.string(forKey: TranscriptionLangsetSeed.defaultsKey), "de,en")
    }

    func testUserValueIsNeverOverwritten() {
        defaults.set("ru,en", forKey: TranscriptionLangsetSeed.defaultsKey)
        XCTAssertFalse(TranscriptionLangsetSeed.seedIfUntouched(defaults, supported: supported, tags: ["de-DE"]))
        XCTAssertEqual(defaults.string(forKey: TranscriptionLangsetSeed.defaultsKey), "ru,en")
    }

    /// An emptied field is still the user's value — seeding must not
    /// resurrect it (`TranscriptionConfig.fromDefaults` falls back to its
    /// own default for a blank one).
    func testUserBlankValueIsNeverOverwritten() {
        defaults.set("", forKey: TranscriptionLangsetSeed.defaultsKey)
        XCTAssertFalse(TranscriptionLangsetSeed.seedIfUntouched(defaults, supported: supported, tags: ["de-DE"]))
        XCTAssertEqual(defaults.string(forKey: TranscriptionLangsetSeed.defaultsKey), "")
    }

    func testSeedRunsOnce() {
        TranscriptionLangsetSeed.seedIfUntouched(defaults, supported: supported, tags: ["de-DE"])
        XCTAssertFalse(TranscriptionLangsetSeed.seedIfUntouched(defaults, supported: supported, tags: ["fr-FR"]))
        XCTAssertEqual(defaults.string(forKey: TranscriptionLangsetSeed.defaultsKey), "de,en")
    }
}
