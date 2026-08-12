import Foundation

/// A decision paired with metadata from its parent digest, for the flat decisions list.
package struct DecisionEntry: Identifiable, Equatable {
    package let decision: Decision
    package let digestID: Int
    package let decisionIdx: Int   // index in the decisions JSON array
    package let channelID: String
    package let channelName: String?
    package let digestSummary: String
    package let digestType: String
    package let date: Date       // from digest's periodTo
    package let messageTS: String?
    package let isRead: Bool
    package let correctedImportance: String?  // user override, nil = no correction

    package init(
        decision: Decision,
        digestID: Int,
        decisionIdx: Int,
        channelID: String,
        channelName: String?,
        digestSummary: String,
        digestType: String,
        date: Date,
        messageTS: String?,
        isRead: Bool,
        correctedImportance: String?
    ) {
        self.decision = decision
        self.digestID = digestID
        self.decisionIdx = decisionIdx
        self.channelID = channelID
        self.channelName = channelName
        self.digestSummary = digestSummary
        self.digestType = digestType
        self.date = date
        self.messageTS = messageTS
        self.isRead = isRead
        self.correctedImportance = correctedImportance
    }

    package var id: String { "\(digestID)-\(decision.id)" }

    /// The effective importance: user correction if present, otherwise AI-generated.
    package var effectiveImportance: String {
        correctedImportance ?? decision.resolvedImportance
    }

    /// Returns a copy with isRead overridden.
    package func with(isRead: Bool) -> Self {
        Self(
            decision: decision,
            digestID: digestID,
            decisionIdx: decisionIdx,
            channelID: channelID,
            channelName: channelName,
            digestSummary: digestSummary,
            digestType: digestType,
            date: date,
            messageTS: messageTS,
            isRead: isRead,
            correctedImportance: correctedImportance
        )
    }

    /// Returns a copy with correctedImportance overridden.
    package func with(correctedImportance: String?) -> Self {
        Self(
            decision: decision,
            digestID: digestID,
            decisionIdx: decisionIdx,
            channelID: channelID,
            channelName: channelName,
            digestSummary: digestSummary,
            digestType: digestType,
            date: date,
            messageTS: messageTS,
            isRead: isRead,
            correctedImportance: correctedImportance
        )
    }
}
