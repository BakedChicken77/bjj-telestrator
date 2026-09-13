import Foundation
import AVFoundation
import UIKit

struct BJJMediaJob: Codable {
    let jobId: String
    let projectId: String
    let operation: String
    var status = "queued"
    var stage = "copying"
    var progress: Double?
    var copiedBytes: Int64 = 0
    var totalBytes: Int64?
    var cancelRequested = false
    var errorCode: String?
    var error: String?
    var projectRevision: Int?
    let createdAt: String
    var terminal: Bool { ["completed", "failed", "cancelled"].contains(status) }
    func json() throws -> BJJJSON {
        var value = try BJJValidate.object(JSONSerialization.jsonObject(with: JSONEncoder().encode(self)), "media job")
        value["progress"] = progress.map { $0 as Any } ?? NSNull()
        return value
    }
}

/// Progress can be produced by a Photos callback or an encoder without hopping
/// through the main actor once per byte/frame. Polling consumes a bounded value.
final class BJJMediaWork {
    let cancellation = BJJJobCancellation()
    private let lock = NSLock()
    private var copied: Int64 = 0, total: Int64 = 0
    private var fraction: Double = 0
    func copying(_ count: Int64, _ size: Int64) { lock.lock(); copied = count; total = size; lock.unlock() }
    func rendering(_ value: Double) { lock.lock(); fraction = max(0, min(1, value)); lock.unlock() }
    func snapshot() -> (Int64, Int64, Double) { lock.lock(); defer { lock.unlock() }; return (copied, total, fraction) }
    static func copy(_ input: URL, _ target: URL, store: BJJStore, work: BJJMediaWork) throws {
        let size = Int64(try input.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        guard size > 0, size <= 4 * 1024 * 1024 * 1024 else { throw BJJError.domain("MEDIA_UNSUPPORTED", "Choose a nonempty video smaller than 4 GiB.") }
        try store.checkSpace(required: (BJJAssets.estimate("import", output: 0, incoming: size)["requiredBytes"] as! NSNumber).int64Value)
        let source = try FileHandle(forReadingFrom: input)
        defer { try? source.close() }
        guard FileManager.default.createFile(atPath: target.path, contents: nil) else { throw BJJError.domain("STORAGE_UNAVAILABLE", "Unable to stage the selected video.") }
        let destination = try FileHandle(forWritingTo: target)
        defer { try? destination.close() }
        var count: Int64 = 0
        work.copying(0, size)
        while true {
            try work.cancellation.check()
            let bytes: Int = try autoreleasepool {
                let data = try source.read(upToCount: Int(BJJAssets.mib)) ?? Data()
                try destination.write(contentsOf: data)
                return data.count
            }
            if bytes == 0 { break }
            count += Int64(bytes)
            guard count <= 4 * 1024 * 1024 * 1024 else { throw BJJError.domain("MEDIA_UNSUPPORTED", "The selected video exceeds 4 GiB.") }
            if count % (16 * BJJAssets.mib) < Int64(bytes) {
                try store.checkSpace(required: (BJJAssets.estimate("import", output: 0)["requiredBytes"] as! NSNumber).int64Value)
            }
            work.copying(count, size)
        }
        guard count == size else { throw BJJError.domain("ASSET_CHANGED", "The selected file changed while copying. Select it again.") }
        try destination.synchronize()
        try work.cancellation.check()
    }
}

@MainActor final class BJJMediaJobs {
    let store: BJJStore
    private var jobs: [String: BJJMediaJob] = [:]
    private var work: [String: BJJMediaWork] = [:]
    private var encoders: [String: BJJRenderer] = [:]
    var activityChanged: (() -> Void)?
    var active: Bool { jobs.values.contains { !$0.terminal && $0.status == "running" } }
    private var root: URL { store.root.appendingPathComponent("media-jobs") }
    init(store: BJJStore) throws {
        self.store = store
        guard (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw BJJError.domain("ASSET_UNSAFE", "The media job folder is unsafe.") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }).prefix(256) where url.pathExtension == "json" {
            do {
                guard (try url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])).isSymbolicLink != true,
                      ((try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0) < 65536 else { continue }
                let record = try store.readJSON(url)
                try BJJValidate.number(record["version"], "media record version", 1...1, integer: true)
                var job = try JSONDecoder().decode(BJJMediaJob.self, from: JSONSerialization.data(withJSONObject: BJJValidate.object(record["job"], "media job")))
                try validate(job)
                guard job.jobId == url.deletingPathExtension().lastPathComponent else { continue }
                if !job.terminal {
                    job.status = "failed"; job.errorCode = "MEDIA_INTERRUPTED"
                    job.error = "Video preparation stopped when the app closed. Import again or repair the preview; saved projects were preserved."
                    let folder = try store.directory(job.projectId)
                    if job.operation == "import" {
                        if let project = try? store.load(job.projectId) {
                            job.status = "completed"; job.stage = "ready"; job.progress = 1; job.projectRevision = project.revision
                            job.error = nil; job.errorCode = nil
                        } else if !FileManager.default.fileExists(atPath: folder.appendingPathComponent("save-transaction.json").path) {
                            try? FileManager.default.removeItem(at: folder)
                        }
                    }
                    try? FileManager.default.removeItem(at: store.safeURL(job.projectId, "temp/media-\(job.jobId).mp4"))
                    try persist(job)
                }
                jobs[job.jobId] = job; work[job.jobId] = BJJMediaWork()
            } catch { continue }
        }
    }
    private func validate(_ job: BJJMediaJob) throws {
        try BJJValidate.uuid(job.jobId); try BJJValidate.uuid(job.projectId); try BJJValidate.timestamp(job.createdAt)
        guard ["import", "repair"].contains(job.operation), ["queued", "running", "completed", "failed", "cancelled"].contains(job.status),
              ["copying", "inspecting", "preparing_preview", "validating", "ready"].contains(job.stage),
              job.progress.map({ $0.isFinite && (0...1).contains($0) }) ?? true else { throw BJJError.invalid("Invalid media job.") }
    }
    private func persist(_ job: BJJMediaJob) throws {
        let path = root.appendingPathComponent("\(job.jobId).json")
        guard (try? path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw BJJError.domain("ASSET_UNSAFE", "The media job record is unsafe.") }
        try store.writeJSON(["version": 1, "job": try job.json()], to: path)
    }
    func get(_ id: String) throws -> BJJMediaJob {
        try BJJValidate.uuid(id)
        guard var job = jobs[id] else { throw BJJError.domain("JOB_MISSING", "This video preparation is no longer available. Start it again.") }
        if let state = work[id]?.snapshot(), !job.terminal {
            if job.stage == "copying", state.1 > 0 {
                job.copiedBytes = state.0; job.totalBytes = state.1; job.progress = min(1, Double(state.0) / Double(state.1))
            } else if job.stage == "preparing_preview" { job.progress = state.2 }
        }
        return job
    }
    func create(_ project: BJJProject? = nil) throws -> BJJMediaJob {
        guard jobs.values.filter({ !$0.terminal }).count < 2 else { throw BJJError.domain("JOB_ACTIVE", "Finish or cancel the current video preparation first.") }
        if jobs.count >= 256, let oldest = jobs.values.filter({ $0.terminal }).min(by: { ($0.createdAt, $0.jobId) < ($1.createdAt, $1.jobId) }) {
            try FileManager.default.removeItem(at: root.appendingPathComponent("\(oldest.jobId).json"))
            jobs.removeValue(forKey: oldest.jobId); work.removeValue(forKey: oldest.jobId)
        }
        let job = BJJMediaJob(jobId: UUID().uuidString.lowercased(), projectId: project?.id ?? UUID().uuidString.lowercased(),
                              operation: project == nil ? "import" : "repair", stage: project == nil ? "copying" : "inspecting", createdAt: BJJProject.now())
        try persist(job); jobs[job.jobId] = job; work[job.jobId] = BJJMediaWork()
        return job
    }
    private func update(_ id: String, _ change: (inout BJJMediaJob) -> Void) throws {
        guard var job = jobs[id], !job.terminal else { return }
        change(&job); jobs[id] = job; activityChanged?(); try persist(job)
    }
    @discardableResult func cancel(_ id: String) throws -> BJJMediaJob {
        let job = try get(id)
        if !job.terminal {
            work[id]?.cancellation.cancel(); encoders[id]?.cancel()
            try update(id) { $0.cancelRequested = true; if job.status == "queued" { $0.status = "cancelled"; $0.errorCode = "JOB_CANCELLED" } }
        }
        return try get(id)
    }
    func failure(_ id: String, _ error: Error) {
        let cancelled = (try? work[id]?.cancellation.check()) == nil
        let code = cancelled ? "JOB_CANCELLED" : ((error as? BJJError)?.code ?? ((error as? CocoaError)?.code == .fileWriteOutOfSpace ? "STORAGE_LOW" : "MEDIA_FAILED"))
        try? update(id) {
            $0.status = cancelled ? "cancelled" : "failed"; $0.errorCode = code
            $0.error = cancelled ? "Video preparation was cancelled." : ((error as? BJJError)?.localizedDescription ?? "Video preparation failed. Check storage and choose a complete supported source. Existing projects were preserved.")
        }
        cleanupImport(id)
    }
    private func cleanupImport(_ id: String) {
        guard let job = jobs[id], job.operation == "import", let folder = try? store.directory(job.projectId) else { return }
        if !FileManager.default.fileExists(atPath: folder.appendingPathComponent("project.json").path),
           !FileManager.default.fileExists(atPath: folder.appendingPathComponent("save-transaction.json").path) {
            try? FileManager.default.removeItem(at: folder)
        }
    }
    func beginImport(_ id: String) throws -> (URL, BJJMediaWork) {
        let job = try get(id)
        try work[id]!.cancellation.check()
        guard job.operation == "import", job.status == "queued" else { throw BJJError.domain("JOB_ACTIVE", "This import was already started. Check its status before retrying.") }
        try update(id) { $0.status = "running" }
        _ = try store.createDirectory(id: job.projectId)
        return (try store.safeURL(job.projectId, "source/\(id).mov"), work[id]!)
    }
    func importFile(_ input: URL, originalName: String) async throws -> BJJProject {
        let job = try create()
        do {
            let (destination, worker) = try beginImport(job.jobId)
            try await BJJAssets.offMain { [store] in try BJJMediaWork.copy(input, destination, store: store, work: worker) }
            return try await finishImport(job.jobId, originalName: originalName)
        } catch { failure(job.jobId, error); throw error }
    }
    func finishImport(_ id: String, originalName: String) async throws -> BJJProject {
        try await prepare(id, sourceReference: "source/\(id).mov", originalName: originalName, snapshot: nil)
    }
    func repair(_ id: String, revision: Int) throws -> BJJMediaJob {
        let project = try store.loadRecoveringRecordings(id)
        guard project.revision == revision else { throw BJJError.domain("PROJECT_CONFLICT", "The saved review changed. Reopen it before repairing the preview.") }
        try store.acquireLease(id)
        do {
            let job = try create(project)
            Task { [self] in _ = try? await prepare(job.jobId, sourceReference: project.source.s("asset"), originalName: project.source.s("originalFilename"), snapshot: project) }
            return job
        } catch { store.releaseLease(id); throw error }
    }
    private func prepare(_ id: String, sourceReference: String, originalName: String, snapshot: BJJProject?) async throws -> BJJProject {
        defer {
            // Includes failures before an encoder or temporary path can be created.
            if let snapshot { store.releaseLease(snapshot.id) } else { cleanupImport(id) }
            activityChanged?()
        }
        do { return try await prepareMedia(id, sourceReference: sourceReference, originalName: originalName, snapshot: snapshot) }
        catch { failure(id, error); throw error }
    }
    private func prepareMedia(_ id: String, sourceReference: String, originalName: String, snapshot: BJJProject?) async throws -> BJJProject {
        let job = try get(id), worker = work[id]!
        let temporary = try store.safeURL(job.projectId, "temp/media-\(id).mp4")
        let proxyRef = "proxy/\(UUID().uuidString.lowercased()).mp4", encoder = BJJRenderer()
        let candidate = try store.safeURL(job.projectId, proxyRef)
        encoders[id] = encoder
        let background = UIApplication.shared.beginBackgroundTask(withName: "BJJ video preparation") { [weak self] in Task { @MainActor in _ = try? self?.cancel(id) } }
        defer {
            encoders.removeValue(forKey: id)
            if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
            try? FileManager.default.removeItem(at: temporary)
            // Keep any candidate owned by a committed document or pending atomic save.
            if let current = try? store.load(job.projectId), current.proxy.s("asset") != proxyRef { try? FileManager.default.removeItem(at: candidate) }
        }
        do {
            try worker.cancellation.check()
            try update(id) { $0.status = "running"; $0.stage = "inspecting"; $0.progress = nil }
            let source = try BJJAssets.file(store, job.projectId, sourceReference)
            let hash = try await BJJAssets.offMain { [store] in
                if let snapshot {
                    var json = snapshot.json; json["voiceovers"] = [BJJJSON]()
                    return try BJJAssets.manifest(store, BJJProject(json), cancellation: worker.cancellation)[0].s("sha256")
                }
                return try BJJAssets.digest(source, cancellation: worker.cancellation)
            }
            let media = try await BJJMedia.inspect(source, reference: sourceReference, originalName: originalName)
            if let snapshot {
                guard abs(media.videoRange.duration.seconds - snapshot.duration) <= 0.001,
                      abs(media.videoRange.start.seconds - ((snapshot.source["videoStartSec"] as? NSNumber)?.doubleValue ?? 0)) <= 0.001,
                      Int(media.orientedSize.width) == Int(snapshot.source.n("displayWidth")), Int(media.orientedSize.height) == Int(snapshot.source.n("displayHeight")) else {
                    throw BJJError.domain("ASSET_CHANGED", "The original video no longer matches this review. Restore its original file.")
                }
            }
            try store.checkSpace(required: (BJJAssets.proxyEstimate(media.videoRange.duration.seconds)["requiredBytes"] as! NSNumber).int64Value)
            try worker.cancellation.check()
            try update(id) { $0.stage = "preparing_preview"; $0.progress = 0 }
            try await encoder.render(media: media, project: nil, store: store, output: temporary, proxy: true) { worker.rendering($0 / media.videoRange.duration.seconds) }
            try update(id) { $0.stage = "validating"; $0.progress = nil }
            let preview = try await BJJMedia.inspect(temporary, reference: proxyRef, originalName: originalName)
            let expected = BJJRenderer.outputSize(media.orientedSize, maximum: 1920)
            guard !BJJColor.isHDR(preview.json), ["avc1", "h264"].contains(preview.json.s("codec")), preview.orientedSize == expected, abs(preview.json.n("rotation")) < 0.001,
                  preview.fps <= 30.01, abs(preview.videoRange.duration.seconds - media.videoRange.duration.seconds) <= max(0.1, 1 / min(30, media.fps)),
                  preview.json["hasAudio"] as? Bool == media.json["hasAudio"] as? Bool,
                  preview.json["hasAudio"] as? Bool != true || preview.json.s("audioCodec") == "aac" else {
                throw BJJError.domain("MEDIA_VALIDATION_FAILED", "The preview failed its orientation, timing, codec or audio check. The previous project was preserved.")
            }
            guard try await BJJAssets.offMain({ try BJJAssets.digest(source, cancellation: worker.cancellation) }) == hash else {
                throw BJJError.domain("ASSET_CHANGED", "The original changed during preparation. Restore its original file.")
            }
            var proxy = preview.json; proxy["durationSec"] = media.videoRange.duration.seconds
            // No await between cancellation/revision check and atomic publication.
            let saved = try store.locked {
                try worker.cancellation.check()
                var json: BJJJSON
                if let snapshot {
                    let current = try store.load(snapshot.id)
                    guard current.revision == snapshot.revision else { throw BJJError.domain("PROJECT_CONFLICT", "The saved review changed during repair. Its current preview was preserved; retry after reopening.") }
                    json = current.json; json["proxy"] = proxy
                } else {
                    let now = BJJProject.now()
                    let title = String(URL(fileURLWithPath: originalName).deletingPathExtension().lastPathComponent.prefix(160)).trimmingCharacters(in: .whitespacesAndNewlines)
                    json = ["schemaVersion": 1, "projectId": job.projectId, "projectName": title.isEmpty ? "Rolling review" : title,
                            "requiredCapabilities": BJJColor.isHDR(media.json) ? [BJJColor.capability] : [String](),
                            "createdAt": now, "updatedAt": now, "source": media.json, "proxy": proxy,
                            "settings": ["defaultAnnotationDuration": 5.0, "seekStepSec": 0.1, "largeSeekStepSec": 1.0, "originalAudioGain": 1.0, "originalAudioMuted": false, "voiceoverMasterGain": 1.0],
                            "exportSettings": ["fps": min(60, media.fps), "crf": 23, "preset": "medium"], "annotations": [BJJJSON](), "voiceovers": [BJJJSON]()]
                }
                try FileManager.default.moveItem(at: temporary, to: candidate)
                return try store.save(BJJProject(json), creating: snapshot == nil, replacingProxy: snapshot != nil)
            }
            try update(id) { $0.status = "completed"; $0.stage = "ready"; $0.progress = 1; $0.projectRevision = saved.revision }
            return saved
        }
    }
}
