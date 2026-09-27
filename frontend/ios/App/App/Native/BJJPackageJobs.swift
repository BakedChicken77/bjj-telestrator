import Foundation
import UIKit

@MainActor enum BJJPackageInbox {
    nonisolated static let changed = Notification.Name("BJJPackageOpened")
    private static var pending: (URL, Bool)?
    static var available: Bool { pending != nil }
    static func receive(_ url: URL) {
        guard url.isFileURL, url.pathExtension.lowercased() == "bjjproj" else { return }
        discard()
        pending = (url, url.startAccessingSecurityScopedResource())
        NotificationCenter.default.post(name: changed, object: nil)
    }
    static func take() -> (URL, Bool)? { defer { pending = nil }; return pending }
    static func discard() {
        if let (url, scoped) = pending, scoped { url.stopAccessingSecurityScopedResource() }
        pending = nil
    }
}

struct BJJPackageJob: Codable {
    let jobId: String
    let projectId: String
    let operation: String
    let includeProxy: Bool
    let createdAt: String
    var projectRevision: Int?
    var status = "queued", stage = "inspecting"
    var progress: Double?
    var cancelRequested = false
    var errorCode: String?, error: String?
    var terminal: Bool { ["completed", "failed", "cancelled"].contains(status) }
    func json() throws -> BJJJSON {
        var result = try BJJValidate.object(JSONSerialization.jsonObject(with: JSONEncoder().encode(self)), "package job")
        result["progress"] = progress.map { $0 as Any } ?? NSNull()
        result["projectRevision"] = projectRevision.map { $0 as Any } ?? NSNull()
        return result
    }
}

