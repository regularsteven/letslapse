import Foundation

/// What a push does about the poster and the working copy when it reaches
/// the render step — decided before any GPU work, from whether the app is
/// in front and what PicPlace already holds of the project (2026-10-16).
///
/// iOS runs no GPU work for a backgrounded app: a Metal command buffer
/// from one is aborted, so a poster rendered after the phone locked or the
/// person switched apps comes back empty. On 2026-10-16 the 18 Pro
/// auto-pushed twenty new projects in one run; the first five, rendered in
/// front, went up with their poster and working copy, and the fifteen after
/// the lock went up as records alone — every other device drew them blank,
/// and the record counted each as a *failed* render, gated for six hours.
/// The gate makes the background a deferral, never a failure: a new project
/// is not sent at all until the app is in front (it goes up whole then), an
/// edit's records go without the poster and the poster is queued for the
/// front, and a poster catch-up with nothing else to send simply waits.
///
/// Pure: the caller reads the application state and its sync record.
public enum PicPlacePushGate {

    public enum Outcome: Equatable, Sendable {
        /// In front: render the poster and the working copy, then send.
        case render
        /// Not in front, and PicPlace has never had this project's records
        /// from this device: nothing is sent — the push stops before the
        /// run and stays due, so the next one in front sends it whole.
        case deferWhole
        /// Not in front, and the records must go (an edit PicPlace lacks):
        /// they are sent without a render, the poster noted as deferred so
        /// the next check in front queues it at once.
        case sendRecordsOnly
        /// Not in front, the records in step, only the poster (or the
        /// working copy) was due: nothing is sent — the push stays due for
        /// the front.
        case deferPoster
    }

    /// `inFront`: the app may render now (on iOS, `applicationState == .active`;
    /// the Mac renders whenever). `recordsOnServer`: a push by this device
    /// reached PicPlace once (`PicPlaceSyncRecord.recordsReachedServer`).
    /// `recordsMoved`: the project's revision is past the one PicPlace
    /// agreed, or there is no record at all.
    public static func outcome(inFront: Bool, recordsOnServer: Bool, recordsMoved: Bool) -> Outcome {
        if inFront { return .render }
        if !recordsOnServer { return .deferWhole }
        return recordsMoved ? .sendRecordsOnly : .deferPoster
    }
}
