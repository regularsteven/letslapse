import Foundation

/// Makes a pulled project's two tag lists agree (2026-11-05).
///
/// A project's tags live twice on a device. `capture.sceneTags` in the
/// manifest is the list the sidebar, search and the index read. The project
/// record (`metadata.json`) holds the same list as `edited.keywords`, which
/// the Gallery's Tags block, the batch panel and an export's `dc:subject`
/// read first. A hand edit here writes both (`AppModel.setSceneTags`).
///
/// A pull takes them from two places: the manifest from the server's row,
/// the project record from the records bundle. They disagree whenever the
/// manifest reached the server without its bundle — a client that edits the
/// manifest alone (Readia's LetsLapse page is one: it cannot write an Apple
/// Archive), or a device whose push stopped between its PUT and its bundle.
/// Until now the panels then showed the old list, and the next add or
/// remove there wrote that old list back over the edit.
///
/// The manifest is never the older of the two on a server: a bundle only
/// goes up inside a push that PUT its manifest first. So after a pull the
/// manifest's list is the project's, and the record follows it.
public enum PulledKeywords {

    /// The list the project record's edited keywords should be settled to
    /// after a pull, or nil when there is nothing to settle. The caller
    /// hands a non-nil answer to the one writer of that layer, which clears
    /// it when the list is empty or is what the files said.
    ///
    /// - Parameters:
    ///   - pulledTags: `capture.sceneTags` as it arrived.
    ///   - taggedAutomatically: the silent pass chose them. Those were never
    ///     keywords on the device that made them, so they are not made
    ///     keywords here.
    ///   - edited: the record's `edited.keywords`, as the bundle left it.
    ///   - imported: the keywords the project's files carried.
    ///   - clean: the app's own normaliser for a tag list.
    public static func settled(pulledTags: [String]?, taggedAutomatically: Bool,
                               edited: [String]?, imported: [String]?,
                               clean: ([String]) -> [String]) -> [String]? {
        guard !taggedAutomatically else { return nil }
        let tags = clean(pulledTags ?? [])
        if let edited {
            return clean(edited) == tags ? nil : tags
        }
        // No edited layer: the panels show what the files said, or the
        // manifest's own list when they said nothing — which already agrees.
        // "No tags" cannot be said over a file's own keywords, here or by a
        // hand edit, so an empty list is left alone.
        guard let imported, !tags.isEmpty else { return nil }
        return clean(imported) == tags ? nil : tags
    }
}
