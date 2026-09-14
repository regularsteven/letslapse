import Foundation

/// The `mode` strings the app registers projects with and classifies by
/// (data model M2). They were `AppModel`'s statics; the index classifies a
/// project at index time and the `lapse` CLI rebuilds the same index, so
/// the strings live here and the app's statics forward to them. A reworded
/// display string would change the stored mode of every project registered
/// afterwards — which is why these are the one place the words are written.
public enum ProjectModes {
    /// A one-tap Photo-mode capture: one asset, blended or not.
    public static let photo = "Photo"
    /// A single picture imported from a file — one asset, no sequence.
    public static let importedPhoto = "Photo · Imported"
    /// A video imported from a file.
    public static let importedVideo = "Import"
    /// The mode line a Scanner shoot registers with — the back-stop that
    /// identifies Scanner projects registered before `captureMode` existed.
    public static let scanner = "Interval · Scanner"
    /// `captureMode`'s value for a Scanner registration (since 2026-08-16).
    public static let scannerCaptureMode = "scanner"
}

/// What a project is to the lists: the Projects filter bar's four kinds,
/// which are not the record's two `kind`s — a Photo and an interval shoot
/// are both `photos`, and a scan is an interval shoot that is a document.
///
/// The rules are the app's own, moved here so the index can store the
/// verdict as a column (`CaptureFilter.matches`, `CaptureProject
/// .isPhotoCapture`, `.isScannerCapture`, `AppModel.isScannerProject`):
///
/// - **scan**: `captureMode == "scanner"`, or a `photos`-kind project whose
///   mode is the scanner's line, or — for scanner runs older than either —
///   a `photos`-kind non-Photo project whose `frames.timestamps` carries a
///   rectangle (`scannerSidecar`, read once by the index and kept).
/// - **photo**: `photos` kind with the Photo or imported-photo mode.
/// - **video**: the `video` kind.
/// - **interval**: every other `photos`-kind project.
public enum ProjectCategory: String, CaseIterable, Sendable, Codable {
    case photo, interval, video, scan

    public static func classify(kind: String, mode: String, captureMode: String?, scannerSidecar: Bool) -> ProjectCategory {
        let photos = kind == "photos"
        if captureMode == ProjectModes.scannerCaptureMode { return .scan }
        if photos && mode == ProjectModes.scanner { return .scan }
        let isPhoto = photos && (mode == ProjectModes.photo || mode == ProjectModes.importedPhoto)
        if isPhoto { return .photo }
        if kind == "video" { return .video }
        if photos && scannerSidecar { return .scan }
        return .interval
    }

    /// True for the projects whose category can only be settled by the
    /// sidecar: `photos` kind, not a Photo, not called a scanner.
    public static func needsSidecar(kind: String, mode: String, captureMode: String?) -> Bool {
        guard kind == "photos", captureMode != ProjectModes.scannerCaptureMode, mode != ProjectModes.scanner else { return false }
        return mode != ProjectModes.photo && mode != ProjectModes.importedPhoto
    }

    /// Whether `source/frames.timestamps` in `folder` records a rectangle on
    /// any frame — the scanner's pose record. False when there is no sidecar.
    public static func sidecarHasRectangle(inProjectFolder folder: URL) -> Bool {
        let url = folder.appendingPathComponent("source", isDirectory: true).appendingPathComponent(FrameTimestamps.fileName)
        guard FileManager.default.fileExists(atPath: url.path),
              let timestamps = try? FrameTimestamps.load(from: url) else { return false }
        return timestamps.entries.contains { $0.rectangle != nil }
    }
}

/// The Gallery sidebar's SHAPES rows, as the index answers them: a project's
/// `shapes.json` counted the way `ShapeSummary` counts it — ellipses one
/// row whatever their obliquity, quads split by family. `none` is a project
/// with an empty register or none at all.
public enum ShapeRow: String, CaseIterable, Sendable {
    case ellipse, rectangle, square, none
}

/// A scene tag's chip label — the words a person reads, and therefore
/// types: the taxonomy's two camel-cased values are the only ones that need
/// translating, and everything else is capitalised. Lives in the Kit so the
/// index can put the label beside the raw tag in the search table (M2:
/// "weather" finds `skyWeather` the way the substring search did);
/// `SceneMetadata.label(for:)` in the app forwards here.
public enum SceneTagLabel {
    public static func label(for tag: String) -> String {
        switch tag {
        case "skyWeather": return "Sky & weather"
        case "lightTrails": return "Light trails"
        default: return tag.prefix(1).uppercased() + tag.dropFirst()
        }
    }
}
