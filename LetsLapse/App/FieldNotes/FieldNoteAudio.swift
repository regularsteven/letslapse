import Foundation
import AVFoundation
import Speech

// MARK: - Recorder

/// Tap-to-record / tap-to-stop microphone capture for a field note. AAC in
/// `.m4a` (the note may be a spoken memo or ambient soundtrack material —
/// both keep). Records to a temp file the save path moves into the project.
final class FieldNoteRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    enum Phase: Equatable {
        case idle
        case denied
        case recording
        /// Recording landed; the file is ready to be saved or discarded.
        case finished(url: URL, duration: TimeInterval)
    }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var elapsed: TimeInterval = 0
    /// 0…1 meter for the level readout.
    @Published private(set) var level: Double = 0

    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?

    func toggle() {
        switch phase {
        case .recording: stop()
        default: start()
        }
    }

    private func start() {
        if case .finished(let url, _) = phase {
            // Re-recording replaces the unsaved take.
            try? FileManager.default.removeItem(at: url)
        }
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                guard granted else {
                    self.phase = .denied
                    return
                }
                self.beginRecording()
            }
        }
    }

    private func beginRecording() {
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
        } catch {
            LLog("fieldnote: audio session failed — \(error.localizedDescription)")
            phase = .idle
            return
        }
        #endif
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fieldnote-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                restoreAudioSession()
                phase = .idle
                return
            }
            self.recorder = recorder
            phase = .recording
            elapsed = 0
            level = 0
            meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                guard let self, let recorder = self.recorder else { return }
                recorder.updateMeters()
                self.elapsed = recorder.currentTime
                // −50 dB…0 dB mapped to 0…1: quiet rooms sit near zero,
                // speech moves the bar.
                let power = Double(recorder.averagePower(forChannel: 0))
                self.level = max(0, min(1, (power + 50) / 50))
            }
        } catch {
            LLog("fieldnote: recorder init failed — \(error.localizedDescription)")
            restoreAudioSession()
            phase = .idle
        }
    }

    func stop() {
        recorder?.stop()
    }

    /// Cancel path: drop the take and any temp file.
    func discard() {
        meterTimer?.invalidate()
        meterTimer = nil
        if let recorder {
            recorder.stop()
            try? FileManager.default.removeItem(at: recorder.url)
        } else if case .finished(let url, _) = phase {
            try? FileManager.default.removeItem(at: url)
        }
        recorder = nil
        restoreAudioSession()
        phase = .idle
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.meterTimer?.invalidate()
            self.meterTimer = nil
            let duration = self.elapsed
            self.recorder = nil
            self.restoreAudioSession()
            if flag, duration > 0.2 {
                self.phase = .finished(url: recorder.url, duration: duration)
            } else {
                try? FileManager.default.removeItem(at: recorder.url)
                self.phase = .idle
            }
            self.level = 0
        }
    }

    private func restoreAudioSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        // Back to the app's normal playback posture (silent-switch-respecting,
        // mixes with other audio).
        PlaybackAudioSession.configureAmbient()
        #endif
    }
}

// MARK: - Speech review

/// The automatic, transparent post-recording check: is there speech in this
/// audio, and if so what does it say? On-device only, by spec — recognition
/// that would leave the device is skipped, and every failure path is
/// non-fatal (the audio note stands on its own).
///
/// `SFSpeechRecognizer` with `requiresOnDeviceRecognition` is the workhorse
/// (floors are iOS 17 / macOS 14). iOS 26's `SpeechAnalyzer` can slot in
/// behind an availability gate later; it brings its own model-download
/// management, which "transparent" argues against until it's designed.
enum FieldNoteSpeechReview {

    /// The transcript, when the recording contains enough spoken words to be
    /// worth offering as a note; nil for ambient audio, unavailable
    /// recognizers, denied permission, or any recognition failure.
    static func transcript(of url: URL) async -> String? {
        guard await authorized() else { return nil }
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(),
              recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else { return nil }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        let text: String? = await withCheckedContinuation { continuation in
            var finished = false
            recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    guard !finished else { return }
                    finished = true
                    continuation.resume(returning: result.bestTranscription.formattedString)
                } else if error != nil {
                    guard !finished else { return }
                    finished = true
                    continuation.resume(returning: nil)
                }
            }
        }
        guard let text, isSubstantialSpeech(text) else { return nil }
        return text
    }

    /// A couple of recognized syllables in ambient noise is not a memo —
    /// only offer a note for something worth reading back.
    static func isSubstantialSpeech(_ text: String) -> Bool {
        text.split(whereSeparator: \.isWhitespace).count >= 3
    }

    private static func authorized() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .denied, .restricted: return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        @unknown default: return false
        }
    }
}

// MARK: - Playback

/// Inline playback for audio notes in the project's notes list. One player,
/// one note at a time; tapping another note's play switches to it.
final class FieldNotePlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playingNoteID: UUID?
    private var player: AVAudioPlayer?

    func toggle(note: FieldNote, url: URL) {
        if playingNoteID == note.id {
            stop()
            return
        }
        stop()
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            guard player.play() else { return }
            self.player = player
            playingNoteID = note.id
        } catch {
            LLog("fieldnote: playback failed — \(error.localizedDescription)")
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playingNoteID = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.player = nil
            self.playingNoteID = nil
        }
    }
}
