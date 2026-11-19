import Foundation

/// A transport that loads a zone into a local buffer page by page (the hosted relay's pull) says whether the
/// data zone's load is whole. The replica hydrator asks before it reads: a route-change sweep deletes what the
/// new transport did not return, which is only knowable once the load has finished. A transport that does not
/// conform is read as always complete.
public protocol InitialLoadReporting: CloudSyncTransport {
    /// False while a pull is in flight or the data zone's first pull or resync has pages left (also after a
    /// failure midway or an app restart); true when the buffer holds the whole zone.
    func dataLoadComplete() async -> Bool
}
