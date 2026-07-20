import Foundation

#if os(iOS)
import AVFoundation
#endif

enum PlaybackAudioSession {
    static func configureAmbient() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(
            .ambient,
            mode: .default,
            options: [.mixWithOthers]
        )
        #endif
    }
}
