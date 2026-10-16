import Foundation
import Observation
import WatchtowerCore

/// What the ⌘/ panel lists for a query: guide sections, then app screens.
struct AskMatches {
    let guide: [GuideSection]
    let screens: [HelpScreen]
}

/// The ⌘/ "Ask Watchtower" panel's state on `AppState` (spec 2026-10-16):
/// the guide index read once per launch through `watchtower guide index
/// --json`, the instant matches, and the one help conversation the panel
/// holds while it is open. Nothing here is stored: closing the panel ends
/// the conversation.
@MainActor
@Observable
final class AskCenter {
    /// The guide's web base, used only before the index has loaded.
    static let fallbackGuideBaseURL = "https://github.com/aiwatchtowers/watchtower/blob/main/docs/guide/"
    static let guideLimit = 5
    static let screenLimit = 4
    /// Sections put into each help turn's prompt.
    static let turnSectionLimit = 4

    private(set) var index: GuideIndex? {
        didSet { searchable = index.map { GuideSearch.Searchable($0.sections) } }
    }
    /// The index's sections split into words once, for ranking per keystroke.
    @ObservationIgnored private(set) var searchable: GuideSearch.Searchable?

    /// The User Guide's front page (Help menu).
    var guideHomeURL: URL? {
        URL(string: (index?.baseURL ?? Self.fallbackGuideBaseURL) + "README.md")
    }
    /// Why the guide could not load; the screens still match. Retried on the next open.
    private(set) var indexError: String?
    /// The guide section each help answer was built from, by assistant message id.
    private(set) var sources: [Int64: GuideSection] = [:]
    /// The open conversation's id; a new one per panel open.
    private(set) var conversationID = UUID()

    /// The light-tier model of a provider when the config names none (the
    /// model catalog's resolved value); nil leaves the CLI's default.
    @ObservationIgnored var resolvedLightModel: @MainActor (String) -> String? = { _ in nil }
    /// Loads the model catalog `resolvedLightModel` reads, when it has not
    /// loaded yet; awaited before the first turn so it runs on the light tier.
    @ObservationIgnored var loadModels: @MainActor () async -> Void = {}
    /// The last owner text of the open conversation, added to the next
    /// turn's retrieval so a bare follow-up still finds the topic.
    @ObservationIgnored var previousQuestion: String?
    /// The top section of the turn in flight, recorded for its reply.
    @ObservationIgnored var pendingSource: GuideSection?
    /// The open conversation's rows, replayed to a provider that resumes no
    /// session; the panel points it at its engine.
    @ObservationIgnored var history: @MainActor () -> [ChatMessageRecord] = { [] }

    @ObservationIgnored private let runner: any CLIRunnerProtocol
    @ObservationIgnored private var loading: Task<Void, Never>?

    init(runner: any CLIRunnerProtocol) {
        self.runner = runner
    }

    /// Reads the guide index unless it is already loaded; concurrent calls share one run.
    func loadIfNeeded() async {
        guard index == nil else { return }
        if let loading {
            await loading.value
            return
        }
        let task = Task { await load() }
        loading = task
        await task.value
        loading = nil
    }

    private func load() async {
        do {
            let data = try await runner.run(args: ["guide", "index", "--json"])
            index = try JSONDecoder().decode(GuideIndex.self, from: data)
            indexError = nil
        } catch {
            NSLog("AskCenter: loading the guide index: %@", error.localizedDescription)
            indexError = "The guide couldn't load: \(error.localizedDescription)"
        }
    }

    /// Guide sections by `GuideSearch.rank`, and screens whose title starts
    /// with the query before those that only contain it (case-insensitive).
    func matches(for query: String, screens: [HelpScreen]) -> AskMatches {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return AskMatches(guide: [], screens: []) }
        let guide = searchable.map { GuideSearch.rank(trimmed, in: $0, limit: Self.guideLimit) } ?? []
        let needle = trimmed.lowercased()
        let prefixed = screens.filter { $0.title.lowercased().hasPrefix(needle) }
        let containing = screens.filter {
            let title = $0.title.lowercased()
            return !title.hasPrefix(needle) && title.contains(needle)
        }
        return AskMatches(guide: guide, screens: Array((prefixed + containing).prefix(Self.screenLimit)))
    }

    /// Loads the guide index and the model catalog before a first question;
    /// false when the panel closed or moved to a new conversation meanwhile,
    /// so nothing is sent (no engine, no paid call nobody sees).
    func prepareToAsk(isShown: @MainActor () -> Bool) async -> Bool {
        let asked = conversationID
        await loadIfNeeded()
        await loadModels()
        return isShown() && conversationID == asked
    }

    /// A panel opened: a fresh conversation with nothing carried over.
    func startConversation() {
        conversationID = UUID()
        previousQuestion = nil
        pendingSource = nil
        history = { [] }
        sources = [:]
    }

    func recordSource(messageID: Int64) {
        sources[messageID] = pendingSource
        pendingSource = nil
    }
}
