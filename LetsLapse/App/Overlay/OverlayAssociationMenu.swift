import SwiftUI

/// The association menu — "what does this line wait for?" — put where the
/// story is rather than only in the rail.
///
/// The rail's "Starts: At time · After layer" picker is still the authoring
/// instrument, and this offers exactly the same choice: the layers this one
/// may follow (its own descendants excluded, since a parent cannot follow
/// its child), a tick on the current parent, and — once linked — whether the
/// layer travels with that parent across the picture or holds its own spot.
///
/// It is a NATIVE menu on purpose. `.contextMenu` already means right-click
/// or ⌃-click on the Mac and touch-and-hold on iOS, which is exactly the
/// three gestures the design asks for, and a hand-drawn popover would have
/// to re-earn all three.
struct OverlayAssociationMenu: View {
    @Binding var document: OverlayDocument
    let layerID: UUID
    /// Persist and re-render. Called after every change here, all of which
    /// are finished gestures.
    let onEdited: () -> Void
    let onToast: (String) -> Void

    var body: some View {
        if let layer = document.overlays.first(where: { $0.id == layerID }) {
            let follow = layer.animation?.follows
            let forbidden = document.descendants(of: layerID)
            let candidates = document.overlays.filter {
                $0.id != layerID && !forbidden.contains($0.id)
            }
            // The design draws the layer's name as a title above a section
            // label; a native menu has one header, so it carries both.
            Section("\(layer.displayName) · \(follow == nil ? "start after…" : "starts after")") {
                ForEach(candidates) { candidate in
                    Button {
                        // Picking the current parent again unlinks — which
                        // is what the tick beside it invites.
                        let toast = document.link(
                            layerID, to: follow?.layerID == candidate.id ? nil : candidate.id)
                        onEdited()
                        onToast(toast)
                    } label: {
                        if follow?.layerID == candidate.id {
                            Label(candidate.displayName, systemImage: "checkmark")
                        } else {
                            Text(candidate.displayName)
                        }
                    }
                }
            }
            if follow != nil {
                Section {
                    Button {
                        if let toast = document.toggleIndependentPosition(of: layerID) {
                            onEdited()
                            onToast(toast)
                        }
                    } label: {
                        if follow?.independentPosition == true {
                            Label("Independent Position", systemImage: "checkmark")
                        } else {
                            Text("Independent Position")
                        }
                    }
                    Button(role: .destructive) {
                        let toast = document.link(layerID, to: nil)
                        onEdited()
                        onToast(toast)
                    } label: {
                        Label("Remove association", systemImage: "xmark.circle")
                    }
                }
            }
        }
    }
}
