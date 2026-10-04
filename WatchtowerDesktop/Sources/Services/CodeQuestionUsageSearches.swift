import Foundation
import WatchtowerCore

/// "Where is it used?"'s searches (ruling R45), per workbench: `code search
/// --word --case` for one name, up to `CodeQuestionUsages.limit` locations.
/// One search per workbench; a newer one, or a cancel, drops an older one's
/// callbacks, and a cancelled search is killed with its process group.
@MainActor
final class CodeQuestionUsageSearches {
    private let startSearch: CodeSearchStarter
    private var searches: [Int64: CodeSearchCancelling] = [:]
    private var generations: [Int64: Int] = [:]
    private var nextGeneration = 0

    init(startSearch: @escaping CodeSearchStarter) {
        self.startSearch = startSearch
    }

    /// Starts the search, cancelling the workbench's running one; `onDone`
    /// runs once with what was found, or nil when the search failed — never
    /// after a cancel or a newer search.
    func start(name: String, folder: URL, workbenchID: Int64, onDone: @escaping (CodeQuestionUsages?) -> Void) {
        cancel(workbenchID)
        nextGeneration += 1
        let generation = nextGeneration
        generations[workbenchID] = generation
        var found: [CodeQuestionUsages.Location] = []
        let options = CodeSearchOptions(query: name, word: true, caseSensitive: true,
                                        max: CodeQuestionUsages.limit, context: 0)
        let search = startSearch(folder, options, { [weak self] match in
            guard self?.generations[workbenchID] == generation, found.count < CodeQuestionUsages.limit else { return }
            found.append(CodeQuestionUsages.Location(path: match.path, line: match.line, text: match.text))
        }, { [weak self] outcome in
            guard let self, generations[workbenchID] == generation else { return }
            generations[workbenchID] = nil
            searches[workbenchID] = nil
            switch outcome {
            case let .finished(done):
                onDone(CodeQuestionUsages(name: name, locations: found,
                                          truncated: done.truncated || found.count >= CodeQuestionUsages.limit))
            case let .failed(message):
                NSLog("CodeQuestionCenter: the usage search for a code question failed: %@", message)
                onDone(nil)
            }
        })
        // A search that already finished (a stub's, at once) keeps no handle.
        if generations[workbenchID] == generation { searches[workbenchID] = search }
    }

    func isRunning(_ workbenchID: Int64) -> Bool {
        searches[workbenchID] != nil
    }

    func cancel(_ workbenchID: Int64) {
        generations[workbenchID] = nil
        searches.removeValue(forKey: workbenchID)?.cancel()
    }

    /// App quit (ruling R34): every search is killed.
    func cancelAll() {
        for workbenchID in Array(searches.keys) { cancel(workbenchID) }
    }
}
