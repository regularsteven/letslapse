import SwiftUI

/// The Gallery tab: a square, filterable thumbnail grid over every capture.
/// Each tile shows the project's "hero" asset — for Photo/Interval captures the
/// latest blended image, otherwise the source frame or video. Tapping a tile
/// pushes the same `ProjectDetailView` the Projects tab uses.
///
/// The filter bar and the grid itself are shared components (`CaptureFilterBar`,
/// `CaptureAssetGrid`); this view only supplies the data source.
struct GalleryView: View {
    @EnvironmentObject var model: AppModel
    @Binding var path: [UUID]
    @State private var filter: CaptureFilter = .all

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                // Manual title, matching the Projects tab (which hides the
                // native navigation bar and draws its own). A native large
                // title would sit under a full navigation-bar height of
                // padding, leaving the two tabs visibly inconsistent.
                Text("Gallery")
                    .font(.system(size: 34, weight: .bold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 20)
                    .padding(.trailing, 16)
                    .padding(.top, 15)

                CaptureFilterBar(selection: $filter)
                    .padding(.horizontal)

                CaptureAssetGrid(
                    items: model.captures.filtered(by: filter),
                    asset: { model.heroAsset(for: $0) },
                    onTap: { path.append($0.id) }
                )
            }
            .background(LL.screenBackground)
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #else
            .navigationTitle("Gallery")
            #endif
            .navigationDestination(for: UUID.self) { captureID in
                ProjectDetailView(captureID: captureID)
            }
        }
    }
}
