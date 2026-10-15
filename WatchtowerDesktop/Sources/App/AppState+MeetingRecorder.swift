import Foundation
import GRDB
import Observation
import WatchtowerCore

extension AppState {
    /// Hands the MeetingRecorderCenter its voice-registry closures once the
    /// shared pool opens (the Center is created before the DB). Both degrade
    /// on failure instead of throwing — voice naming is a progressive
    /// enhancement like roles themselves: a failed read → nil, identification
    /// off for that recording (plain "Speaker N" labels, nothing queued or
    /// learned — spec §2.6); a failed write → nothing queued (the transcript
    /// is already saved).
    /// Failures are printed, never silent (the renderRoles diagnostics
    /// convention). `func`, not `private func`, so @testable tests can wire a
    /// test DB through it (the initSecretaryProfile precedent).
    func wireMeetingRecorderLoaders(dbPool: DatabasePool) {
        meetingRecorderCenter.registryLoader = { eventID in
            do {
                return try await dbPool.read { db in try Self.loadVoiceRegistry(db, eventID: eventID) }
            } catch {
                print("[AppState] voice registry load failed, identification disabled for this run: "
                      + error.localizedDescription)
                return nil
            }
        }
        meetingRecorderCenter.registryWriter = { transcriptID, outcome in
            do {
                return try await dbPool.write { db -> Int in
                    for sample in outcome.autoSamples {
                        var sample = sample
                        sample.transcriptID = transcriptID
                        try VoiceSampleQueries.insertAuto(db, sample)
                    }
                    for task in outcome.tasks {
                        try VoiceLabelQueueQueries.enqueue(
                            db, transcriptID: transcriptID, clusterLabel: task.label, reason: task.reason,
                            suggestedPersonID: task.personID, score: task.score)
                    }
                    return outcome.tasks.count
                }
            } catch {
                print("[AppState] voice registry write failed for transcript \(transcriptID), nothing queued: "
                      + error.localizedDescription)
                return 0
            }
        }

        voiceRegistryCenter.attach(dbPool: dbPool)
        // Launch catch-up: the one full retro pass (spec §4.1), skipped with
        // "Voice recognition" off (spec §6).
        let voiceRecognition = TranscriptionConfig.fromDefaults().voiceRecognition
        voiceRegistryCenter.startCatchUp(voiceRecognition: voiceRecognition)
        observeVoiceRegistryCatchUp()
    }

    /// Keeps `voiceRegistryCenter` in sync with every meeting-recorder save
    /// (`MeetingRecorderCenter.savedTick`) via manual Observation tracking —
    /// there's no view guaranteed to stay mounted for the app's whole
    /// lifetime to drive a SwiftUI `.onChange` here, so AppState re-arms its
    /// own tracking closure after each fire.
    private func observeVoiceRegistryCatchUp() {
        withObservationTracking {
            _ = meetingRecorderCenter.savedTick
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                await self.handleMeetingRecorderSaved()
                self.observeVoiceRegistryCatchUp()
            }
        }
    }

    /// Hands the recorder Center its real meetings provider (the Center is
    /// created before the dbPool exists — the `wireMeetingRecorderLoaders`
    /// precedent) and starts the warm-engine policy poll. A read failure is
    /// treated as "no meetings" and logged (the MeetingReminder convention):
    /// the worst outcome is a missed prewarm or a one-tick-late unload, both
    /// self-correcting — never a crash, never an unload mid-recording (the
    /// policy never touches a busy engine regardless of the window).
    func startWarmEnginePolicy(dbPool: DatabasePool) {
        meetingRecorderCenter.configureWarmPolicy { now in
            do {
                // Candidate events overlapping the prewarm lookahead:
                // fetchEvents matches start_time <= to AND end_time >= from,
                // so this returns both ongoing meetings and ones starting
                // within the lead; the pure logic sorts out which is which.
                let events = try dbPool.read { db in
                    try CalendarQueries.fetchEvents(
                        db,
                        from: now,
                        to: now.addingTimeInterval(WarmEnginePolicy.prewarmLead)
                    )
                }
                return WarmEnginePolicy.window(events: events, now: now)
            } catch {
                print("[AppState] warm-policy event read failed, treating as no meetings: "
                      + error.localizedDescription)
                return .noMeetings
            }
        }
        meetingRecorderCenter.startWarmPolicy()
    }
}
