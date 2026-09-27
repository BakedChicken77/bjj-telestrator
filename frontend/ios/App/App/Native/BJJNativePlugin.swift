import Foundation
import Capacitor
import AVFoundation
import PhotosUI
import UniformTypeIdentifiers
import UIKit
import OSLog

// Value-only lifecycle: all plugin transitions run on MainActor. Tokens fence delayed
// permission continuations, bridge calls and AVAudioRecorder delegate callbacks.
struct BJJRecordingLifecycle {
    enum Phase: String { case idle, preparing, prepared, recording, stopping }
    private(set) var phase: Phase = .idle
    private(set) var sessionID: String?
    mutating func begin(_ id: String) throws {
        guard phase == .idle else { throw BJJError.invalid("A recording is already active.") }
        sessionID = id; phase = .preparing
    }
    mutating func advance(_ id: String, from: Phase, to: Phase) throws {
        guard sessionID == id, phase == from else {
            throw BJJError.invalid("Recording was interrupted. Tap Record voiceover to retry.")
        }
        phase = to
    }
    mutating func reset() { phase = .idle; sessionID = nil }
}

@objc(BJJNativePlugin)
public class BJJNativePlugin: CAPPlugin, CAPBridgedPlugin, UIDocumentPickerDelegate, PHPickerViewControllerDelegate, AVAudioRecorderDelegate {
    public let identifier = "BJJNativePlugin"
    public let jsName = "BJJNative"
    public let pluginMethods: [CAPPluginMethod] = [
        "listProjects", "getProject", "importVideo", "saveProject", "deleteProject", "listExports",
        "createExport", "getExport", "cancelExport", "getAssetURL", "shareExport",
        "prepareRecording", "startRecording", "stopRecording"
    ].map { CAPPluginMethod(name: $0, returnType: CAPPluginReturnPromise) }
    private var service: BJJService?
    private var startupError: String?
    private var pickerCall: CAPPluginCall?
    private var recorder: AVAudioRecorder?
    private var recordingProject: String?
    private var recordingID: String?
    private var recordingURL: URL?
    private var recordingStart: Double?
    private var lastClip: BJJJSON?
    private var lastSessionID: String?
    private var lifecycle = BJJRecordingLifecycle()
    private let recordingLog = Logger(subsystem: "com.bakedchicken77.bjjtelestrator", category: "recording")
    @MainActor private func traceRecording(_ action: String) {
        recordingLog.info("\(action, privacy: .public) session=\(self.lifecycle.sessionID ?? "none", privacy: .public) state=\(self.lifecycle.phase.rawValue, privacy: .public)")
    }
    private var observations: [NSObjectProtocol] = []

