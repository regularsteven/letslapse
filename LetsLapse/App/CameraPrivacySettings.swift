import AVFoundation
import Foundation
#if os(macOS)
import AppKit
#endif

enum CameraPrivacySettings {
    static var authorizationStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    static var statusLabel: String {
        switch authorizationStatus {
        case .authorized:
            return "Camera access is enabled."
        case .notDetermined:
            return "Camera access has not been requested yet."
        case .denied:
            return "Camera access is denied."
        case .restricted:
            return "Camera access is restricted by system policy."
        @unknown default:
            return "Camera access status is unknown."
        }
    }

    static func requestAccess(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                completion(granted)
            }
        }
    }

    #if os(macOS)
    static func open() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera",
            "x-apple.systempreferences:com.apple.preference.security"
        ]
        for value in urls {
            guard let url = URL(string: value), NSWorkspace.shared.open(url) else { continue }
            return
        }
    }
    #endif
}
