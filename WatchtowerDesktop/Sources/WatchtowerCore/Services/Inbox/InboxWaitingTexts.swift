import Foundation

/// The lines of Waiting for me and Mail waiting (spec "Waiting for me and
/// Mail waiting"): the list row's preview and meta, the panes' subtitles.
/// Pure.
package enum InboxWaitingTexts {
    /// Mail waiting's row preview: "<today> new today. Most of it comes from
    /// <K> senders: clear a sender in one press." K is the top ten (or fewer)
    /// senders `mailMeta` gives the share of; "Most of it" only above half,
    /// else "It comes from <senderCount> senders…"; no sender, no second
    /// sentence.
    package static func mailPreview(_ s: MailWaitingSummary) -> String {
        let head = s.today > 0 ? "\(s.today) new today." : "No new mail today."
        guard s.senderCount > 0 else { return head }
        let tail = s.topTenShare > 50
            ? "Most of it comes from \(senders(topSenders(s)))"
            : "It comes from \(senders(s.senderCount))"
        return "\(head) \(tail): clear a sender in one press."
    }

    /// Mail waiting's row meta: "<open> open · <share>% from <K> senders";
    /// "<open> open" with no sender.
    package static func mailMeta(_ s: MailWaitingSummary) -> String {
        guard s.senderCount > 0 else { return "\(s.open) open" }
        return "\(s.open) open · \(s.topTenShare)% from \(senders(topSenders(s)))"
    }

    /// Mail waiting's pane subtitle.
    package static func mailPaneSubtitle(_ s: MailWaitingSummary) -> String {
        "\(s.open) open · \(s.today) new today · grouped by sender, the busiest first"
    }

    /// Waiting for me's pane subtitle.
    package static func peoplePaneSubtitle(_ c: PeopleWaitingCounts) -> String {
        "People in Slack, Jira and Linear · \(c.today) new today · \(c.older) older · mail is in Mail waiting"
    }

    /// The senders `topTenShare` is over: the top ten, or fewer.
    private static func topSenders(_ s: MailWaitingSummary) -> Int { min(10, s.senderCount) }

    private static func senders(_ n: Int) -> String { n == 1 ? "1 sender" : "\(n) senders" }
}
