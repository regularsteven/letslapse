import SwiftUI

// MARK: - Gallery sidebar

/// The left sidebar panel of the Gallery tab.
///
/// Three sections:
/// - **Library**: capture-kind filter rows (All / Photos / Interval / Video)
/// - **Tags**: scene tags present in the visible library
/// - **Collections**: link to Collections tab (navigates via model)
struct GallerySidebar: View {
    @EnvironmentObject var model: AppModel
    @Binding var filter: CaptureFilter
    @Binding var tagSelection: Set<String>
    /// The captures already filtered by type — used to derive which tags appear.
    var allCaptures: [AppModel.CaptureProject]

    private var presentTags: [String] {
        allCaptures.presentSceneTags
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                librarySection
                if !presentTags.isEmpty {
                    Divider().padding(.horizontal, 12)
                    tagsSection
                }
                Divider().padding(.horizontal, 12)
                collectionsSection
            }
            .padding(.top, 14)
            .padding(.bottom, 20)
        }
        .scrollContentBackground(.hidden)
        .background(LL.screenBackground)
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
}

// MARK: - Library filter row

private struct LibraryFilterRow: View {
    var label: String
    var icon: String
    var isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isSelected ? LL.accent : .secondary)
                .frame(width: 20, alignment: .center)

            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(isSelected ? LL.accent : .primary)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(isSelected ? LL.accent.opacity(0.1) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
    }
}
