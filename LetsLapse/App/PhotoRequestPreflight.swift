import AVFoundation

/// The questions iOS 27 asks of a `capturePhoto(with:delegate:)` request,
/// asked first.
///
/// Built against the iOS 27 SDK, a request AVFoundation refuses is no longer a
/// dropped shot but an NSException Swift cannot catch:
/// `-[AVCapturePhotoOutput capturePhotoWithSettings:delegate:]` validates, and
/// `_AVCaptureShouldThrowForAPIViolations` turns what older SDKs logged
/// (*"Suppressing exception throw for API contract violation"*) into an abort.
/// The iPhone 18 Pro aborted on it four times in Photo mode, every logged time
/// on its 4224×3024 format at 8× (docs/fieldtests/2026-09-26-18pro-crash-triage.md).
///
/// Only the checks a plain still request from this app can fail are mirrored,
/// and only as AVFoundation states them — the quoted refusals are its own,
/// read from the iOS 27 binary. A request these checks pass is sent exactly as
/// it was before; anything else comes back with the sizes involved, so the log
/// says which check it was.
enum PhotoRequestPreflight {
    /// *"No active and enabled video connection"* — nothing in the request can
    /// fix it, so the caller skips the shot.
    static func connectionProblem(of output: AVCapturePhotoOutput) -> String? {
        guard let connection = output.connection(with: .video) else {
            return "the photo output has no video connection"
        }
        guard connection.isActive, connection.isEnabled else {
            return "the photo output's video connection is not active and enabled"
                + " (active \(connection.isActive), enabled \(connection.isEnabled))"
        }
        return nil
    }

    /// The size to put in `maxPhotoDimensions` (nil: leave it unset), with a
    /// note to log when there is something to say.
    ///
    /// Mirrors *"…must not be larger than the maxPhotoDimensions set on the
    /// AVCapturePhotoOutput"* and *"…must match one of the
    /// supportedMaxPhotoDimensions of the video devices's active format"*. A
    /// size both take is asked as chosen; failing that, the largest smaller one
    /// they take, so a still never grows past what was chosen; failing that,
    /// none — unset, the output's own maximum governs, as it always has for the
    /// Scanner.
    static func dimensions(
        _ wanted: CMVideoDimensions,
        output: AVCapturePhotoOutput,
        device: AVCaptureDevice?
    ) -> (dimensions: CMVideoDimensions?, note: String?) {
        let ceiling = output.maxPhotoDimensions
        let listed = device?.activeFormat.supportedMaxPhotoDimensions ?? []
        func takes(_ size: CMVideoDimensions) -> Bool {
            size.width <= ceiling.width && size.height <= ceiling.height
                && (device == nil || listed.contains { same($0, size) })
        }
        let chosen = takes(wanted)
            ? wanted
            : listed
                .filter { pixels($0) < pixels(wanted) && takes($0) }
                .max { pixels($0) < pixels($1) }
        let asChosen = chosen.map { same($0, wanted) } ?? false
        let aside = constituentAside(wanted, device: device)
        if asChosen, aside == nil { return (wanted, nil) }

        var facts = ["the output's maximum is \(label(ceiling))"]
        if device != nil { facts.append("the active format lists \(labels(listed))") }
        if let aside { facts.append(aside) }
        let outcome: String
        if asChosen {
            outcome = "asked as chosen"
        } else if let chosen {
            outcome = "would be refused — asking \(label(chosen))"
        } else {
            outcome = "would be refused — left unset"
        }
        return (chosen, "\(label(wanted)) \(outcome) (\(facts.joined(separator: "; ")))")
    }

    /// Not one of AVFoundation's stated checks, so reported, never acted on:
    /// whether the active constituent's own format lists the size is the open
    /// question of the 18 Pro's aborts, which all came on the telephoto of a
    /// Triple Camera. If one still comes, the line logged before it answers.
    private static func constituentAside(_ size: CMVideoDimensions, device: AVCaptureDevice?) -> String? {
        #if os(iOS)
        guard let device, device.isVirtualDevice,
              let constituent = device.activePrimaryConstituent else { return nil }
        let theirs = constituent.activeFormat.supportedMaxPhotoDimensions
        guard !theirs.contains(where: { same($0, size) }) else { return nil }
        return "\(constituent.localizedName)'s format lists \(labels(theirs))"
        #else
        return nil
        #endif
    }

    private static func same(_ a: CMVideoDimensions, _ b: CMVideoDimensions) -> Bool {
        a.width == b.width && a.height == b.height
    }

    private static func pixels(_ size: CMVideoDimensions) -> Int64 {
        Int64(size.width) * Int64(size.height)
    }

    private static func label(_ size: CMVideoDimensions) -> String {
        "\(size.width)×\(size.height)"
    }

    private static func labels(_ sizes: [CMVideoDimensions]) -> String {
        sizes.isEmpty ? "nothing" : sizes.map(label).joined(separator: ", ")
    }
}
