import Foundation
import WatchtowerKit
import WatchtowerSync

extension AskFormModel {
    // MARK: - Parts

    static func subline(_ ask: OwnerAsk, snapshot: WorkbenchReplicaSnapshot) -> String {
        var parts = [ask.workbenchName]
        if let session = ask.sessionID.flatMap(snapshot.session) {
            parts.append(session.title)
        }
        if let target = ask.targetID {
            parts.append("#\(target)")
        }
        return "From " + parts.joined(separator: " · ")
    }

    static func page(_ question: OwnerAskPayload.Question, index: Int, count: Int, draft: AskDraft) -> QuestionPage {
        let pick = draft.picks[question.id] ?? AskQuestionPick()
        return QuestionPage(
            questionID: question.id,
            index: index,
            count: count,
            question: question.question,
            multi: question.multi,
            options: question.options.map { option in
                .init(
                    label: option.label,
                    description: option.description,
                    recommended: option.recommended,
                    isPicked: pick.labels.contains(option.label)
                )
            },
            other: pick.other
        )
    }

    static func review(
        _ ask: OwnerAsk, draft: AskDraft, render: (String) -> PlainTextDocument, split: (PlainTextDocument) -> [ReviewParagraph]
    ) -> Review {
        let document = ask.docSnapshot.map(render)
        let paragraphs = document.map(split) ?? []
        let clipped = ask.docClipped == true && document != nil
        var byParagraph: [Int: [Comment]] = [:]
        var unplaced: [Comment] = []
        let comments = draft.comments.map { Comment(id: $0.id, quote: $0.anchor.quote, body: $0.body) }
        for (draftComment, comment) in zip(draft.comments, comments) {
            if let id = paragraphID(of: draftComment, in: document, paragraphs: paragraphs) {
                byParagraph[id, default: []].append(comment)
            } else {
                unplaced.append(comment)
            }
        }
        return Review(
            docPath: ask.docPath,
            document: document,
            paragraphs: paragraphs,
            clippedNotice: clipped ? AskText.clipped(docBytes: ask.docBytes) : nil,
            clippedEnd: clipped ? AskText.clippedEnd(docPath: ask.docPath) : nil,
            comments: comments,
            commentsByParagraph: byParagraph,
            unplacedComments: unplaced,
            verdict: draft.verdict,
            commentsLine: AskText.commentsLine(count: comments.count, hasDocument: document != nil)
        )
    }

    /// The paragraph a comment was made on: the line holding its start,
    /// when the quote is still there (a newer snapshot moves text).
    private static func paragraphID(of comment: AskCommentDraft, in document: PlainTextDocument?, paragraphs: [ReviewParagraph]) -> Int? {
        guard let document, let location = comment.location,
              let index = ReviewParagraph.index(of: location, in: paragraphs) else { return nil }
        let quote = comment.anchor.quote as NSString
        let text = document.text as NSString
        guard location + quote.length <= text.length,
              text.substring(with: NSRange(location: location, length: quote.length)) == comment.anchor.quote else { return nil }
        return paragraphs[index].id
    }

    private static let checkMarks: [(state: OwnerAskAnswer.CheckState, symbol: String, tone: PhoneTone)] = [
        (.ok, "checkmark.circle", .green), (.broken, "xmark.circle", .red), (.skipped, "minus.circle", .secondary)
    ]

    static func checkRow(_ item: OwnerAskPayload.CheckItem, draft: AskDraft) -> CheckRow {
        let state = draft.checks[item.id]
        let note = draft.checkNotes[item.id] ?? ""
        let choices = checkMarks.map { mark in
            let selected = state == mark.state
            return CheckChoice(
                state: mark.state, label: AskText.check(mark.state),
                symbol: selected ? mark.symbol + ".fill" : mark.symbol,
                tone: selected ? mark.tone : .secondary, isSelected: selected
            )
        }
        return CheckRow(
            id: item.id, text: item.text, hint: item.hint, state: state, note: note,
            needsNote: state == .broken && AskDraft.trimmed(note).isEmpty, choices: choices
        )
    }

    static func closedLines(_ ask: OwnerAsk) -> [ClosedLine] {
        guard let answer = ask.answer else { return [] }
        var lines: [ClosedLine] = []
        if answer.dismissed {
            lines.append(ClosedLine(label: "Dismissed", value: "Closed on the Mac without an answer"))
        }
        if let verdict = answer.verdict {
            lines.append(ClosedLine(label: "Verdict", value: verdict == .approved ? "Approved" : "Changes requested"))
        }
        let questions = Dictionary((ask.payload?.questions ?? []).map { ($0.id, $0.question) }) { first, _ in first }
        for item in answer.answers {
            let picked = (item.labels + (item.other.isEmpty ? [] : ["Other: \(item.other)"])).joined(separator: ", ")
            lines.append(ClosedLine(label: questions[item.id] ?? item.id, value: picked.isEmpty ? "No answer" : picked))
        }
        let checks = Dictionary((ask.payload?.checklist ?? []).map { ($0.id, $0.text) }) { first, _ in first }
        for item in answer.checklist {
            let note = item.note.isEmpty ? "" : " — \(item.note)"
            lines.append(ClosedLine(label: checks[item.id] ?? item.id, value: "\(AskText.check(item.state))\(note)"))
        }
        lines += answer.comments.map { ClosedLine(label: "“\($0.quote)”", value: $0.body) }
        if !answer.note.isEmpty {
            lines.append(ClosedLine(label: "Note", value: answer.note))
        }
        return lines
    }
}
