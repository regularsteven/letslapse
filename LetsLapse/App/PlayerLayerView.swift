#if os(iOS)
import AVFoundation
import SwiftUI
import UIKit

/// A movie surface with nothing on it: an `AVPlayerLayer` in a plain view.
///
/// The touch video editor used AVKit's `VideoPlayer` for its picture, which
/// brought a transport bar and a tap that toggles it — and, on 2026-09-21,
/// stood between the picture and the gestures the editor now owns: a tap for
/// clear preview and a swipe across the picture to the neighbouring project.
/// The editor's own strip plays, pauses and scrubs, so the picture can be a
/// bare layer and every touch on it the editor's. The Mac keeps `VideoPlayer`.
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    /// Fires with the layer's `isReadyForDisplay` — true once a frame is on
    /// screen, which is when a poster laid over the surface can go.
    var onReadyForDisplay: ((Bool) -> Void)? = nil

    func makeUIView(context: Context) -> PlayerLayerUIView {
        let view = PlayerLayerUIView()
        view.playerLayer.player = player
        view.onReady = onReadyForDisplay
        return view
    }

    func updateUIView(_ view: PlayerLayerUIView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
        view.onReady = onReadyForDisplay
    }
}

final class PlayerLayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    var onReady: ((Bool) -> Void)?
    private var readiness: NSKeyValueObservation?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isUserInteractionEnabled = false
        playerLayer.videoGravity = .resizeAspect
        readiness = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
            let ready = layer.isReadyForDisplay
            DispatchQueue.main.async { self?.onReady?(ready) }
        }
    }

    required init?(coder: NSCoder) { nil }
}
#endif
