import SwiftUI

/// Reveals a delete action on a leading drag, for rows and cards living in
/// custom layouts — the system swipe actions exist only inside `List`.
///
/// The red strip occupies exactly the revealed width, so rows with transparent
/// backgrounds never show it through their gaps mid-swipe. A `cornerRadius`
/// marks the content as a standalone card: the strip's trailing corners take
/// the card's radius and the composite stays unclipped so the card keeps its
/// shadow; 0 keeps the row-in-a-card look, clipped to its own bounds.
struct SwipeToDeleteModifier: ViewModifier {
    var cornerRadius: CGFloat = 0
    /// Claims the drag ahead of the content's own gestures. Rows whose whole
    /// surface is a Button need that; content carrying its own drag gesture —
    /// the collection timeline's reorder handle — passes `false` so a drag
    /// starting on the handle still reorders.
    var claimsDrag = true
    var onDelete: () -> Void

    @State private var offset: CGFloat = 0

    private let actionWidth: CGFloat = 72

    func body(content: Content) -> some View {
        let composite = content
            .offset(x: offset)
            .background(alignment: .trailing) {
                if offset < 0 {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                            offset = 0
                        }
                        onDelete()
                    } label: {
                        Image(systemName: "trash.fill")
                            .foregroundStyle(.white)
                            .frame(width: -offset)
                            .frame(maxHeight: .infinity)
                            .background(Color.red)
                    }
                    .buttonStyle(.plain)
                    .clipShape(UnevenRoundedRectangle(
                        bottomTrailingRadius: cornerRadius,
                        topTrailingRadius: cornerRadius,
                        style: .continuous))
                    .accessibilityLabel("Delete")
                }
            }
        Group {
            if cornerRadius == 0 {
                if claimsDrag {
                    composite.clipped().highPriorityGesture(drag)
                } else {
                    composite.clipped().gesture(drag)
                }
            } else {
                if claimsDrag {
                    composite.highPriorityGesture(drag)
                } else {
                    composite.gesture(drag)
                }
            }
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 24, coordinateSpace: .local)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                offset = min(0, max(-actionWidth, value.translation.width + (offset < -actionWidth / 2 ? -actionWidth : 0)))
            }
            .onEnded { value in
                withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                    offset = value.translation.width < -actionWidth / 2 ? -actionWidth : 0
                }
            }
    }
}

extension View {
    /// Swipe-left-to-delete for rows and cards outside a `List`.
    func swipeToDelete(
        cornerRadius: CGFloat = 0,
        claimsDrag: Bool = true,
        onDelete: @escaping () -> Void
    ) -> some View {
        modifier(SwipeToDeleteModifier(
            cornerRadius: cornerRadius, claimsDrag: claimsDrag, onDelete: onDelete))
    }
}