    override public func load() {
        Task { @MainActor in
            do {
                service = try BJJService(store: BJJStore())
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                try AVAudioSession.sharedInstance().setActive(true)
            } catch { startupError = error.localizedDescription }
        }
        observations.append(NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.interrupted("Recording saved before the app moved to the background.")
        })
        observations.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            if (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue {
                self?.interrupted("Recording saved after an audio interruption.")
            }
        })
    }
    deinit { for observation in observations { NotificationCenter.default.removeObserver(observation) } }

    private func perform(_ call: CAPPluginCall, _ work: @escaping @MainActor (BJJService) async throws -> BJJJSON) {
        Task { @MainActor in
            do {
                // Lazy initialization also covers a bridge call arriving during plugin load.
                if service == nil { service = try BJJService(store: BJJStore()) }
                guard let service else { throw BJJError.invalid(startupError ?? "Unable to open local project storage.") }
                call.resolve(try await work(service))
            } catch { call.reject(error.localizedDescription) }
        }
    }
    private func id(_ call: CAPPluginCall, _ key: String = "projectId") throws -> String { try BJJValidate.uuid(call.getString(key)) }
    @objc func listProjects(_ call: CAPPluginCall) { perform(call) { service in ["projects": try service.store.list()] } }
    @objc func getProject(_ call: CAPPluginCall) { perform(call) { [self] service in ["project": try service.store.load(id(call)).json] } }
    @objc func saveProject(_ call: CAPPluginCall) {
        perform(call) { service in
            let value = try BJJValidate.object(call.getObject("project"), "project")
            return ["project": try service.store.save(BJJProject(value)).json]
        }
    }
    @objc func deleteProject(_ call: CAPPluginCall) {
        perform(call) { [self] service in
            let projectId = try id(call)
            guard recordingProject != projectId else { throw BJJError.invalid("Stop recording before deleting this project.") }
            try service.deleteProject(projectId); return [:]
        }
    }
    @objc func listExports(_ call: CAPPluginCall) { perform(call) { [self] service in ["jobs": try service.listExports(id(call))] } }
    @objc func createExport(_ call: CAPPluginCall) { perform(call) { [self] service in ["job": try service.createExport(id(call)).json()] } }
    @objc func getExport(_ call: CAPPluginCall) { perform(call) { [self] service in ["job": try service.job(id(call, "jobId")).json()] } }
    @objc func cancelExport(_ call: CAPPluginCall) { perform(call) { [self] service in ["job": try service.cancel(id(call, "jobId")).json()] } }
    @objc func getAssetURL(_ call: CAPPluginCall) {
        perform(call) { [self] service in
            let projectId = try id(call)
            let reference: String
            if call.getString("kind") == "video" { reference = try service.store.load(projectId).proxy.s("asset") }
            else if call.getString("kind") == "voiceover" {
                let clipId = try id(call, "clipId")
                guard let clip = try service.store.recordings(projectId)[clipId] as? BJJJSON else { throw BJJError.invalid("This recording is missing.") }
                reference = clip.s("asset")
            } else { throw BJJError.invalid("Unknown media asset kind.") }
            _ = try service.store.asset(projectId, reference)
            if call.getString("kind") == "video" {
                return ["url": "capacitor://localhost/bjj-media/\(projectId)/video.mp4"]
            }
            return ["url": "capacitor://localhost/bjj-media/\(projectId)/voiceover/\(try id(call, "clipId")).wav"]
        }
    }
    @objc func shareExport(_ call: CAPPluginCall) {
        Task { @MainActor in
            do {
                guard let service, let host = bridge?.viewController else { throw BJJError.invalid("The share sheet is unavailable.") }
                let url = try service.exportedFile(id(call, "jobId"))
                let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                sheet.popoverPresentationController?.sourceView = host.view
                sheet.popoverPresentationController?.sourceRect = CGRect(x: host.view.bounds.midX, y: host.view.bounds.midY, width: 1, height: 1)
                sheet.completionWithItemsHandler = { _, completed, _, error in
                    if let error { call.reject(error.localizedDescription) } else { call.resolve(["completed": completed]) }
                }
                host.present(sheet, animated: true)
            } catch { call.reject(error.localizedDescription) }
        }
    }
    @objc func importVideo(_ call: CAPPluginCall) {
        DispatchQueue.main.async { [self] in
            guard pickerCall == nil, lifecycle.phase == .idle, let host = bridge?.viewController else {
                call.reject("Finish the current import or recording first."); return
            }
            pickerCall = call
            if call.getString("source") == "photos" {
                var config = PHPickerConfiguration(photoLibrary: .shared())
                config.filter = .videos; config.selectionLimit = 1
                config.preferredAssetRepresentationMode = .current
                let picker = PHPickerViewController(configuration: config); picker.delegate = self
                picker.isModalInPresentation = true
                host.present(picker, animated: true)
            } else {
                let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.movie, .video], asCopy: false)
                picker.allowsMultipleSelection = false; picker.delegate = self
                picker.isModalInPresentation = true
                host.present(picker, animated: true)
            }
        }
    }
    public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        pickerCall?.resolve(["cancelled": true]); pickerCall = nil
    }
    public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { documentPickerWasCancelled(controller); return }
        guard let call = pickerCall else { return }
        pickerCall = nil
        Task { @MainActor in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                guard let service else { throw BJJError.invalid("Project storage is unavailable.") }
                let project = try await service.importFile(url, originalName: url.lastPathComponent)
                call.resolve(["project": project.json])
            } catch { call.reject(error.localizedDescription) }
        }
    }
    public func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let call = pickerCall else { return }
        pickerCall = nil
        guard let item = results.first?.itemProvider else { call.resolve(["cancelled": true]); return }
        let name = item.suggestedName ?? "Rolling video.mov"
        item.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { [weak self] url, error in
            guard let self else { call.reject("Import was interrupted."); return }
            guard let url else { call.reject(error?.localizedDescription ?? "The selected video is unavailable. Download the original from iCloud Photos and try again."); return }
            // NSItemProvider removes its URL after this callback returns; copy it here.
            let stage = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(url.pathExtension)
            do {
                let count = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard count > 0, count <= 4 * 1024 * 1024 * 1024 else { throw BJJError.invalid("Choose a video smaller than 4 GiB.") }
                try FileManager.default.copyItem(at: url, to: stage)
            } catch { call.reject(error.localizedDescription); return }
            Task { @MainActor in
                defer { try? FileManager.default.removeItem(at: stage) }
                do {
                    guard let service = self.service else { throw BJJError.invalid("Project storage is unavailable.") }
                    call.resolve(["project": try await service.importFile(stage, originalName: name).json])
                } catch { call.reject(error.localizedDescription) }
            }
        }
    }
    @objc func prepareRecording(_ call: CAPPluginCall) {
        perform(call) { [self] service in
            let sessionID = try id(call, "sessionId")
            let projectId = try id(call)
            let project = try service.store.load(projectId)
            guard project.voiceovers.count < 200 else { throw BJJError.invalid("This project already has 200 voiceover clips.") }
            try lifecycle.begin(sessionID)
            recordingProject = projectId; lastClip = nil; lastSessionID = nil
            traceRecording("permission requested")
            do {
                let allowed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
                }
                guard lifecycle.sessionID == sessionID else { throw BJJError.invalid("Recording was cancelled. Tap Record voiceover to retry.") }
                guard allowed else { throw BJJError.invalid("Microphone access is denied. Allow BJJ Telestrator in iPhone Settings → Privacy & Security → Microphone.") }
                try service.store.checkSpace(required: 100_000_000)
                // Permission/storage only. WKWebView starts playback before we activate
                // capture, so playback cannot invalidate a pre-created recorder.
                try lifecycle.advance(sessionID, from: .preparing, to: .prepared)
                traceRecording("prepared")
                return [:]
            } catch {
                if lifecycle.sessionID == sessionID { clearRecording() }
                throw error
            }
        }
    }
    @objc func startRecording(_ call: CAPPluginCall) {
        perform(call) { [self] service in
            let sessionID = try id(call, "sessionId")
            guard lifecycle.sessionID == sessionID, lifecycle.phase == .prepared,
                  let projectId = recordingProject else {
                throw BJJError.invalid("Recording was interrupted. Tap Record voiceover to retry.")
            }
            do {
                let duration = try service.store.load(projectId).duration
                let start = try BJJValidate.number(call.getDouble("startSec"), "recording start", 0...(duration - 0.05))
                let session = AVAudioSession.sharedInstance()
                traceRecording("activating capture after playback")
                try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
                try session.setPreferredSampleRate(48000); try session.setActive(true)
                let clipId = UUID().uuidString.lowercased()
                let url = try service.store.directory(projectId).appendingPathComponent("voiceover/\(clipId).wav")
                recordingID = clipId; recordingURL = url
                let recorder = try AVAudioRecorder(url: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
                self.recorder = recorder; recorder.delegate = self
                guard recorder.prepareToRecord(), recorder.record(forDuration: duration - start) else {
                    throw BJJError.invalid("The microphone could not start recording. Tap Record voiceover to retry.")
                }
                recordingStart = start
                try lifecycle.advance(sessionID, from: .prepared, to: .recording)
                traceRecording("capture started")
                return ["elapsedSec": recorder.currentTime]
            } catch {
                let failedURL = recordingURL
                clearRecording()
                if let failedURL { try? FileManager.default.removeItem(at: failedURL) }
                throw error
            }
        }
    }
    @objc func stopRecording(_ call: CAPPluginCall) {
        perform(call) { [self] _ in
            let sessionID = try id(call, "sessionId")
            guard lifecycle.sessionID == sessionID else {
                return lastSessionID == sessionID ? (lastClip.map { ["clip": $0] } ?? [:]) : [:]
            }
            let clip = try finishRecording(start: call.getDouble("startSec"))
            return clip.map { ["clip": $0] } ?? [:]
        }
    }
    @MainActor private func clearRecording() {
        recorder?.delegate = nil
        recorder?.stop()
        recorder = nil; recordingProject = nil; recordingID = nil; recordingURL = nil; recordingStart = nil
        lifecycle.reset()
        // Mix with the WebKit playback session instead of interrupting it on teardown.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
    }
    @MainActor private func finishRecording(start: Double? = nil) throws -> BJJJSON? {
        guard let sessionID = lifecycle.sessionID else { return nil }
        lastSessionID = sessionID
        traceRecording("finishing")
        defer { clearRecording() }
        guard let recorder, let projectId = recordingProject, let clipId = recordingID,
              let url = recordingURL, let service else { return nil }
        try lifecycle.advance(sessionID, from: .recording, to: .stopping)
        recorder.delegate = nil
        recorder.stop()
        guard let recordingStart else { try? FileManager.default.removeItem(at: url); return nil }
        let project = try service.store.load(projectId)
        let actualStart = start ?? recordingStart
        guard actualStart.isFinite, actualStart >= 0, actualStart < project.duration else { throw BJJError.invalid("The recording start is outside the video.") }
        let audio = try AVAudioFile(forReading: url)
        let duration = min(Double(audio.length) / audio.fileFormat.sampleRate, project.duration - actualStart)
        guard duration >= 0.05 else { try? FileManager.default.removeItem(at: url); return nil }
        let clip: BJJJSON = ["id": clipId, "asset": "voiceover/\(clipId).wav", "startSec": actualStart,
                             "durationSec": duration, "endSec": actualStart + duration, "gain": 1.0, "muted": false,
                             "timingOffsetMs": 0.0, "recordedAt": BJJProject.now(), "codec": "pcm_s16le",
                             "sampleRate": Int(audio.fileFormat.sampleRate), "channels": Int(audio.fileFormat.channelCount)]
        try service.store.registerClip(projectId, clip: clip)
        lastClip = clip
        return clip
    }
    private func interrupted(_ reason: String, source: AVAudioRecorder? = nil) {
        // Capture the token before scheduling, so a queued old notification cannot
        // finish a new session. NotificationCenter delivers these on the main queue.
        let sessionID = lifecycle.sessionID
        Task { @MainActor in
            guard let sessionID, lifecycle.sessionID == sessionID,
                  source == nil || source === recorder, let projectId = recordingProject else { return }
            traceRecording("interrupted")
            do {
                let clip = try finishRecording()
                var event: BJJJSON = ["projectId": projectId, "sessionId": sessionID,
                    "reason": clip == nil ? "Recording interrupted before a clip could be saved. Tap Record voiceover to retry." : reason]
                if let clip { event["clip"] = clip }
                notifyListeners("recordingFinished", data: event)
            } catch {
                notifyListeners("recordingFinished", data: ["projectId": projectId, "sessionId": sessionID,
                    "reason": "Recording stopped. The clip could not be saved.", "error": error.localizedDescription])
            }
        }
    }
    public func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        interrupted(flag ? "Recording saved at the end of the video." : "Recording stopped after a microphone error; readable audio was saved.", source: recorder)
    }
    public func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        interrupted("Recording stopped after a microphone error; readable audio was saved.", source: recorder)
    }
}
