import Foundation

/// The independent reviewer beside Branch review (board #1025, business
/// item 8, tech spec §6), on the shared embedded chat component.
///
/// - Draft-only (review-rules "The assistant & chat contracts", AGENT-04):
///   no tool mode; the provider's own read-only file tools read the folder
///   the round was taken from (`ai query --read-folder`, widened to a
///   workbench's registered session worktrees — ask #560).
/// - One thread per branch (`review_reviewer_threads`, migration 00175):
///   `chat_conversations` of context type `review_reviewer`, context id
///   `<workbench>:<branch>`; two sessions on one branch share it.
/// - No live session: each turn is a fresh call with the system prompt, the
///   engine's replay block and this turn's compact branch map
///   (`ReviewerMapBrief`).
/// - Nothing reaches the author's session but **Send to author**, the
///   owner's own design comment in the open round.
package enum ReviewerSurface {
    package static let contextType = "review_reviewer"

    package static func contextID(projectID: Int64, branch: String) -> String {
        "\(projectID):\(branch)"
    }

    /// How the configured provider reads the folder: Claude through its
    /// read-only file tools, Codex through its shell under the read-only
    /// sandbox, Ollama not at all (its turn then runs without the folder).
    package enum Reader: Equatable, Sendable {
        case claudeTools, codexSandbox, none
    }

    /// Where the reviewer works: the thread's workbench and branch key, the
    /// branch as the owner reads it and the folder the round was taken from.
    package struct Context: Equatable, Sendable {
        package let projectID: Int64
        /// The thread key (`threadBranch`).
        package let branch: String
        /// The branch's name for the panel's line; "" for a detached HEAD.
        package let branchLabel: String
        package let readFolder: String
        /// The folder is the session's own worktree, not the workbench folder.
        package let inWorktree: Bool
        /// A branch-tip round's tree (#1012): the branch is read from refs and
        /// the folder is checked out on another branch, so its files are not
        /// the branch's; nil for a round of the folder.
        package let tipTree: String?
        package var branchTip: Bool { tipTree != nil }

        package init(
            projectID: Int64,
            branch: String,
            branchLabel: String,
            readFolder: String,
            inWorktree: Bool,
            tipTree: String? = nil
        ) {
            self.projectID = projectID
            self.branch = branch
            self.branchLabel = branchLabel
            self.readFolder = readFolder
            self.inWorktree = inWorktree
            self.tipTree = tipTree
        }
    }

    /// The key prefix of a thread that has no branch (a detached HEAD).
    private static let sessionKeyPrefix = "session:"

    /// Where the reviewer of a session's round works; nil until the thread
    /// key is known (no round yet, or the folder's branch not read yet).
    package static func context(
        projectID: Int64,
        sessionID: Int64,
        round: ReviewRoundInfo?,
        place: SessionPlace,
        mainStatus: WorkbenchGitStatus?
    ) -> Context? {
        guard let round, !round.folderRoot.isEmpty else { return nil }
        let status = ReviewIdentityPresentation.status(place: place, mainStatus: mainStatus)
        guard let branch = threadBranch(round: round, folderStatus: status, sessionID: sessionID) else { return nil }
        var inWorktree = false
        if case .worktree = place { inWorktree = true }
        return Context(projectID: projectID, branch: branch,
                       branchLabel: branch.hasPrefix(sessionKeyPrefix) ? "" : branch,
                       readFolder: round.folderRoot, inWorktree: inWorktree,
                       tipTree: round.isBranchTip ? round.treeSha : nil)
    }

    /// The thread key: the round's branch (#1012) when it has one, else the
    /// folder's checked-out branch; a detached HEAD (or a folder with no
    /// branch) keys by the session. nil while the folder's status is unknown.
    package static func threadBranch(round: ReviewRoundInfo?, folderStatus: WorkbenchGitStatus?, sessionID: Int64) -> String? {
        if let branch = round?.branch, !branch.isEmpty { return branch }
        guard let status = folderStatus else { return nil }
        if status.detached || status.branch.isEmpty { return "\(sessionKeyPrefix)\(sessionID)" }
        return status.branch
    }

    /// The line under the panel's switch (mockup frame 5): what the reviewer
    /// can actually read with the configured provider.
    package static func mapLine(_ context: Context, reader: Reader) -> String {
        let branch = context.branchLabel.isEmpty ? "this branch" : context.branchLabel
        let place = context.inWorktree ? "the session's worktree" : "the workbench folder"
        let reads: String
        if reader == .none {
            reads = "answers from the branch map only — this AI provider cannot read files"
        } else if context.branchTip {
            reads = "reads \(place), which is not on \(branch)"
        } else {
            reads = "reads \(branch) in \(place)"
        }
        return "Read-only · \(reads) · sees the chapters, their danger and the summary"
            + " · never talks to the author's session"
    }

    package static let emptyHint =
        "Ask the reviewer about this branch: what breaks if…, what a change would take. It reads the code and never talks to the author's session."
    package static let noRoundHint = "The reviewer opens once the branch's round is ready."
    package static let placeholder = "Ask the reviewer about this branch…"

    /// `map` is read when each turn starts, so the turn sees the chapter
    /// open at that moment; `reader` too (a provider changed between turns).
    @MainActor
    package static func spec(
        context: Context,
        conversationID: Int64,
        reader: @escaping @MainActor () -> Reader,
        map: @escaping @MainActor () -> ReviewerMapInput
    ) -> ChatSurfaceSpec {
        let runOptions = { @MainActor () -> ChatRunOptions in
            ChatRunOptions(readFolder: reader() == .none ? nil : context.readFolder)
        }
        return ChatSurfaceSpec(
            key: EmbeddedChatKey(contextType: contextType,
                                 contextID: contextID(projectID: context.projectID, branch: context.branch),
                                 conversationID: conversationID),
            persistence: .database(conversationID: conversationID),
            toolAccess: .draftOnly,
            ownerInstructions: true,
            systemPrompt: { systemPrompt(context: context, reader: reader()) },
            turnPrompt: { turnPrompt(question: $0.text, map: map()) },
            emptyHint: emptyHint,
            runOptions: runOptions
        )
    }

    package static func turnPrompt(question: String, map: ReviewerMapInput) -> String {
        """
        \(ReviewerMapBrief.render(map))

        === THE OWNER'S QUESTION ===
        \(question)
        """
    }

    package static func readingInstructions(_ reader: Reader) -> String {
        switch reader {
        case .claudeTools:
            """
            You run inside the branch's folder with the read-only file tools Read, Grep, Glob and LS. Read the files \
            the answer needs; paths are relative to the folder. You cannot change, create or delete any file, run \
            commands or reach the web.
            """
        case .codexSandbox:
            """
            You run inside the branch's folder under a read-only sandbox. Read-only shell commands that inspect files \
            (cat, ls, rg, grep, sed -n, head, git log, git show, git diff) are fine; paths are relative to the folder. \
            Never modify, create or delete anything, and do not reach the web.
            """
        case .none:
            """
            You cannot read any file, run commands or reach the web: answer from the branch map only, and say so \
            when the answer needs code you have not been shown.
            """
        }
    }

    /// A branch-tip round's folder is on another branch: its files are not the branch's.
    package static func branchTipNote(context: Context, reader: Reader) -> String {
        guard let tree = context.tipTree, reader != .none else { return "" }
        // The round's tree, not the branch name: an origin-only branch has no
        // short ref, and a tag of the same name would win the lookup.
        let read = reader == .codexSandbox
            ? "Read the branch's own files with `git show \(tree):<path>` (the tree of its tip)."
            : "Say so when an answer rests on a file the branch changes."
        return "\n\nThe folder is checked out on another branch, not on \"\(context.branchLabel)\": its files are not the branch's. \(read)"
    }

    package static func systemPrompt(context: Context, reader: Reader) -> String {
        let branch = context.branchLabel.isEmpty ? "a detached HEAD" : "\"\(context.branchLabel)\""
        return """
        You are an independent code reviewer of the owner's branch \(branch). You are not its author: the agent \
        session that wrote the code never sees this conversation, and you never talk to it. The owner asks you \
        questions about the branch — what breaks if something changes, what adding something would take, where a \
        risk hides across chapters.

        === READING THE CODE ===
        \(readingInstructions(reader))\(branchTipNote(context: context, reader: reader))

        === THE BRANCH MAP ===
        Each owner message comes with a compact map of the branch: its chapters in reading order, the most \
        dangerous first, their files, the summary and the chapter open on the owner's screen. The map is a guide, \
        not the code: read the files before you answer, and say when an answer rests on code you did not read.

        === RESPONSE RULES ===
        - Answer in the language the owner writes in.
        - Cite code as `path:line` or `path:start-end`, the path relative to the folder.
        - Name the chapter a cited file belongs to when it helps the owner find it.
        - You only read: never claim to have changed a file, and never address the author — the owner decides \
        what reaches them.
        - Be concise.
        """
    }
}
