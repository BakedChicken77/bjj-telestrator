import Foundation
import Capacitor
import AVFoundation
import PhotosUI
import UniformTypeIdentifiers
import UIKit

@objc(BJJNativePlugin)
public class BJJNativePlugin: CAPPlugin, CAPBridgedPlugin, UIDocumentPickerDelegate, PHPickerViewControllerDelegate, AVAudioRecorderDelegate {
    public let identifier = "BJJNativePlugin"
    public let jsName = "BJJNative"
    public let pluginMethods: [CAPPluginMethod] = [
        "listProjects", "getProject", "importVideo", "saveProject", "deleteProject", "listExports",
        "createExport", "getExport", "cancelExport", "getAssetURL", "shareExport",
        "prepareRecording", "startRecording", "stopRecording", "getCapabilities",
        "writeRecoveryDraft", "getRecoveryDrafts", "clearRecoveryDraft", "recoverProjectCopy", "shareDiagnostics"
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
        observations.append(NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.notifyListeners("appSuspending", data: [:])
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
            } catch {
                if let domain = error as? BJJError { call.reject(domain.localizedDescription, domain.code) }
                else { call.reject("Unable to access local project storage. Check free space and retry.", "STORAGE_UNAVAILABLE") }
            }
        }
    }
    private func id(_ call: CAPPluginCall, _ key: String = "projectId") throws -> String { try BJJValidate.uuid(call.getString(key)) }
    @objc func getCapabilities(_ call: CAPPluginCall) { call.resolve(BJJProjectMigrations.capabilities) }
    @objc func writeRecoveryDraft(_ call: CAPPluginCall) {
        perform(call) { service in try service.store.writeDraft(BJJValidate.object(call.getObject("draft"), "recovery draft")); return [:] }
    }
    @objc func getRecoveryDrafts(_ call: CAPPluginCall) {
        perform(call) { [self] service in ["drafts": try service.store.recoveryDrafts(id(call))] }
    }
    @objc func clearRecoveryDraft(_ call: CAPPluginCall) {
        perform(call) { [self] service in
            try service.store.clearDraft(id(call), writer: id(call, "writerId"), draft: id(call, "draftId")); return [:]
        }
    }
    @objc func recoverProjectCopy(_ call: CAPPluginCall) {
        perform(call) { service in
            ["project": try service.store.recoverCopy(BJJProject(BJJValidate.object(call.getObject("project"), "recovery project"))).json]
        }
    }
    @objc func listProjects(_ call: CAPPluginCall) { perform(call) { service in ["projects": try service.store.list()] } }
    @objc func getProject(_ call: CAPPluginCall) { perform(call) { [self] service in ["project": try service.store.loadRecoveringRecordings(id(call)).json] } }
    @objc func saveProject(_ call: CAPPluginCall) {
        perform(call) { service in
            let value = try BJJValidate.object(call.getObject("project"), "project")
            let revision = try BJJValidate.number(call.getDouble("expectedRevision"), "expected revision", 1...9007199254740991, integer: true)
            guard revision == (value["revision"] as? NSNumber)?.doubleValue else { throw BJJError.domain("REVISION_REQUIRED", "The request and project revisions do not match.") }
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
    @objc func createExport(_ call: CAPPluginCall) {
        perform(call) { [self] service in
            let revision = try BJJValidate.number(call.getDouble("expectedRevision"), "expected revision", 1...9007199254740991, integer: true)
            return ["job": try service.createExport(id(call), expectedRevision: Int(revision)).json()]
        }
    }
    @objc func shareDiagnostics(_ call: CAPPluginCall) {
        perform(call) { [self] _ in
            guard let text = call.getString("text"), text.utf8.count < 32768,
                  let host = bridge?.viewController else { throw BJJError.invalid("The support summary is unavailable.") }
            let sheet = UIActivityViewController(activityItems: [text], applicationActivities: nil)
            sheet.popoverPresentationController?.sourceView = host.view
            sheet.popoverPresentationController?.sourceRect = CGRect(x: host.view.bounds.midX, y: host.view.bounds.midY, width: 1, height: 1)
            host.present(sheet, animated: true)
            return [:]
        }
    }
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
            guard pickerCall == nil, recorder == nil, let host = bridge?.viewController else {
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
            guard recorder == nil else { throw BJJError.invalid("A recording is already active.") }
            let projectId = try id(call)
            let project = try service.store.load(projectId)
            guard project.voiceovers.count < 200 else { throw BJJError.invalid("This project already has 200 voiceover clips.") }
            let allowed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
            }
            guard allowed else { throw BJJError.invalid("Microphone access is denied. Allow BJJ Telestrator in iPhone Settings → Privacy & Security → Microphone.") }
            try service.store.checkSpace(required: 100_000_000)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setPreferredSampleRate(48000); try session.setActive(true)
            let clipId = UUID().uuidString.lowercased()
            let url = try service.store.directory(projectId).appendingPathComponent("voiceover/\(clipId).wav")
            let recorder = try AVAudioRecorder(url: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
            recorder.delegate = self
            guard recorder.prepareToRecord() else { throw BJJError.invalid("The iPhone microphone could not be prepared.") }
            self.recorder = recorder; recordingProject = projectId; recordingID = clipId; recordingURL = url
            recordingStart = nil; lastClip = nil
            return [:]
        }
    }
    @objc func startRecording(_ call: CAPPluginCall) {
        perform(call) { [self] service in
            guard let recorder, let projectId = recordingProject else { throw BJJError.invalid("Prepare the microphone before recording.") }
            let start = try BJJValidate.number(call.getDouble("startSec"), "recording start", 0...(service.store.load(projectId).duration - 0.05))
            let remaining = try service.store.load(projectId).duration - start
            guard !recorder.isRecording, recorder.record(forDuration: remaining) else { throw BJJError.invalid("The microphone could not start recording.") }
            recordingStart = start
            return ["elapsedSec": recorder.currentTime]
        }
    }
    @objc func stopRecording(_ call: CAPPluginCall) {
        perform(call) { [self] _ in
            let clip = try finishRecording(start: call.getDouble("startSec"))
            return clip.map { ["clip": $0] } ?? [:]
        }
    }
    @MainActor private func finishRecording(start: Double? = nil) throws -> BJJJSON? {
        guard let recorder, let projectId = recordingProject, let clipId = recordingID, let url = recordingURL, let service else { return lastClip }
        recorder.stop()
        defer {
            self.recorder = nil; recordingProject = nil; recordingID = nil; recordingURL = nil; recordingStart = nil
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
        }
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
    private func interrupted(_ reason: String) {
        Task { @MainActor in
            guard let projectId = recordingProject else { return }
            do {
                let clip = try finishRecording()
                var event: BJJJSON = ["projectId": projectId, "reason": reason]
                if let clip { event["clip"] = clip }
                notifyListeners("recordingFinished", data: event, retainUntilConsumed: true)
            } catch {
                notifyListeners("recordingFinished", data: ["projectId": projectId, "reason": reason, "error": error.localizedDescription], retainUntilConsumed: true)
            }
        }
    }
    public func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        interrupted(flag ? "Recording saved at the end of the video." : "Recording stopped after a microphone error; any readable audio was saved.")
    }
    public func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        interrupted(error?.localizedDescription ?? "The microphone encountered a recording error; any readable audio was saved.")
    }
}
