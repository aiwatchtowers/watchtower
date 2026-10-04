import AppKit
import SwiftUI
import WatchtowerCore

/// The popover's root, hosted in an `NSPopover` by the Files pane's editor:
/// the code-answer environment, set once here and never re-applied while an
/// answer streams (an `OpenURLAction` cannot be compared — `MarkdownView`).
/// `path:line` links open in Files; other links pass the app-wide gate.
struct CodeQuestionPopoverHost: View {
    let questions: CodeQuestionCenter
    let workbenchID: Int64

    var body: some View {
        CodeQuestionPopover(questions: questions, workbenchID: workbenchID)
            .popoverSurface()
            .environment(\.dictationCenter, questions.dictation)
            .codeAnswerLinks { [questions, workbenchID] url in
                Task { await questions.openLink(url, workbenchID: workbenchID) }
            }
    }

    enum LinkRoute: Equatable {
        /// A `path:line` link: opened in Files by the popover itself.
        case files
        case systemHandler
        case discarded
    }

    /// Where a clicked link goes: `watchtower-code` stays in the app, any
    /// other scheme passes the app-wide allowlist.
    static func linkRoute(_ url: URL) -> LinkRoute {
        if url.scheme?.lowercased() == CodeLineLinks.scheme { return .files }
        return AllowedURLSchemes.permits(url) ? .systemHandler : .discarded
    }
}

extension View {
    /// A code answer's links (the popover, Open Quickly's card, the
    /// Questions tab): `path:line` links render and go to `openCodeLink`,
    /// any other link passes the app-wide gate. Applied once at the
    /// surface's root (an `OpenURLAction` cannot be compared — `MarkdownView`).
    func codeAnswerLinks(_ openCodeLink: @escaping (URL) -> Void) -> some View {
        environment(\.markdownCodeLinks, true)
            .environment(\.openURL, OpenURLAction { url in
                switch CodeQuestionPopoverHost.linkRoute(url) {
                case .files:
                    openCodeLink(url)
                    return .handled
                case .systemHandler:
                    return .systemAction
                case .discarded:
                    return .discarded
                }
            })
    }
}

/// The question popover at the selection (spec §9.2): quick actions, the
/// model picker, the answer (`EmbeddedChatView` `.compact`) with a
/// follow-up field, a suggested change's Apply, and Copy. Esc closes it;
/// the conversation stays for the Questions tab.
struct CodeQuestionPopover: View {
    let questions: CodeQuestionCenter
    let workbenchID: Int64

    var body: some View {
        if let session = questions.sessions[workbenchID] {
            let engine = questions.engine(workbenchID: workbenchID)
            VStack(alignment: .leading, spacing: 0) {
                header(session, busy: engine?.isBusy ?? false)
                quickActions(busy: engine?.isBusy == true || session.isSearchingUsages)
                Divider()
                if let engine, let chats = questions.embeddedChats {
                    EmbeddedChatView(engine: engine, density: .compact, placeholder: "Ask a follow-up…",
                                     onEscape: close)
                        .frame(height: 320)
                        .embeddedChatVisibility(engine.spec.key, in: chats)
                } else {
                    firstQuestionField(session)
                }
                if session.proposal != nil {
                    proposalBar
                }
                if let notice = session.notice {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(notice == CodeQuestionCenter.appliedNotice ? Color.secondary : Color.orange)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                actionRow(engine)
            }
            .frame(width: 460)
            .onExitCommand(perform: close)
        }
    }

    private func close() {
        questions.closeQuestion(workbenchID: workbenchID)
    }

    private func header(_ session: CodeQuestionCenter.Session, busy: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkle").foregroundStyle(.orange)
            Text(Self.anchorLabel(session.anchor))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            ChatModelPicker(
                provider: session.choice.provider,
                model: session.choice.model,
                suggestions: questions.modelSuggestions(session.choice.provider),
                onSelectProvider: { questions.setModelChoice(session.choice.switching(to: $0), workbenchID: workbenchID) },
                onSelectModel: { questions.setModelChoice(.init(provider: session.choice.provider, model: $0), workbenchID: workbenchID) }
            )
            .disabled(busy)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private func quickActions(busy: Bool) -> some View {
        HStack(spacing: 6) {
            ForEach(CodeQuestionQuickAction.allCases) { action in
                Button(action.title) { questions.quickAction(action, workbenchID: workbenchID) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .disabled(busy)
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private func firstQuestionField(_ session: CodeQuestionCenter.Session) -> some View {
        HStack(spacing: 6) {
            TextField("Ask about this code…", text: Binding(
                get: { questions.sessions[workbenchID]?.draft ?? "" },
                set: { questions.setDraft($0, workbenchID: workbenchID) }
            ))
            .textFieldStyle(.plain)
            // The draft as it is now, not as this body last saw it.
            .onSubmit { questions.ask(questions.sessions[workbenchID]?.draft ?? "", workbenchID: workbenchID) }
            Button {
                questions.ask(questions.sessions[workbenchID]?.draft ?? "", workbenchID: workbenchID)
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title3)
            }
            .buttonStyle(.borderless)
            .disabled(session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("Ask")
            .accessibilityLabel("Ask")
        }
        .padding(12)
    }

    private var proposalBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "plusminus").foregroundStyle(.secondary)
            Text("The suggested change is shown in the editor.").font(.caption)
            Spacer(minLength: 4)
            Button("Discard") { questions.discardProposal(workbenchID: workbenchID) }
            Button("Apply") {
                let questions = questions
                let workbenchID = workbenchID
                Task { await questions.applyProposal(workbenchID: workbenchID) }
            }
            .buttonStyle(.popoverPrimary)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.green.opacity(0.08))
    }

    private func actionRow(_ engine: EmbeddedChatEngine?) -> some View {
        let answer = engine?.messages.last { $0.message.isAssistant && $0.message.status == "complete" }?.message.text
        return HStack(spacing: 14) {
            Button("Copy", systemImage: "doc.on.doc") {
                guard let answer else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(answer, forType: .string)
            }
            .disabled(answer == nil)
            // Ruling R35's rule: no dead control ships.
            if CodeQuestionActionsFeature.pinToInspector {
                Button("Pin to inspector", systemImage: "pin") { questions.pinToInspector(workbenchID: workbenchID) }
                    .disabled(!canPin)
                    .help("Keep this conversation in the Questions tab")
            }
            if CodeQuestionActionsFeature.handToClaudeCode {
                // From the stored messages: not while an answer streams.
                Button("Hand to Claude Code", systemImage: "terminal") { questions.handToClaude(workbenchID: workbenchID) }
                    .keyboardShortcut(.return, modifiers: [.command, .option])
                    .disabled(engine == nil || engine?.isBusy == true)
                    .help("Continue this in a Claude Code session of the workbench (⌥⌘↩)")
            }
            Spacer()
            Text("esc to close").font(.caption2).foregroundStyle(.tertiary)
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Once the conversation exists, and not while a usage search waits to
    /// send.
    private var canPin: Bool {
        guard let session = questions.sessions[workbenchID] else { return false }
        return session.conversationID != nil && !session.isSearchingUsages
    }

    /// "App.swift:12" or "App.swift:12–14".
    static func anchorLabel(_ anchor: CodeQuestionAnchor) -> String {
        let name = (anchor.path as NSString).lastPathComponent
        let lines = anchor.range.startLine == anchor.range.endLine ? "\(anchor.range.startLine)"
            : "\(anchor.range.startLine)–\(anchor.range.endLine)"
        return "\(name):\(lines)"
    }
}
