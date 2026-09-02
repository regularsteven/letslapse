import CoreGraphics
import LetsLapseKit

/// The fine rotation the Adjust and Guided screens' source-frame previews
/// are levelled by, so a punch or a canvas crop is composed on the picture
/// the render will actually crop — the levelled one — rather than on the
/// raw frame.
///
/// A main-actor lookup rather than a parameter because the previews are
/// drawn by a dozen small views (`WarpPreviewLoader`, `ExactFrameLoader`
/// and their owners), none of which otherwise knows the project; threading
/// one number through all of them to answer "which project is open" is
/// what `AppModel` already exists for. `AppModel` installs the provider
/// once, at launch.
@MainActor
enum AdjustPreviewLevel {
    /// Answers with the current project's rotation in degrees, 0 when no
    /// project is open. Installed by `AppModel.init`.
    static var provider: () -> Double = { 0 }

    static var degrees: Double { provider() }

    /// `image` levelled by the current project's rotation — a no-op copy of
    /// the reference at zero.
    static func apply(_ image: CGImage) -> CGImage {
        PhotoGrader.rotated(image, degrees: degrees)
    }
}
