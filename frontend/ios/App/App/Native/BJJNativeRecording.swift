import Foundation
import AVFoundation
import UIKit

/// Capture has one owner, fenced permission callbacks, and a durable take receipt.
@MainActor final class BJJNativeRecording: NSObject, AVAudioRecorderDelegate {
    private var lifecycle = BJJRecordingLifecycle()
    private var recorder: AVAudioRecorder?
    private var url: URL?
    private var start = 0.0
    private var newHolds: [BJJJSON] = []
    private var pauseStart: Double?
    private var pauseBoundary = 0.0
    private var frozenPTS = 0.0
    private var pausedDuration = 0.0
    private var clockTimer: Timer?
    private var pausePreparing = false
    private var lastSpaceCheck = -5.0
    var videoPaused: Bool { pauseStart != nil || pausePreparing }
    var liveElapsed: Double { recorder?.currentTime ?? 0 }
    func toggleVideoPause() async throws {
        guard lifecycle.phase == .recording, let player, let recorder, let project, let store, !pausePreparing else { return }
        if let began = pauseStart {
            let ticks = ((recorder.currentTime - began) * 48000).rounded()
            if ticks > 0 {
                newHolds.append(["id": UUID().uuidString.lowercased(), "sourceTicks": (pauseBoundary * 48000).rounded(), "durationTicks": ticks, "frozenPTS": frozenPTS])
                pausedDuration += ticks / 48000
            }
            pauseStart = nil; player.playImmediately(atRate: 1); return
        }
        guard project.reviewTimeline.holds.count + newHolds.count < 2000 else { throw BJJError.invalid("This review already has 2,000 narration pauses.") }
        let output = player.currentTime().seconds
        guard project.reviewTimeline.span(at: output)?.hold == nil else { throw BJJError.invalid("Video is already paused. Keep narrating or let playback resume.") }
        player.pause(); pauseStart = recorder.currentTime
        pauseBoundary = project.reviewTimeline.source(at: output)
        frozenPTS = pauseBoundary
        pausePreparing = true
        let token = lifecycle.sessionID
        defer { pausePreparing = false }
        do {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: try store.asset(project.id, project.source.s("asset"))))
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            let frame = try await generator.image(at: CMTime(seconds: pauseBoundary + ((project.source["videoStartSec"] as? NSNumber)?.doubleValue ?? 0), preferredTimescale: 48000))
            guard lifecycle.sessionID == token, recorder === self.recorder else { return }
            frozenPTS = max(0, frame.actualTime.seconds - ((project.source["videoStartSec"] as? NSNumber)?.doubleValue ?? 0))
        } catch {
            guard lifecycle.sessionID == token else { return }
            stop(reason: "The paused frame could not be inspected. The take and its pause were preserved for review.")
            throw error
        }
    }
    private var project: BJJProject?
    private var store: BJJStore?
    private weak var player: AVPlayer?
    private var observations: [NSObjectProtocol] = []
    var meterChanged: ((Float) -> Void)?
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
            guard project.allTakes.count < 200 else { throw BJJError.invalid("This review already has 200 takes.") }
            let permission = await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
            }
            guard lifecycle.sessionID == token else { throw BJJError.cancelled }
            guard permission else { throw BJJError.invalid("Allow microphone access in Settings to record narration.") }
            try store.checkSpace(required: Int64(min(86400, project.outputDuration + 3600) * 96000) + 100_000_000)
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
            guard position.isFinite, position < project.outputDuration - 0.2 else { throw BJJError.invalid("Move before the end of the video to record.") }
            player.playImmediately(atRate: 1)
            for _ in 0..<200 {
                guard lifecycle.sessionID == token else { throw BJJError.cancelled }
                if player.timeControlStatus == .playing, player.currentTime().seconds > position { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            guard player.timeControlStatus == .playing, player.currentTime().seconds > position else {
                throw BJJError.invalid("Video playback did not start. Try recording again.")
            }
            guard capture.record() else { throw BJJError.invalid("The microphone could not start.") }
            start = max(0, player.currentTime().seconds - capture.currentTime)
            capture.isMeteringEnabled = true; capture.delegate = self; recorder = capture
            try lifecycle.advance(token, from: .prepared, to: .recording)
            newHolds = []; pausedDuration = 0; pauseStart = nil; lastSpaceCheck = -5
            clockTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.checkClock() }
            }
        } catch {
            if lifecycle.sessionID == token { reset(); if let url { try? FileManager.default.removeItem(at: url) }; url = nil }
            throw error
        }
    }
    func checkClock() {
        guard lifecycle.phase == .recording, let player, let recorder else { return }
        meterChanged?(level)
        if recorder.currentTime >= 3600 || project!.outputDuration + pausedDuration + (pauseStart.map { recorder.currentTime - $0 } ?? 0) >= 86400 {
            stop(reason: "The take reached its one-hour recording limit."); return
        }
        if recorder.currentTime - lastSpaceCheck >= 5, let store {
            lastSpaceCheck = recorder.currentTime
            do { try store.checkSpace(required: 100_000_000) }
            catch { stop(reason: "Recording stopped because storage is low. The valid take was preserved."); return }
        }
        guard pauseStart == nil, !pausePreparing else { return }
        if abs(player.currentTime().seconds - start + pausedDuration - recorder.currentTime) > 0.2 {
            stop(reason: "Video playback stalled. The take was stopped to protect its timing.")
        }
    }
    func stop(reason: String? = nil) {
        guard active else { return }
        let capture = recorder, path = url, document = project, storage = store
        let startSec = start
        if let began = pauseStart, let capture {
            let ticks = ((capture.currentTime - began) * 48000).rounded()
            if ticks > 0 { newHolds.append(["id": UUID().uuidString.lowercased(), "sourceTicks": (pauseBoundary * 48000).rounded(), "durationTicks": ticks, "frozenPTS": frozenPTS]) }
        }
        let holds = newHolds
        capture?.delegate = nil; capture?.stop(); player?.pause()
        reset(); url = nil
        guard let capture, let path, let document, let storage else { finished?(nil, nil, reason); return }
        do {
            var audio = try AVAudioFile(forReading: path)
            if holds.isEmpty && !document.pauseAware {
                let maximum = Int64((max(0, document.duration - startSec) * audio.fileFormat.sampleRate).rounded(.down))
                if audio.length > maximum {
                    try Self.trimUnregisteredTake(path, frames: maximum)
                    audio = try AVAudioFile(forReading: path)
                }
            }
            let duration = Double(audio.length) / audio.fileFormat.sampleRate
            guard duration >= 0.05 else { try? FileManager.default.removeItem(at: path); finished?(nil, nil, "The take was too short to save."); return }
            let id = path.deletingPathExtension().lastPathComponent
            if holds.isEmpty && !document.pauseAware {
                let length = min(duration, document.duration - startSec)
                let clip: BJJJSON = ["id": id, "asset": "voiceover/\(id).wav", "startSec": startSec,
                    "durationSec": length, "endSec": startSec + length, "gain": 1.0, "muted": false,
                    "timingOffsetMs": 0.0, "recordedAt": BJJProject.now(), "codec": "pcm_s16le",
                    "sampleRate": Int(audio.fileFormat.sampleRate), "channels": Int(audio.fileFormat.channelCount)]
                try storage.registerClip(document.id, clip: clip); finished?(clip, nil, reason)
            } else {
                let ordered = (document.reviewTimeline.holds + holds).enumerated().sorted {
                    $0.element.n("sourceTicks") == $1.element.n("sourceTicks") ? $0.offset < $1.offset : $0.element.n("sourceTicks") < $1.element.n("sourceTicks")
                }.map { $0.element }
                let timeline = BJJReviewTimeline(sourceDuration: document.duration, holds: ordered)
                let take: BJJJSON = ["id": id, "asset": "voiceover/\(id).wav", "durationSec": duration,
                    "sampleCount": audio.length, "gain": 1.0, "muted": false, "recordedAt": BJJProject.now(),
                    "codec": "pcm_s16le", "sampleRate": 48000, "channels": 1,
                    "placements": timeline.placements(start: startSec, duration: min(duration, timeline.duration - startSec))]
                let receipt: BJJJSON = ["kind": "review-narration-v1", "operationId": UUID().uuidString.lowercased(),
                    "baseRevision": document.revision, "baseProject": document.json, "take": take, "holds": holds]
                try storage.registerReviewReceipt(document.id, receipt: receipt)
                finished?(receipt, nil, reason)
            }
            _ = capture // retain until the file has closed and its metadata was read
        } catch { finished?(nil, error, "The take could not be committed. Its audio file was preserved.") }
    }
    /// A delayed source-end callback may capture a few extra microphone samples.
    /// Trim only an ordinary, unregistered take; pause-aware takes retain every
    /// sample. Registry duration must match the actual WAV for portable backups.
    static func trimUnregisteredTake(_ path: URL, frames: Int64) throws {
        let temporary = path.deletingLastPathComponent().appendingPathComponent("trim-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try autoreleasepool {
            let source = try AVAudioFile(forReading: path)
            guard frames > 0, frames <= source.length else { throw BJJError.invalid("The take has no valid source-time audio.") }
            let destination = try AVAudioFile(forWriting: temporary, settings: source.fileFormat.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 65536)!
            var remaining = frames
            while remaining > 0 {
                try source.read(into: buffer, frameCount: AVAudioFrameCount(min(remaining, 65536)))
                guard buffer.frameLength > 0 else { throw BJJError.invalid("The captured audio ended unexpectedly.") }
                try destination.write(from: buffer); remaining -= Int64(buffer.frameLength)
            }
        }
        _ = try FileManager.default.replaceItemAt(path, withItemAt: temporary)
    }
    private func reset() {
        clockTimer?.invalidate(); clockTimer = nil; pauseStart = nil; pausePreparing = false
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
