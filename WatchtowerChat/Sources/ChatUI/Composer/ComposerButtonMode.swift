/// What the composer's round button is (#2065 §5). With `sendWhileStreaming` (the Workchat) it is Send whenever
/// the field holds something to send, in every state, and Stop only with nothing to send while the agent works —
/// Claude Code's own behaviour. Without it (the AI chat, the phone) it is Stop for as long as a reply streams.
public enum ComposerButtonMode: Equatable {
    case sendButton(active: Bool)
    case stopButton(active: Bool)

    public static func resolve(isStreaming: Bool, sendWhileStreaming: Bool, canSend: Bool, canStop: Bool) -> Self {
        guard isStreaming else { return .sendButton(active: canSend) }
        if sendWhileStreaming && canSend { return .sendButton(active: true) }
        return .stopButton(active: canStop)
    }
}