@MainActor final class BJJPackageJobs {
    let store: BJJStore
    let root: URL
    let limits: BJJPackageLimits
    private var jobs: [String: BJJPackageJob] = [:]
    private var workers: [String: BJJPackageWork] = [:]
    private var readers: [String: Int] = [:]
    var activityChanged: (() -> Void)?
    var active: Bool { jobs.values.contains { $0.status == "running" } }
    init(store: BJJStore, limits: BJJPackageLimits = BJJPackageLimits()) throws {
        self.store = store; self.limits = limits
        root = store.root.appendingPathComponent("package-jobs", isDirectory: true)
        guard (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw BJJError.domain("ASSET_UNSAFE", "Package storage cannot be a symbolic link.") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        for folder in folders.prefix(1024) {
            do {
                let id = try BJJValidate.uuid(folder.lastPathComponent), file = try path(id, "job.json")
                guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 65536 else { continue }
                var job = try JSONDecoder().decode(BJJPackageJob.self, from: Data(contentsOf: file))
                try BJJValidate.uuid(job.projectId)
                guard job.jobId == id, ["backup", "restore"].contains(job.operation), jobs.count < 64 else { continue }
                if !job.terminal, let receipt = try? path(id, "completed.json"),
                   let size = try? receipt.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 65536,
                   let bytes = try? Data(contentsOf: receipt),
                   let final = try? JSONDecoder().decode(BJJPackageJob.self, from: bytes), final.jobId == id,
                   final.projectId == job.projectId, final.operation == job.operation, final.status == "completed" {
                    job = final
                }
                if !job.terminal {
                    job.status = "failed"; job.errorCode = "PACKAGE_INTERRUPTED"
                    job.error = "Package work was interrupted. Existing projects were preserved; start the operation again."
                    if job.operation == "restore", let marker = try? store.readJSON(store.safeURL(job.projectId, "restore-job.json")),
                       marker["jobId"] as? String == id, let project = try? store.load(job.projectId) {
                        job.status = "completed"; job.stage = "ready"; job.progress = 1
                        job.projectRevision = project.revision; job.errorCode = nil; job.error = nil
                    }
                    try persist(job)
                    for name in ["staging", "incoming.partial", "backup.partial"] {
                        try? FileManager.default.removeItem(at: path(id, name))
                    }
                }
                jobs[id] = job; workers[id] = BJJPackageWork()
            } catch { continue }
        }
    }
    func path(_ id: String, _ name: String) throws -> URL {
        try BJJValidate.uuid(id)
        guard ["job.json", "completed.json", "input.json", "staging", "incoming.partial", "incoming.bjjproj", "backup.partial", "backup.bjjproj"].contains(name) else { throw BJJError.invalid("Unknown package asset.") }
        let folder = root.appendingPathComponent(id, isDirectory: true), result = folder.appendingPathComponent(name)
        for url in [root, folder, result] {
            guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw BJJError.domain("ASSET_UNSAFE", "Symbolic links are not supported for package work.") }
        }
        return result
    }
    private func persist(_ job: BJJPackageJob) throws {
        try store.writeJSON(job.json(), to: path(job.jobId, "job.json"))
    }
    private func update(_ id: String, _ change: (inout BJJPackageJob) -> Void) throws {
        guard var job = jobs[id] else { throw BJJError.domain("PACKAGE_MISSING", "This package operation is unavailable.") }
        change(&job)
        if job.status == "completed" {
            try store.writeJSON(job.json(), to: path(id, "completed.json"))
            jobs[id] = job; activityChanged?(); try? persist(job)
        } else { jobs[id] = job; activityChanged?(); try persist(job) }
    }
    func get(_ id: String) throws -> BJJJSON {
        try BJJValidate.uuid(id)
        guard let job = jobs[id] else { throw BJJError.domain("PACKAGE_MISSING", "This package operation is unavailable.") }
        var json = try job.json()
        if job.status == "running", let worker = workers[id] { json.merge(worker.state()) { _, new in new } }
        return json
    }
    func list() throws -> [BJJJSON] { try jobs.keys.sorted().map(get) }
    func create(operation: String, requestId: String, projectId: String? = nil, revision: Int? = nil, includeProxy: Bool = false) throws -> BJJJSON {
        try BJJValidate.uuid(requestId)
        if let previous = jobs[requestId] {
            guard previous.operation == operation, operation != "backup" || (previous.projectId == projectId && previous.projectRevision == revision && previous.includeProxy == includeProxy) else { throw BJJError.domain("PROJECT_CONFLICT", "This request identifier already belongs to another operation.") }
            return try get(requestId)
        }
        guard ["backup", "restore"].contains(operation), jobs.count < 64,
              jobs.values.filter({ !$0.terminal }).count < 2 else { throw BJJError.domain("PACKAGE_LIMIT", "Finish or remove an older package operation before starting another.") }
        let folder = try path(requestId, "job.json").deletingLastPathComponent()
        guard !FileManager.default.fileExists(atPath: folder.path) else { throw BJJError.domain("PROJECT_CONFLICT", "This package request already has retained files. Start another operation.") }
        var project: BJJProject?
        if operation == "backup" {
            project = try store.locked {
                guard let projectId else { throw BJJError.invalid("Choose a project to back up.") }
                let project = try store.loadRecoveringRecordings(projectId)
                guard project.revision == revision else { throw BJJError.domain("PROJECT_CONFLICT", "The project changed. Save or reopen it before backup.") }
                try store.acquireLease(projectId); return project
            }
        }
        var created = false
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            created = true
            let id = project?.id ?? UUID().uuidString.lowercased()
            var job = BJJPackageJob(jobId: requestId, projectId: id, operation: operation, includeProxy: includeProxy,
                                    createdAt: BJJProject.now(), projectRevision: project?.revision)
            job.stage = project == nil ? "copying" : "inspecting"
            if let project { try store.writeJSON(project.json, to: path(requestId, "input.json")) }
            jobs[requestId] = job; workers[requestId] = BJJPackageWork(); try persist(job)
            if let project { Task { [self] in await runBackup(requestId, project: project) } }
            return try get(requestId)
        } catch {
            if let project { store.releaseLease(project.id) }
            jobs.removeValue(forKey: requestId); workers.removeValue(forKey: requestId)
            if created { try? FileManager.default.removeItem(at: folder) }
            throw error
        }
    }
    private func fail(_ id: String, _ error: Error) {
        guard jobs[id]?.status != "completed", let worker = workers[id] else { return }
        let cancelled: Bool
        do { try worker.cancellation.check(); cancelled = (error as? BJJError)?.code == "JOB_CANCELLED" } catch { cancelled = true }
        let low = (error as NSError).domain == NSCocoaErrorDomain && (error as NSError).code == NSFileWriteOutOfSpaceError
        try? update(id) { job in
            job.status = cancelled ? "cancelled" : "failed"
            job.errorCode = cancelled ? "JOB_CANCELLED" : low ? "STORAGE_LOW" : (error as? BJJError)?.code ?? "PACKAGE_FAILED"
            job.error = cancelled ? "Package work was cancelled. Existing projects were preserved." : low ? "Not enough free storage. Existing projects were preserved." : (error as? BJJError)?.errorDescription ?? "Package work failed. Existing projects were preserved; retry with a complete backup."
        }
    }
    private func background(_ id: String) -> UIBackgroundTaskIdentifier {
        UIApplication.shared.beginBackgroundTask(withName: "BJJ project package") { [weak self] in
            Task { @MainActor in _ = try? self?.cancel(id) }
        }
    }
    private func runBackup(_ id: String, project: BJJProject) async {
        defer { store.releaseLease(project.id); activityChanged?() }
        guard let job = jobs[id], let work = workers[id] else { return }
        let background = self.background(id)
        defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }
        do {
            let temporary = try path(id, "backup.partial")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try update(id) { $0.status = "running" }
            try await BJJAssets.offMain { [store, limits] in
                try BJJProjectPackage.backup(store, project: project, output: temporary, includeProxy: job.includeProxy, work: work, limits: limits)
            }
            try work.cancellation.check()
            try FileManager.default.moveItem(at: temporary, to: path(id, "backup.bjjproj"))
            try update(id) { $0.status = "completed"; $0.stage = "ready"; $0.progress = 1 }
        } catch { fail(id, error) }
    }
    /// The Files picker retains security-scoped access across this bounded copy.
    func importFile(_ id: String, source: URL) async throws -> BJJJSON {
        guard let job = jobs[id], job.operation == "restore", job.status == "queued", let work = workers[id] else { throw BJJError.domain("PROJECT_CONFLICT", "This package upload is already active or finished.") }
        try update(id) { $0.status = "running"; $0.stage = "copying" }
        let background = self.background(id)
        defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) }; activityChanged?() }
        do {
            let temporary = try path(id, "incoming.partial")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try await BJJAssets.offMain { [store, limits] in
                let size = Int64(try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
                guard size > 0, size <= Int64(limits.compressed) else { throw BJJPackageArchive.invalid("The package exceeds supported transfer limits or is empty.") }
                try store.checkSpace(required: (BJJAssets.estimate("package upload", output: 0, incoming: size)["requiredBytes"] as! NSNumber).int64Value)
                let input = try FileHandle(forReadingFrom: source); defer { try? input.close() }
                guard !FileManager.default.fileExists(atPath: temporary.path), FileManager.default.createFile(atPath: temporary.path, contents: nil) else { throw BJJError.domain("STORAGE_UNAVAILABLE", "The selected package could not be staged.") }
                let output = try FileHandle(forWritingTo: temporary); defer { try? output.close() }
                var copied: Int64 = 0
                while true {
                    try work.cancellation.check()
                    let count = try autoreleasepool { () throws -> Int in
                        let data = try input.read(upToCount: Int(BJJAssets.mib)) ?? Data()
                        guard copied + Int64(data.count) <= size else { throw BJJPackageArchive.invalid("The package changed during copying.") }
                        try output.write(contentsOf: data); return data.count
                    }
                    if count == 0 { break }
                    copied += Int64(count); work.update("copying", copied, size)
                    if copied % (16 * BJJAssets.mib) < Int64(count) { try store.checkSpace(required: 100 * BJJAssets.mib) }
                }
                guard copied == size else { throw BJJPackageArchive.invalid("The package transfer is incomplete.") }
                try output.synchronize()
            }
            try work.cancellation.check()
            try FileManager.default.moveItem(at: temporary, to: path(id, "incoming.bjjproj"))
            work.update("inspecting")
            try update(id) { $0.stage = "inspecting"; $0.progress = nil }
            Task { [self] in await runRestore(id) }
            return try get(id)
        } catch { fail(id, error); throw error }
    }
    private func runRestore(_ id: String) async {
        guard let job = jobs[id], let work = workers[id] else { return }
        let background = self.background(id)
        defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) }; activityChanged?() }
        do {
            _ = try await BJJProjectPackage.restore(store, source: path(id, "incoming.bjjproj"), staging: path(id, "staging"), id: job.projectId, work: work, limits: limits) { [self] folder, project in
                try store.writeJSON(["version": 1, "jobId": id], to: folder.appendingPathComponent("restore-job.json"))
                let restored = try BJJProjectPackage.install(store, folder: folder, project: project, work: work)
                try update(id) { $0.projectRevision = restored.revision; $0.status = "completed"; $0.stage = "ready"; $0.progress = 1 }
                return restored
            }
        } catch { fail(id, error) }
    }
    func cancel(_ id: String) throws -> BJJJSON {
        _ = try get(id)
        guard let job = jobs[id], !job.terminal else { return try get(id) }
        workers[id]?.cancel(); try update(id) { $0.cancelRequested = true }
        if job.operation == "restore" && job.status == "queued" { fail(id, BJJError.cancelled) }
        return try get(id)
    }
    func acquireOutput(_ id: String) throws -> URL {
        _ = try get(id)
        guard jobs[id]?.operation == "backup", jobs[id]?.status == "completed" else { throw BJJError.domain("PACKAGE_UNAVAILABLE", "The backup is not ready to save.") }
        let file = try path(id, "backup.bjjproj")
        guard FileManager.default.fileExists(atPath: file.path) else { throw BJJError.domain("PACKAGE_MISSING", "This backup file was removed. Create another backup.") }
        readers[id, default: 0] += 1; return file
    }
    func releaseOutput(_ id: String) { readers[id] = max(0, readers[id, default: 0] - 1) }
    func remove(_ id: String) throws {
        _ = try get(id)
        guard jobs[id]!.terminal, readers[id, default: 0] == 0 else { throw BJJError.domain("PACKAGE_BUSY", "This package is in use. Finish or cancel it first.") }
        try FileManager.default.removeItem(at: path(id, "job.json").deletingLastPathComponent())
        jobs.removeValue(forKey: id); workers.removeValue(forKey: id)
    }
}
