import Foundation

/// The Usage → Watchtower tab's name for an LLM call's purpose: the
/// `digest.WithSource` / `llmusage.WithPurpose` tag the Go side records in
/// `llm_calls.purpose`. A tag missing here shows as itself under "Other",
/// so a new Go tag is never hidden — it only reads raw until it gets a name.
package enum LLMPurposeNames {
    package static func display(purpose: String) -> (name: String, group: String) {
        if purpose.isEmpty { return ("Untagged", "Untagged") }
        if let known = table[purpose] { return known }
        return (purpose, "Other")
    }

    /// Every purpose with a name of its own.
    package static var knownPurposes: [String] { Array(table.keys) }

    private static let table: [String: (name: String, group: String)] = {
        var map: [String: (name: String, group: String)] = [:]
        for (group, rows) in groups {
            for (purpose, name) in rows { map[purpose] = (name, group) }
        }
        return map
    }()

    /// Group → (purpose, name).
    private static let groups: [(String, [(String, String)])] = [
        ("Slack", [
            ("digest.channel", "Slack digests"),
            ("digest.channel_batch", "Slack digests (batched)"),
            ("digest.daily", "Daily digest"),
            ("digest.weekly", "Weekly digest"),
            ("digest.period", "Period summaries"),
            ("analysis.period", "Period analysis"),
            ("light", "Quick classifications")
        ]),
        ("Built-in automations", [
            ("briefing.daily", "Morning brief"),
            ("day_plan.generate", "Morning brief — day plan"),
            ("tracks.extract_batch", "Track my threads"),
            ("ideas.consolidate", "Idea finder"),
            ("ideas.digest_email", "Idea finder — email"),
            ("ideas.digest_jira", "Idea finder — Jira"),
            ("reactioncmd.command", "Reactions")
        ]),
        ("Tracks", [
            ("customtrack.compose", "Custom tracks — setup"),
            ("customtrack.shortlist", "Custom tracks — shortlist"),
            ("customtrack.run", "Custom tracks"),
            ("track.compose", "Custom tracks — setup"),
            ("track.shortlist", "Custom tracks — shortlist"),
            ("track.run", "Custom tracks")
        ]),
        ("People", [
            ("people.batch", "People cards"),
            ("people.reduce", "People summaries"),
            ("people.team", "Team summary")
        ]),
        ("Tasks and targets", [
            ("tasks.generate", "Task suggestions"),
            ("tasks.update", "Task updates"),
            ("targets.extract", "Targets from messages"),
            ("targets.link", "Target links"),
            ("targets.next_step", "Target next steps")
        ]),
        ("Meetings", [
            ("meeting.prep", "Meeting prep"),
            ("meeting.recap", "Meeting recaps"),
            ("meeting.notes", "Meeting notes"),
            ("meeting.chapters", "Meeting chapters"),
            ("meeting.extract_topics", "Meeting topics"),
            ("meeting.followup", "Meeting follow-ups"),
            ("dictation.clean", "Dictation clean-up")
        ]),
        ("Memory", [
            ("memory.extract_episodes", "Memory — episodes"),
            ("memory.extract_episodes_batch", "Memory — episodes (batched)"),
            ("memory.extract_email_episodes", "Memory — email episodes"),
            ("memory.entity_rewrite", "Memory — entity pages"),
            ("memory.revise_beliefs", "Memory — beliefs"),
            ("memory.render_map", "Memory — world map"),
            ("memory.reflect", "Memory — weekly reflection"),
            ("memory.render_channel_digest", "Memory — channel pages")
        ]),
        ("Catch-Up and Inbox", [
            ("catchup.compose", "Catch-Up recaps"),
            ("catchup.learn", "Feedback rules"),
            ("inbox.style_sample", "Writing style sample")
        ]),
        ("Knowledge", [
            ("media.describe", "Image descriptions"),
            ("media.summarize_link", "Link summaries")
        ]),
        ("Jira", [
            ("jira.fields", "Jira field mapping"),
            ("jira.boards", "Jira board analysis")
        ]),
        ("Automations", [
            ("automation.llm", "Automation steps"),
            ("automation.llm.strong", "Automation steps (strong)"),
            ("automation.agent", "Automation agents")
        ]),
        ("Workbench", [
            ("workbench.spec_review", "Spec reviews"),
            ("workbench.review_overview", "Review overviews"),
            ("workbench.review_lessons", "Review lessons"),
            ("workbench.ask_guard", "Ask guard"),
            ("review.overview", "Review overviews"),
            ("review.lessons", "Review lessons"),
            ("review.spec", "Spec reviews"),
            ("terminal.title", "Session titles")
        ]),
        ("Assistant", [
            ("chat.title", "Chat titles"),
            ("ask", "Ask from the terminal"),
            ("instructions.suggest", "Agent instruction suggestions"),
            ("coach.propose", "Agent coach"),
            ("prompts.tune", "Prompt tuning")
        ]),
        ("Setup", [
            ("probe", "Model checks")
        ])
    ]
}
