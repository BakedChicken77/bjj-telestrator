import Foundation
import AVFoundation
import UIKit
import os

struct BJJExportJob: Codable {
    let jobId: String
    let projectId: String
    var status: String
    var progress: Double
    var renderedSec: Double
    var error: String?
    var filename: String?
    let createdAt: String
    func json() throws -> BJJJSON {
        var value = try BJJValidate.object(JSONSerialization.jsonObject(with: JSONEncoder().encode(self)), "export")
        value["error"] = error.map { $0 as Any } ?? NSNull()
        value["filename"] = filename.map { $0 as Any } ?? NSNull()
        return value
    }
}

@MainActor final class BJJService {
    let store: BJJStore
    private var jobs: [String: BJJExportJob] = [:]
    private var queue: [String] = []
    private var snapshots: [String: BJJProject] = [:]
    private var renderer: BJJRenderer?
    private var activeJob: String?
    private var background: UIBackgroundTaskIdentifier = .invalid
    private let logger = Logger(subsystem: "com.bjjtelestrator.app", category: "media")

    init(store: BJJStore) throws {
        self.store = store
        let folders = try FileManager.default.contentsOfDirectory(at: store.root, includingPropertiesForKeys: nil)
        for folder in folders where UUID(uuidString: folder.lastPathComponent) != nil {
            if !FileManager.default.fileExists(atPath: folder.appendingPathComponent("project.json").path) {
                // An import killed by iOS has no committed project and can be retried
                // from its untouched Photos/Files original.
                try FileManager.default.removeItem(at: folder)
                continue
            }
            let exportFolder = folder.appendingPathComponent("exports")
            for path in (try? FileManager.default.contentsOfDirectory(at: exportFolder, includingPropertiesForKeys: nil)) ?? [] where path.pathExtension == "json" {
                do {
                    var job = try JSONDecoder().decode(BJJExportJob.self, from: Data(contentsOf: path))
                    try BJJValidate.uuid(job.jobId); try BJJValidate.uuid(job.projectId)
                    guard job.projectId == folder.lastPathComponent else { continue }
                    if ["running", "queued"].contains(job.status) {
                        job.status = "failed"
                        job.error = "The app closed before this export finished. Start a new export and keep the app open."
                    }
                    jobs[job.jobId] = job
                    try persist(job)
                } catch { logger.error("Unreadable export metadata: \(error.localizedDescription, privacy: .public)") }
            }
            let temp = folder.appendingPathComponent("temp")
            for path in (try? FileManager.default.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil)) ?? [] {
                try? FileManager.default.removeItem(at: path)
            }
        }
    }
    private func persist(_ job: BJJExportJob) throws {
        let url = try store.directory(job.projectId).appendingPathComponent("exports/\(job.jobId).json")
        try JSONEncoder().encode(job).write(to: url, options: .atomic)
    }
    func listExports(_ projectId: String) throws -> [BJJJSON] {
        try BJJValidate.uuid(projectId)
        return try jobs.values.filter { $0.projectId == projectId }.sorted { $0.createdAt > $1.createdAt }.map { try $0.json() }
    }
    func job(_ id: String) throws -> BJJExportJob {
        try BJJValidate.uuid(id)
        guard let job = jobs[id] else { throw BJJError.invalid("This export does not exist.") }
        return job
    }
    func createExport(_ projectId: String) throws -> BJJExportJob {
        let project = try store.load(projectId)
        guard project.exportSettings.n("fps") <= 60 else { throw BJJError.invalid("Choose an export frame rate of 60 fps or less on iPhone.") }
        try store.checkSpace(required: Int64(project.duration * 2_000_000) + 100_000_000)
        let id = UUID().uuidString.lowercased()
        let stamp = BJJProject.now().replacingOccurrences(of: ":", with: "-")
        let name = "\(BJJStore.sanitized(project.name))-annotated-\(stamp)-\(id.prefix(8)).mp4"
        let job = BJJExportJob(jobId: id, projectId: projectId, status: "queued", progress: 0, renderedSec: 0,
                               filename: name, createdAt: BJJProject.now())
        jobs[id] = job; snapshots[id] = project; queue.append(id)
        try persist(job)
        Task { startNext() }
        return job
    }
    func cancel(_ id: String, reason: String? = nil) throws -> BJJExportJob {
        var item = try job(id)
        guard ["queued", "running"].contains(item.status) else { return item }
        item.status = "cancelled"; item.error = reason
        jobs[id] = item; try persist(item)
        queue.removeAll { $0 == id }
        if activeJob == id { renderer?.cancel() } else { snapshots.removeValue(forKey: id) }
        return item
    }
    func deleteProject(_ id: String) throws {
        guard !jobs.values.contains(where: { $0.projectId == id && ["queued", "running"].contains($0.status) }) else {
            throw BJJError.invalid("Cancel this project's pending exports before deleting it.")
        }
        try store.delete(id)
        jobs = jobs.filter { $0.value.projectId != id }
    }
    func exportedFile(_ id: String) throws -> URL {
        let job = try job(id)
        guard job.status == "completed", let name = job.filename, name == URL(fileURLWithPath: name).lastPathComponent else {
            throw BJJError.invalid("The MP4 is not ready to share.")
        }
        return try store.asset(job.projectId, "exports/\(name)")
    }
    private func startNext() {
        guard activeJob == nil, let id = queue.first, let project = snapshots[id] else { return }
        queue.removeFirst(); activeJob = id
        let worker = BJJRenderer(); renderer = worker
        jobs[id]?.status = "running"
        if let job = jobs[id] { try? persist(job) }
        UIApplication.shared.isIdleTimerDisabled = true
        background = UIApplication.shared.beginBackgroundTask(withName: "BJJ video export") { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                _ = try? self.cancel(id, reason: "iOS stopped the background export. Keep BJJ Telestrator open while rendering, then retry.")
                self.endBackgroundTask()
            }
        }
        Task {
            var temporary: URL?
            defer {
                if let temporary { try? FileManager.default.removeItem(at: temporary) }
                renderer = nil; activeJob = nil; snapshots.removeValue(forKey: id)
                UIApplication.shared.isIdleTimerDisabled = false
                endBackgroundTask(); startNext()
            }
            do {
                let source = try store.asset(project.id, project.source.s("asset"))
                let media = try await BJJMedia.inspect(source, reference: project.source.s("asset"), originalName: project.source.s("originalFilename"))
                let staging = try store.directory(project.id).appendingPathComponent("temp/\(id).mp4")
                temporary = staging
                logger.info("Export started: \(id, privacy: .public)")
                try await worker.render(media: media, project: project, store: store, output: staging) { [weak self] seconds in
                    Task { @MainActor in
                        guard let self, self.jobs[id]?.status == "running" else { return }
                        self.jobs[id]?.renderedSec = seconds
                        self.jobs[id]?.progress = min(99, seconds / project.duration * 100)
                    }
                }
                if jobs[id]?.status == "cancelled" { return }
                let probe = try await BJJMedia.inspect(staging, reference: "exports/output.mp4", originalName: "output.mp4")
                let tolerance = max(0.1, 1 / project.exportSettings.n("fps"))
                let expectedAudio = (media.json["hasAudio"] as! Bool) || project.voiceovers.contains {
                    !($0["muted"] as! Bool) && $0.n("gain") * project.settings.n("voiceoverMasterGain") > 0
                }
                guard probe.json.s("codec") == "avc1", abs(probe.videoRange.duration.seconds - project.duration) <= tolerance,
                      probe.orientedSize == BJJRenderer.outputSize(media.orientedSize),
                      (probe.json["hasAudio"] as? Bool) == expectedAudio,
                      !expectedAudio || probe.json["audioCodec"] as? String == "aac" else {
                    logger.error("Export validation: video=\(probe.json.s("codec"), privacy: .public), audio=\(String(describing: probe.json["audioCodec"]), privacy: .public), duration=\(probe.videoRange.duration.seconds), expected=\(project.duration), width=\(probe.orientedSize.width), height=\(probe.orientedSize.height)")
                    throw BJJError.invalid("The completed MP4 failed its codec, dimensions, audio or duration check. Try exporting again.")
                }
                let target = try store.directory(project.id).appendingPathComponent("exports/\(jobs[id]!.filename!)")
                try FileManager.default.moveItem(at: staging, to: target)
                jobs[id]?.status = "completed"; jobs[id]?.progress = 100; jobs[id]?.renderedSec = project.duration
                logger.info("Export completed: \(id, privacy: .public)")
            } catch {
                if jobs[id]?.status != "cancelled" {
                    jobs[id]?.status = "failed"; jobs[id]?.error = error.localizedDescription
                    logger.error("Export failed: \(id, privacy: .public), \(error.localizedDescription, privacy: .public)")
                }
            }
            if let job = jobs[id] { try? persist(job) }
        }
    }
    private func endBackgroundTask() {
        if background != .invalid { UIApplication.shared.endBackgroundTask(background); background = .invalid }
    }
    func importFile(_ input: URL, originalName: String) async throws -> BJJProject {
        let size = try input.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 4 * 1024 * 1024 * 1024 else { throw BJJError.invalid("Choose a nonempty video smaller than 4 GiB.") }
        try store.checkSpace(required: Int64(size) * 2 + 250_000_000)
        let (id, folder) = try store.createDirectory()
        do {
            let ext = input.pathExtension.lowercased()
            let safeExtension = ["mov", "mp4", "m4v"].contains(ext) ? ext : "mov"
            let reference = "source/\(UUID().uuidString.lowercased()).\(safeExtension)"
            let source = folder.appendingPathComponent(reference)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { try FileManager.default.copyItem(at: input, to: source); continuation.resume() }
                    catch { continuation.resume(throwing: error) }
                }
            }
            let media = try await BJJMedia.inspect(source, reference: reference, originalName: originalName)
            let proxyRef = "proxy/\(UUID().uuidString.lowercased()).mp4"
            let proxy = folder.appendingPathComponent(proxyRef)
            let encoder = BJJRenderer()
            let token = UIApplication.shared.beginBackgroundTask(withName: "BJJ video import") { encoder.cancel() }
            UIApplication.shared.isIdleTimerDisabled = true
            defer {
                if token != .invalid { UIApplication.shared.endBackgroundTask(token) }
                UIApplication.shared.isIdleTimerDisabled = activeJob != nil
            }
            try await encoder.render(media: media, project: nil, store: store, output: proxy, proxy: true) { _ in }
            let proxyMedia = try await BJJMedia.inspect(proxy, reference: proxyRef, originalName: originalName)
            var proxyJSON = proxyMedia.json
            // Logical media time always belongs to the source, independent of frame rounding.
            proxyJSON["durationSec"] = media.videoRange.duration.seconds
            let now = BJJProject.now()
            let title = String(URL(fileURLWithPath: originalName).deletingPathExtension().lastPathComponent.prefix(160)).trimmingCharacters(in: .whitespacesAndNewlines)
            let project = try BJJProject([
                "schemaVersion": 1, "projectId": id,
                "projectName": title.isEmpty ? "Rolling review" : title,
                "createdAt": now, "updatedAt": now, "source": media.json, "proxy": proxyJSON,
                "settings": ["defaultAnnotationDuration": 5.0, "seekStepSec": 0.1, "largeSeekStepSec": 1.0,
                             "originalAudioGain": 1.0, "originalAudioMuted": false, "voiceoverMasterGain": 1.0],
                "exportSettings": ["fps": min(60, media.fps), "crf": 23, "preset": "medium"],
                "annotations": [BJJJSON](), "voiceovers": [BJJJSON]()
            ])
            return try store.save(project, creating: true)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }
}
