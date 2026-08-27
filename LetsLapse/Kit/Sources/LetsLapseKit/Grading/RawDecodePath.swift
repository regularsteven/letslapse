import Foundation

/// Which raw-decode pipeline converts DNG bytes → a linear-light Metal texture
/// ready for the grade engine, and — the part that actually separates these —
/// *where in that chain the white balance is applied*.
///
/// The engine has always decoded DNGs through `CIRAWFilter` (see
/// `LinearFrameDecoder`), which applies Apple's full device colour profile.
/// What the temperature/tint sliders do afterwards is a plain 3×3 in linear
/// Display P3, built by Bradford chromatic adaptation in `ToneMath`. So the
/// four paths below are not four demosaicers — they are four answers to
/// "which matrix, applied where":
///
/// | path        | demosaic + profile | white balance applied            |
/// |-------------|--------------------|----------------------------------|
/// | `bradford`  | CIRAWFilter        | P3 Bradford 3×3, after the profile |
/// | `forwardmatrix` | CIRAWFilter    | P3 3×3 from the DNG's own calibration, after the profile |
/// | `ciraw`     | CIRAWFilter        | inside the converter, in camera space, *before* the profile |
/// | `dcp`       | —                  | scaffold only                    |
///
/// That middle column is why `ciraw` is the interesting one for shadow colour:
/// Lightroom balances in camera space ahead of its profile's tone-dependent
/// rendering, and a matrix applied downstream in P3 cannot reproduce what a
/// profile does when it sees re-balanced camera data.
public enum RawDecodePath: String, CaseIterable, Codable, Sendable {
    /// Original path: Bradford chromatic adaptation via `ToneMath`. Default.
    case bradfordAdaptation = "bradford"
    /// Build the same post-profile 3×3 from the DNG's own colour calibration —
    /// `ForwardMatrix1/2` when the file carries them, otherwise the DNG spec's
    /// documented fallback (the inverse of the interpolated `ColorMatrix`) —
    /// so the adaptation travels through the camera's measured response
    /// instead of a generic cone space.
    case forwardMatrix = "forwardmatrix"
    /// Let `CIRAWFilter` do the white balance itself, in camera space ahead of
    /// Apple's device colour profile — the same ordering Lightroom uses. The
    /// grade-side matrix becomes identity.
    case cirawFilter = "ciraw"
    /// Balance in the converter as `.cirawFilter` does, then run the camera's
    /// Adobe profile — its hue/sat and look tables — over the result.
    ///
    /// The only path that moves hue *differently at different brightnesses*,
    /// which is the part of Lightroom's rendering no 3×3 can imitate. Needs
    /// Adobe's profile set installed; see `DCPProfileLocator`.
    case dcpProfile = "dcp"

    /// Short label for settings UI and CLI help.
    public var displayName: String {
        switch self {
        case .bradfordAdaptation: return "Bradford (default)"
        case .forwardMatrix: return "Forward matrix"
        case .cirawFilter: return "Core Image RAW"
        case .dcpProfile: return "Adobe DCP"
        }
    }

    /// One line on what the path changes, for the settings picker's footer.
    public var summary: String {
        switch self {
        case .bradfordAdaptation:
            return "White balance as a Bradford 3×3 in Display P3, after Apple's camera profile."
        case .forwardMatrix:
            return "Same insertion point, but the matrix comes from the DNG's own calibration tags."
        case .cirawFilter:
            return "White balance inside the raw converter, in camera space — Lightroom's ordering."
        case .dcpProfile:
            return "Lightroom's ordering plus the camera's Adobe profile tables. Needs Adobe profiles installed."
        }
    }

    /// `UserDefaults` key backing `current`.
    public static let defaultsKey = "rawDecodePath"

    /// The process-wide selection. Reads and writes `UserDefaults.standard`
    /// under `rawDecodePath`, so the app's settings picker, the `lapse`
    /// CLI's `--decode-path` and the tests all move the same switch.
    ///
    /// An unavailable stored value (a `.dcp` written by a build that had it,
    /// say) resolves back to the default rather than throwing at render time.
    public static var current: RawDecodePath {
        get {
            guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
                  let path = RawDecodePath(rawValue: raw),
                  RawDecodePathRegistry.isAvailable(path) else {
                return .bradfordAdaptation
            }
            return path
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }
}

/// Which paths this build can actually run.
public enum RawDecodePathRegistry {
    /// `true` for `.dcpProfile` only where Adobe's profile set is installed,
    /// and for `.cirawFilter` above its OS floor; `true` otherwise.
    ///
    /// The `CIRAWFilter` check is structural rather than load-bearing here:
    /// `LetsLapseKit` already floors at iOS 16 / macOS 13, both above the
    /// iOS 15 / macOS 12 the API needs, so on every platform this package
    /// builds for the answer is `true`. It stays because the floor is the
    /// package manifest's to change, not this file's.
    ///
    /// The DCP check is the load-bearing one. The profiles ship with
    /// Lightroom and Camera Raw rather than with this app — Adobe's licence is
    /// not ours to redistribute under — so the path exists on a Mac with
    /// Lightroom installed and nowhere else. On iOS it is always false, which
    /// is a property of the platform and not a build setting: there is no
    /// `/Library/Application Support/Adobe` on a phone.
    public static func isAvailable(_ path: RawDecodePath) -> Bool {
        switch path {
        case .bradfordAdaptation, .forwardMatrix:
            return true
        case .cirawFilter:
            if #available(iOS 15, macOS 12, *) { return true }
            return false
        case .dcpProfile:
            return DCPProfileLocator.isInstalled
        }
    }

    /// Why a path is unavailable, for a picker that wants to say more than
    /// "unavailable".
    public static func unavailabilityNote(for path: RawDecodePath) -> String? {
        guard !isAvailable(path) else { return nil }
        switch path {
        case .dcpProfile:
            return "Adobe camera profiles are not installed. They ship with Lightroom or Camera Raw."
        case .cirawFilter:
            return "Needs iOS 15 or macOS 12."
        case .bradfordAdaptation, .forwardMatrix:
            return nil
        }
    }

    /// The paths a picker should offer as selectable.
    public static var available: [RawDecodePath] {
        RawDecodePath.allCases.filter(isAvailable)
    }
}
