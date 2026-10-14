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

    static func review(_ ask: OwnerAsk, draft: AskDraft, render: (String) -> PlainTextDocument) -> Review {
        let count = draft.comments.count
        let noun = count == 1 ? "1 comment" : "\(count) comments"
        return Review(
            docPath: ask.docPath,
            document: ask.docSnapshot.map(render),
            clippedNotice: ask.docClipped == true ? AskText.clipped(docBytes: ask.docBytes) : nil,
            comments: draft.comments.map { Comment(id: $0.id, quote: $0.anchor.quote, body: $0.body) },
            verdict: draft.verdict,
            commentsLine: ask.docSnapshot == nil ? noun : "Select text to comment · \(noun)"
        )
    }

    static let checkMarks: [(state: OwnerAskAnswer.CheckState, symbol: String, tone: PhoneTone)] = [
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
