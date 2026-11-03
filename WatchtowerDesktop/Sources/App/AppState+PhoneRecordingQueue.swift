import Foundation
import GRDB
import WatchtowerCore

extension AppState {
    /// Phone recordings on the Go hub, claimed, reported and finished over its
    /// control socket (go hub plan 3 Task 17): `previous` stopped, a new queue
    /// started on `hub`'s watch (a rescan at each snapshot, a take on each
    /// `recording_queued`). None without a hub center (XCTest).
    func replacePhoneRecordingQueue(
        _ previous: PhoneRecordingQueue?, hub: HubCenter?, dbPool: DatabasePool, cliRunner: (any CLIRunnerProtocol)?
    ) -> PhoneRecordingQueue? {
        previous?.stop()
        guard let hub else { return nil }
        let queue = PhoneRecordingQueue.live(cli: cliRunner, recorder: meetingRecorderCenter, dbPool: dbPool)
        queue.start()
        hub.onWatchConnected = { [weak queue] in queue?.rescan() }
        hub.onRecordingQueued = { [weak queue] in queue?.recordingQueued($0) }
        return queue
    }
}
