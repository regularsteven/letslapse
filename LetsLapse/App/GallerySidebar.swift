import SwiftUI

// MARK: - Gallery sidebar

/// The left sidebar panel of the Gallery tab.
///
/// Four sections:
/// - **Library**: capture-kind filter rows (All / Photos / Interval / Video)
/// - **Tags**: scene tags present in the visible library
/// - **Collections**: link to Collections tab (navigates via model)
/// - **Shapes**: Ellipse / Rectangle / Square / No Shapes, from each project's
///   `shapes.json` register (Find shapes, or drawn in the Masks tab)
///
/// With the library connected to PicPlace, a **PicPlace** section under
/// Library (2026-09-25, the brief's "Gallery library filters" — plan §1b,
/// §14): All · On this device · Download available · Not available to
/// download · Needs uploading · Has blends · Syncing / Needs attention, each
/// with its count. None of it on a device that is not connected.
///
/// And on the phone, where it is a sheet, a fifth on top — **View**, the
/// Timeline switch: the portrait header gave the Timeline glyph's seat to
/// the sync pill (2026-09-15), and the mode is remembered, so this is where
/// a phone turns it on and off. The wide layouts pass nothing and keep
/// their header button.
struct GallerySidebar: View {
    @EnvironmentObject var model: AppModel
    @Binding var filter: CaptureFilter
    @Binding var tagSelection: Set<String>
    @Binding var shapeSelection: Set<ShapeFilter>
    /// The tags present among the projects the grid's question matches —
    /// the index's answer (M3), in the taxonomy's order, custom after.
    var presentTags: [String]
    /// The Timeline switch, when this sidebar is the only place it lives.
    var timelineMode: Binding<Bool>? = nil
    /// The PicPlace section's selection — nil in a library not connected to
    /// PicPlace, which shows no section at all.
    var picplaceFilter: Binding<PicPlaceFilter>? = nil
    var picplaceCounts: [PicPlaceFilter: Int] = [:]
    /// The status sweep's progress while it runs.
    var picplaceProgress: (done: Int, total: Int)? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let timelineMode {
                    viewSection(timelineMode)
                    Divider().padding(.horizontal, 12)
                }
                librarySection
                if let picplaceFilter {
                    Divider().padding(.horizontal, 12)
                    picplaceSection(picplaceFilter)
                }
                if !presentTags.isEmpty {
                    Divider().padding(.horizontal, 12)
                    tagsSection
                }
                Divider().padding(.horizontal, 12)
                collectionsSection
                Divider().padding(.horizontal, 12)
                shapesSection
            }
            .padding(.top, 14)
            .padding(.bottom, 20)
        }
        .scrollContentBackground(.hidden)
        .background(LL.screenBackground)
    }

    // MARK: View (phone)

    private func viewSection(_ timelineMode: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LLSectionHeader("View")
                .padding(.horizontal, 14)
            Toggle(isOn: timelineMode) {
                HStack(spacing: 10) {
                    Image(systemName: "calendar")
                        .font(.system(size: 15))
                        .foregroundStyle(timelineMode.wrappedValue ? LL.accent : .secondary)
                        .frame(width: 22)
                    Text("Timeline")
                        .font(.system(size: 14))
                }
            }
            .tint(LL.accent)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            Text("Tiles grouped by shoot day, with a month rail")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
        }
    }

    // MARK: Library

    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 2) {
            LLSectionHeader("Library")
                .padding(.horizontal, 14)

            ForEach(CaptureFilter.withoutScans) { f in
                Button {
                    filter = f
                } label: {
                    LibraryFilterRow(
                        label: f.rawValue,
                        icon: iconName(for: f),
                        isSelected: filter == f
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: PicPlace

    private func picplaceSection(_ selection: Binding<PicPlaceFilter>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LLSectionHeader("PicPlace")
                .padding(.horizontal, 14)

            ForEach(PicPlaceFilter.allCases) { f in
                Button {
                    selection.wrappedValue = f
                } label: {
                    LibraryFilterRow(
                        label: f.label,
                        icon: f.systemImage,
                        isSelected: selection.wrappedValue == f,
                        count: f == .all ? nil : picplaceCounts[f]
                    )
                }
                .buttonStyle(.plain)
            }
            if let progress = picplaceProgress {
                // The first look at a library walks every project once;
                // later looks check what moved.
                Text("Checking \(progress.done.formatted()) of \(progress.total.formatted()) projects…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 18)
                    .padding(.top, 4)
            }
        }
    }

    private func iconName(for filter: CaptureFilter) -> String {
        switch filter {
        case .all:      return "square.grid.2x2"
        case .photos:   return "photo"
        case .interval: return "square.stack"
        case .video:    return "film"
        case .scans:    return "doc.viewfinder"
        }
    }

    // MARK: Tags

    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            LLSectionHeader("Tags")
                .padding(.horizontal, 14)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(presentTags, id: \.self) { tag in
                    let isOn = tagSelection.contains(tag)
                    Button {
                        if isOn { tagSelection.remove(tag) } else { tagSelection.insert(tag) }
                    } label: {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(isOn ? LL.accent : Color.primary.opacity(0.25))
                                .frame(width: 7, height: 7)
                            Text(SceneMetadata.label(for: tag))
                                .font(.system(size: 14))
                                .foregroundStyle(isOn ? LL.accent : .primary)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }

            if !tagSelection.isEmpty {
                Button {
                    tagSelection = []
                } label: {
                    Text("Clear tags")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(LL.accent)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.top, 2)
            }
        }
    }

    // MARK: Collections

    private var collectionsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            LLSectionHeader("Collections")
                .padding(.horizontal, 14)

            // Navigate to the Collections tab via the shared model flag.
            Button {
                model.requestedTab = .collections
            } label: {
                LibraryFilterRow(
                    label: "All Collections",
                    icon: "rectangle.stack",
                    isSelected: false
                )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Shapes

    /// The register rows. A project shows under Ellipse / Rectangle / Square
    /// when its `shapes.json` holds one (found by Find shapes or drawn in the
    /// Masks tab), and under No Shapes when it holds none or was never given
    /// one — so the pictures the detector missed can be browsed to and given
    /// a shape by hand. Rows narrow like the tags; No Shapes stands alone.
    /// All four are always offered: an empty row is the prompt to run Find
    /// shapes, not a dead control.
    private var shapesSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            LLSectionHeader("Shapes")
                .padding(.horizontal, 14)

            ForEach(ShapeFilter.allCases) { row in
                let isOn = shapeSelection.contains(row)
                Button {
                    shapeSelection.toggle(row)
                } label: {
                    LibraryFilterRow(
                        label: row.title,
                        icon: row.symbolName,
                        isSelected: isOn
                    )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }

            if !shapeSelection.isEmpty {
                Button {
                    shapeSelection = []
                } label: {
                    Text("Clear shapes")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(LL.accent)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.top, 4)
            }
        }
    }
}

// MARK: - Library filter row

private struct LibraryFilterRow: View {
    var label: String
    var icon: String
    var isSelected: Bool
    /// How many projects the row keeps, where the section shows numbers.
    var count: Int? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isSelected ? LL.accent : .secondary)
                .frame(width: 20, alignment: .center)

            // The PicPlace section's names are the brief's, in full: a
            // narrow sidebar wraps "Not available to download" rather than
            // cutting it (they are the pill's VoiceOver words too).
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(isSelected ? LL.accent : .primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            if let count {
                Text(count.formatted())
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(isSelected ? LL.accent.opacity(0.1) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
    }
}
