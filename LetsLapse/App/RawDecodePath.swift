import Foundation
import LetsLapseKit
import SwiftUI

/// App-side binding for the raw-decode toggle.
///
/// The `RawDecodePath` enum itself lives in `LetsLapseKit`
/// (`Grading/RawDecodePath.swift`), not here, because `ToneMath` and
/// `LinearFrameDecoder` branch on it and the Kit cannot import the app target.
/// This file is the app's half: the `@AppStorage` key the settings picker
/// binds to, and the glue that keeps that key and `RawDecodePath.current`
/// pointing at the same `UserDefaults` entry.
enum RawDecodeSettings {
    /// The `UserDefaults` key, shared with `RawDecodePath.current` and with
    /// the `lapse` CLI's `--decode-path`.
    static let storageKey = RawDecodePath.defaultsKey

    /// The current selection, resolved through the registry so an unavailable
    /// stored value falls back to the default rather than failing at render
    /// time.
    static var current: RawDecodePath {
        get { RawDecodePath.current }
        set { RawDecodePath.current = newValue }
    }

    /// Every case, in declaration order, so the picker can show the
    /// unavailable ones greyed rather than hiding them — a comparison feature
    /// that silently omits an option reads as a bug.
    static var allPaths: [RawDecodePath] { RawDecodePath.allCases }

    /// The label for a row in the picker, marked when the path cannot run.
    ///
    /// A greyed row that only says "unavailable" invites the reader to assume
    /// the feature is unfinished. The DCP path is finished; it needs Adobe's
    /// profiles, which are somebody else's to install. Saying which of those
    /// two it is costs a few words and saves the question.
    static func label(for path: RawDecodePath) -> String {
        guard !RawDecodePathRegistry.isAvailable(path) else { return path.displayName }
        guard let note = RawDecodePathRegistry.unavailabilityNote(for: path) else {
            return "\(path.displayName) (unavailable)"
        }
        return "\(path.displayName) — \(note)"
    }
}

/// A `RawDecodePath` binding usable directly from SwiftUI.
///
/// `@AppStorage` cannot store a non-`RawRepresentable`-of-`String` type
/// without help, and `RawDecodePath` is exactly that shape — but its stored
/// value also needs the registry check on read, so this wrapper reads through
/// `RawDecodePath.current` and writes the raw string. `@AppStorage` on the
/// same key still drives the view's invalidation.
struct RawDecodePathBinding {
    static func binding(refresh: Binding<String>) -> Binding<RawDecodePath> {
        Binding(
            get: { RawDecodePath.current },
            set: { newValue in
                RawDecodePath.current = newValue
                // Writing the @AppStorage-backed string is what tells SwiftUI
                // to re-render; setting `current` alone would change the
                // defaults without invalidating any view reading it.
                refresh.wrappedValue = newValue.rawValue
            })
    }
}
