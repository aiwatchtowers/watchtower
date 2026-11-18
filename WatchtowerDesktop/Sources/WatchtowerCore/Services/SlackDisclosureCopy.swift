import Foundation

/// The Slack LLM-provider disclosure (#1769, spec §6): the company-setup sheet
/// shows `setupTitle` and `setupLines` before the token field, the connect
/// confirm shows `connectLine(workspace:)`, both with the privacy link.
/// `SlackDisclosureCopyTests` pins it to the mockups' `SlackPolicyMockCopy`
/// and to the provider names of the Slack app manifest.
public enum SlackDisclosureCopy {
    public static let setupTitle = "What Watchtower does with your workspace's data"
    public static let setupLines = [
        "Each person's copy stays on their own Mac. Watchtower has no server.",
        "To write summaries and answer questions, it sends message text to the AI provider each person "
            + "chooses: Anthropic (Claude) or OpenAI (Codex) under their own account, or a local model (Ollama).",
        "Watchtower never trains a model. Whether a provider may train on what it receives is a setting "
            + "in that person's Claude or ChatGPT account.",
        "AI output can be wrong."
    ]
    public static let privacyLink = "Privacy policy"
    public static let privacyURL = URL(string: "https://aiwatchtowers.com/privacy/")!

    public static func connectLine(workspace: String) -> String {
        "Watchtower keeps a copy of what you can see in \(workspace) on this Mac and sends "
            + "message text to your AI provider."
    }
}
