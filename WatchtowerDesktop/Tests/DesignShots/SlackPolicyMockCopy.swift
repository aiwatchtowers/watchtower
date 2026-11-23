import Foundation

/// Design-only string table of the Slack Developer Policy hygiene spec
/// (`docs/superpowers/specs/2026-11-17-slack-policy-hygiene-design.md`, §8).
/// The implementation moves each group into the model the spec names
/// (`AccountPurgeStatus`, `FileVaultNotice`, `SlackDisclosureCopy`,
/// `PeopleCardCopy`, `SlackMarkReadCopy`) and pins it there;
/// `SlackPolicyMockCopyTests` pins this table so the mockups and the spec
/// cannot drift apart. Sample data only: `acme`, made-up people.
enum SlackPolicyMockCopy {
    // MARK: Settings → System → Privacy

    static let privacyTitle = "Privacy"
    static let purgeTitle = "Delete an account's data when its access ends"
    /// Off by default since the owner's 2026-11-23 decision.
    static let captionDefault = "Off by default"
    static let footOnAll = "On: when an account's access is revoked, or Watchtower has not reached its source for "
        + "30 days, its synced data is deleted 72 hours later unless you reconnect. A removed Slack workspace's "
        + "data goes 72 hours after the remove, another removed account's 30 days after it was last reached. "
        + "Briefings, recaps, ideas, memory, chats and meeting transcripts are kept."
    static let footOff = "Off: synced data stays on this Mac after access ends, until you delete it with "
        + "Reset All Data… in Settings → System. Slack expects a workspace's data to be gone within "
        + "14 business days after its app is removed."
    static let fileVaultOff = "FileVault is off, so Slack data on this Mac is not encrypted at rest. "
        + "Turn it on in System Settings → Privacy & Security → FileVault."
    static let openFileVault = "Open FileVault settings"

    // MARK: Connections → Slack

    static let workspacesTitle = "Workspaces"
    static let accountFull = "Full · your workspace's app"
    static let accountRemoved = "Removed"
    static let removedLine = "acme was removed. Its data will be deleted on Nov 20, 14:00 unless you add it again."
    static let addAgain = "Add again"

    // MARK: Remove dialog

    static let removeTitle = "Remove acme?"
    static let removeBodyOn = "Watchtower stops syncing acme and signs out of it at Slack, so this sign-in stops "
        + "working on every Mac that uses it. Its synced data stays for now and is deleted in 72 hours unless "
        + "you add the workspace again. Briefings, recaps, ideas, memory, chats and meeting transcripts are kept."
    static let removeBodyOff = "Watchtower stops syncing acme and signs out of it at Slack, so this sign-in stops "
        + "working on every Mac that uses it. Its synced data stays on this Mac until you delete it, because "
        + "deleting data when access ends is off."
    static let remove = "Remove"
    static let cancel = "Cancel"

    // MARK: Disclosure (Set up for my company, connect confirm)

    static let disclosureTitle = "What Watchtower does with your workspace's data"
    static let disclosureLines = [
        "Each person's copy stays on their own Mac. Watchtower has no server.",
        "To write summaries and answer questions, it sends message text to the AI provider each person "
            + "chooses: Anthropic (Claude) or OpenAI (Codex) under their own account, or a local model (Ollama).",
        "Watchtower never trains a model. Whether a provider may train on what it receives is a setting "
            + "in that person's Claude or ChatGPT account.",
        "AI output can be wrong."
    ]
    static let privacyLink = "Privacy policy"
    static let connectLine = "Watchtower keeps a copy of what you can see in acme on this Mac and sends "
        + "message text to your AI provider."

    // MARK: People

    static let personName = "@dana"
    static let personPeriod = "Nov 3 – Nov 16"
    static let basisLine = "Based on 42 messages in 5 channels you share"
    static let personSummary = "Drives the billing migration; settles API questions in #billing-dev within a day."
    static let decisionRoleTitle = "Decision role"
    static let decisionRole = "Decision-maker"
    static let guideTitle = "Communication Guide"
    static let guideText = "Prefers a short written proposal in the thread before a call; answers fastest when "
        + "the question names the ticket."
    static let tacticsTitle = "Tactics"
    static let tactics = ["If a billing change needs sign-off, post the diff summary in #billing-dev first."]
    static let stopCard = "Stop card for this person"
    static let stopTitle = "Stop the card for @dana?"
    static let stopBody = "Watchtower deletes @dana's card and makes no new one. Messages, digests, search and "
        + "Find experts are not affected. You can make cards again later."
    static let stopConfirm = "Stop card"
    static let stoppedLine = "No card for @dana: you stopped it."
    static let makeAgain = "Make cards again"

    static let peopleTitle = "People"
    static let peopleRows: [(name: String, role: String, line: String)] = [
        ("@dana", "Decision-maker", "Billing migration, API questions"),
        ("@lee", "Approver", "Release sign-off, on-call rota"),
        ("@sam", "Contributor", "Checkout UI, design reviews")
    ]
    static let teamSummaryTitle = "Team Summary"
    static let teamSummary = "The team closed the billing migration's first phase and moved release sign-off "
        + "to a weekly slot."
    static let tipsTitle = "Tips"
    static let tips = ["Bring billing questions to #billing-dev before Thursday's sign-off."]
    static let orgLinksTitle = "Your org links"
    static let orgLinks: [(role: String, name: String)] = [("Manager", "@lee"), ("Peer", "@sam"), ("Peer", "@dana")]
    static let orgLinksEmpty = "No org links yet. Add your manager, peers and reports in your profile."
    static let editConnections = "Edit Connections"

    // MARK: Digest detail (Mark read in Slack removed)

    static let digestTitle = "#billing-dev"
    static let digestMessages = "214 messages"
}
