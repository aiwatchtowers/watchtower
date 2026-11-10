import Foundation
import WatchtowerCore

/// The agents' transcripts as the center finds them: whether a row's stored
/// session has one, and whether a relaunch resumes it.
extension TerminalCenter {
    /// Each agent's transcript lookup over this center's seams.
    private var transcriptLookups: AgentTranscriptLookups {
        AgentTranscriptLookups(claude: transcriptExists, codex: codexRolloutExists)
    }

    /// Whether the agent has a transcript for the row's stored session id,
    /// through its session adapter: Claude Code's under `~/.claude`, Codex's
    /// rollout under its home in the app's environment. No id, no transcript.
    /// A lookup that failed reads as none here: a relaunch of an agent that
    /// mints its own id is decided by the view model with `resumesStoredID`,
    /// which passes the answer.
    func hasTranscript(_ session: TerminalSession) -> Bool {
        guard let id = session.claudeSessionID, let agent = session.kind.agent?.session else { return false }
        let home = agent.transcriptHome(environment: Constants.resolvedEnvironmentIfReady())
        return (try? agent.transcriptExists(id: id, storedPath: session.transcriptPath, home: home, in: transcriptLookups))
            ?? false
    }

    /// Whether relaunching (not fresh) the row of an agent that mints its own
    /// session id (`AgentSessionCaps.appSessionID` false: Codex) resumes its
    /// stored id: a valid id whose transcript exists — at its stored path, or
    /// under `home` (the login shell's, resolved by the caller; nil checks the
    /// stored path alone). Throws when the agent's transcript folder could not
    /// be listed, so the caller does not drop the id on it.
    func resumesStoredID(_ session: TerminalSession, home: URL?) throws -> Bool {
        guard let agent = session.kind.agent?.session, !agent.caps.appSessionID,
              let id = session.claudeSessionID, TerminalLaunch.isValidSessionID(id) else {
            return false
        }
        return try agent.transcriptExists(id: id, storedPath: session.transcriptPath, home: home, in: transcriptLookups)
    }
}
