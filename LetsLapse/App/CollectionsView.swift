import SwiftUI

/// Collections tab — placeholder while the real UX is designed.
///
/// A collection will gather blended clips from across projects into an
/// arrangeable timeline (with in/out points) that exports as a single video.
/// Until that design lands, this screen just states the intent so the tab
/// isn't a dead end. It took the parked Music spike's tab slot; `MusicView`
/// and its engine stay in the codebase, unrouted.
struct CollectionsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                header

                comingSoonCard

                Spacer(minLength: 96)
            }
            .padding(.horizontal, 16)
        }
        .background(LL.screenBackground)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Collections")
                .font(.system(size: 34, weight: .bold))
            Text("Coming soon")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LL.amber)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4).padding(.top, 8).padding(.bottom, 6)
    }

    private var comingSoonCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "film.stack")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No collections yet")
                .font(.headline)
            Text("A collection strings blended clips from your projects into one timeline, and exports as a single video.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
        .padding(20)
        .llCard(cornerRadius: 18)
    }
}
