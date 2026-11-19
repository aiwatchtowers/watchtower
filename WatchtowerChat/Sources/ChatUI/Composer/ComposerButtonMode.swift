/// What the composer's round button is (#2065 §5). With `sendWhileStreaming` (the Workchat) it is Send whenever
/// the field holds something to send, in every state, and Stop only with nothing to send while the agent works —
/// Claude Code's own behaviour. Without it (the AI chat, the phone) it is Stop for as long as a reply streams.
public enum ComposerButtonMode: Equatable {
    case send(active: Bool)
    case stop(active: Bool)

    public static func resolve(isStreaming: Bool, sendWhileStreaming: Bool, canSend: Bool, canStop: Bool) -> Self {
        guard isStreaming else { return .send(active: canSend) }
        if sendWhileStreaming && canSend { return .send(active: true) }
        return .stop(active: canStop)
    }
}
