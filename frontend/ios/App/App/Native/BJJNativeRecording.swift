import Foundation
import AVFoundation
import UIKit

/// Capture has one owner, fenced permission callbacks, and a durable take receipt.
@MainActor final class BJJNativeRecording: NSObject, AVAudioRecorderDelegate {
    private var lifecycle = BJJRecordingLifecycle()
    private var recorder: AVAudioRecorder?
    private var url: URL?
    private var start = 0.0
    private var project: BJJProject?
    private var store: BJJStore?
    private weak var player: AVPlayer?
    private var observations: [NSObjectProtocol] = []
    var finished: ((BJJJSON?, Error?, String?) -> Void)?
    var active: Bool { lifecycle.phase != .idle }
    var elapsed: Double { recorder?.currentTime ?? 0 }
    var level: Float { recorder?.updateMeters(); return recorder?.averagePower(forChannel: 0) ?? -160 }
    var route: String {
        let session = AVAudioSession.sharedInstance()
        return (session.currentRoute.inputs + session.currentRoute.outputs).map(\.portName).joined(separator: " → ")
    }
    override init() {
        super.init()
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification, UIApplication.didEnterBackgroundNotification] {
            observations.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                if note.name == AVAudioSession.interruptionNotification,
                   note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt != AVAudioSession.InterruptionType.began.rawValue { return }
                Task { @MainActor in
                    guard let self, self.recorder != nil else { return }
                    self.stop(reason: "Recording stopped because the audio route or app state changed. Review the saved take before continuing.")
                }
            })
        }
    }
    deinit { observations.forEach(NotificationCenter.default.removeObserver) }
    func begin(project: BJJProject, store: BJJStore, player: AVPlayer) async throws {
        let token = UUID().uuidString
        try lifecycle.begin(token)
        self.project = project; self.store = store; self.player = player
        do {
            guard project.voiceovers.count < 200 else { throw BJJError.invalid("This review already has 200 takes.") }
            let permission = await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
            }
            guard lifecycle.sessionID == token else { throw BJJError.cancelled }
            guard permission else { throw BJJError.invalid("Allow microphone access in Settings to record narration.") }
            try store.checkSpace(required: Int64(project.duration * 96000) + 100_000_000)
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try audio.setPreferredSampleRate(48000)
            try audio.setActive(true)
            try lifecycle.advance(token, from: .preparing, to: .prepared)
            let path = try store.safeURL(project.id, "voiceover/\(UUID().uuidString.lowercased()).wav")
            url = path
            let capture = try AVAudioRecorder(url: path, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
            guard capture.prepareToRecord() else { throw BJJError.invalid("The microphone could not prepare a take.") }
            // Start capture only after the media clock actually advances, not at the button press.
            let position = player.currentTime().seconds
            guard position.isFinite, position < project.duration - 0.2 else { throw BJJError.invalid("Move before the end of the video to record.") }
            player.playImmediately(atRate: 1)
            for _ in 0..<200 {
                guard lifecycle.sessionID == token else { throw BJJError.cancelled }
                if player.timeControlStatus == .playing, player.currentTime().seconds > position { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            guard player.timeControlStatus == .playing, player.currentTime().seconds > position else {
                throw BJJError.invalid("Video playback did not start. Try recording again.")
            }
            guard capture.record(forDuration: max(0.05, project.duration - player.currentTime().seconds)) else { throw BJJError.invalid("The microphone could not start.") }
            start = max(0, player.currentTime().seconds - capture.currentTime)
            capture.isMeteringEnabled = true; capture.delegate = self; recorder = capture
            try lifecycle.advance(token, from: .prepared, to: .recording)
        } catch {
            if lifecycle.sessionID == token { reset(); if let url { try? FileManager.default.removeItem(at: url) }; url = nil }
            throw error
        }
    }
    func checkClock() {
        guard lifecycle.phase == .recording, let player, let recorder else { return }
        if abs(player.currentTime().seconds - start - recorder.currentTime) > 0.2 {
            stop(reason: "Video playback stalled. The take was stopped to protect its timing.")
        }
    }
    func stop(reason: String? = nil) {
        guard active else { return }
        let capture = recorder, path = url, document = project, storage = store
        let startSec = start
        capture?.delegate = nil; capture?.stop(); player?.pause()
        reset(); url = nil
        guard let capture, let path, let document, let storage else { finished?(nil, nil, reason); return }
        do {
            let audio = try AVAudioFile(forReading: path)
            let duration = min(Double(audio.length) / audio.fileFormat.sampleRate, document.duration - startSec)
            guard duration >= 0.05 else { try? FileManager.default.removeItem(at: path); finished?(nil, nil, "The take was too short to save."); return }
            let id = path.deletingPathExtension().lastPathComponent
            let clip: BJJJSON = ["id": id, "asset": "voiceover/\(id).wav", "startSec": startSec,
                "durationSec": duration, "endSec": startSec + duration, "gain": 1.0, "muted": false,
                "timingOffsetMs": 0.0, "recordedAt": BJJProject.now(), "codec": "pcm_s16le",
                "sampleRate": Int(audio.fileFormat.sampleRate), "channels": Int(audio.fileFormat.channelCount)]
            try storage.registerClip(document.id, clip: clip)
            finished?(clip, nil, reason)
            _ = capture // retain until the file has closed and its metadata was read
        } catch { finished?(nil, error, "The take could not be committed. Its audio file was preserved.") }
    }
    private func reset() {
        recorder?.delegate = nil; recorder?.stop(); recorder = nil; player?.pause()
        lifecycle.reset()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
    }
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in if self.recorder === recorder { self.stop(reason: flag ? nil : "Recording ended unexpectedly. Review the saved take.") } }
    }
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in if self.recorder === recorder { self.stop(reason: error?.localizedDescription ?? "The microphone stopped.") } }
    }
}
