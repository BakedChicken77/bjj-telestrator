import Foundation

/// Storage-owned version-1 checkpoint/trash records. Source and recording files
/// stay immutable; callers run hashing and copying off the main actor.
struct BJJProjectVersions {
    let store: BJJStore
    private let files = FileManager.default

    func current(_ id: String, _ revision: Int) throws -> BJJProject {
        let project = try store.loadRecoveringRecordings(id)
        guard project.revision == revision else { throw BJJError.domain("PROJECT_CONFLICT", "This project changed. Reload it before this recovery action.") }
        return project
    }
    func checkpointPath(_ id: String, _ checkpoint: String) throws -> URL {
        try BJJValidate.uuid(checkpoint)
        return try store.safeURL(id, "checkpoints/\(checkpoint).json")
    }
    private func readRecord(_ url: URL) throws -> BJJJSON {
        guard (try url.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
            throw BJJError.domain("RECOVERY_INVALID", "Symbolic links are not supported for recovery records.")
        }
        let value = try store.readJSON(url)
        try BJJValidate.number(value["version"], "recovery record version", 1...1, integer: true)
        return value
    }
    func checkpoint(_ id: String, revision: Int, label: String) throws -> BJJJSON {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.count <= 120 else { throw BJJError.invalid("Checkpoint labels must contain 1–120 characters.") }
        let project = try store.locked { () throws -> BJJProject in
            let project = try current(id, revision)
            try store.acquireLease(id)
            return project
        }
        defer { store.releaseLease(id) }
        let plan = try BJJRenderPlan(store: store, project: project)
        return try store.locked {
            _ = try current(id, revision)
            guard try checkpoints(id).count < 1000 else { throw BJJError.domain("RECOVERY_LIMIT", "This project already has 1,000 checkpoints.") }
            let identifier = UUID().uuidString.lowercased()
            var value: BJJJSON = ["version": 1, "checkpointId": identifier, "projectId": id, "revision": revision,
                                  "label": label, "createdAt": BJJProject.now(), "input": plan.json]
            let path = try checkpointPath(id, identifier)
            try files.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try store.writeJSON(value, to: path)
            value.removeValue(forKey: "input")
            return value
        }
    }
    func readCheckpoint(_ id: String, _ checkpoint: String) throws -> BJJJSON {
        let value = try readRecord(checkpointPath(id, checkpoint))
        guard value["projectId"] as? String == id, value["checkpointId"] as? String == checkpoint else {
            throw BJJError.domain("RECOVERY_INVALID", "This checkpoint belongs to another project.")
        }
        _ = try BJJValidate.string(value["label"], "checkpoint label", max: 120)
        _ = try BJJValidate.timestamp(value["createdAt"])
        _ = try BJJRenderPlan(BJJValidate.object(value["input"], "checkpoint input"), projectId: id, revision: value["revision"] as? Int)
        return value
    }
    func checkpoints(_ id: String) throws -> [BJJJSON] {
        _ = try store.load(id)
        let folder = try checkpointPath(id, UUID().uuidString.lowercased()).deletingLastPathComponent()
        guard files.fileExists(atPath: folder.path) else { return [] }
        let paths = try files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        guard paths.count <= 1000 else { throw BJJError.domain("RECOVERY_LIMIT", "This project exceeds the supported 1,000 checkpoints.") }
        return try paths.map { path in
            var value = try readCheckpoint(id, path.deletingPathExtension().lastPathComponent)
            value.removeValue(forKey: "input")
            return value
        }.sorted { ($0.s("createdAt"), $0.s("checkpointId")) > ($1.s("createdAt"), $1.s("checkpointId")) }
    }
    func restoreCheckpoint(_ id: String, checkpoint: String, revision: Int) throws -> BJJProject {
        try store.locked { _ = try current(id, revision); try store.acquireLease(id) }
        defer { store.releaseLease(id) }
        let value = try readCheckpoint(id, checkpoint)
        let plan = try BJJRenderPlan(BJJValidate.object(value["input"], "checkpoint input"), projectId: id, revision: value["revision"] as? Int)
        try plan.verify(store)
        _ = try self.checkpoint(id, revision: revision, label: "Before restoring " + String(value.s("label").prefix(100)))
        return try store.locked {
            let previous = try current(id, revision)
            var json = plan.project.json
            for field in ["projectId", "revision", "createdAt", "source", "proxy"] { json[field] = previous.json[field] }
            return try store.save(BJJProject(json))
        }
    }
    func duplicate(_ id: String, revision: Int) throws -> BJJProject {
        try store.locked { try store.recoverCopy(current(id, revision), suffix: " (copy)") }
    }
    func trashRoot() throws -> URL {
        let path = store.root.appendingPathComponent("recently-deleted", isDirectory: true)
        try rejectLink(path)
        return path
    }
    func trashEntry(_ id: String) throws -> URL {
        try BJJValidate.uuid(id)
        let path = try trashRoot().appendingPathComponent(id, isDirectory: true)
        try rejectLink(path)
        return path
    }
    private func rejectLink(_ url: URL) throws {
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw BJJError.domain("ASSET_UNSAFE", "Symbolic links are not supported for project recovery.")
        }
    }
    func trash(_ id: String, revision: Int) throws {
        try store.locked {
            let project = try current(id, revision)
            try store.requireUnleased(id)
            let identifier = UUID().uuidString.lowercased(), entry = try trashEntry(identifier)
            let target = entry.appendingPathComponent("projects/\(id)", isDirectory: true)
            try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try store.writeJSON(["version": 1, "trashId": identifier, "projectId": id, "projectName": project.name,
                                 "revision": revision, "deletedAt": BJJProject.now()], to: entry.appendingPathComponent("metadata.json"))
            // One same-volume rename preserves the whole project, checkpoints and
            // export inputs. Metadata precedes the move so interruption is recoverable.
            try files.moveItem(at: store.directory(id), to: target)
        }
    }
    func readTrash(_ id: String) throws -> (BJJJSON, URL) {
        let entry = try trashEntry(id), value = try readRecord(entry.appendingPathComponent("metadata.json"))
        guard value["trashId"] as? String == id else { throw BJJError.domain("RECOVERY_INVALID", "The deleted project identity differs from its storage.") }
        let projectId = try BJJValidate.uuid(value["projectId"] as? String)
        _ = try BJJValidate.string(value["projectName"], "project name", max: 160)
        _ = try BJJValidate.timestamp(value["deletedAt"])
        let projects = entry.appendingPathComponent("projects", isDirectory: true), folder = projects.appendingPathComponent(projectId, isDirectory: true)
        try rejectLink(projects); try rejectLink(folder)
        guard files.fileExists(atPath: folder.path) else { throw CocoaError(.fileReadNoSuchFile) }
        return (value, folder)
    }
    func deleted() throws -> [BJJJSON] {
        let root = try trashRoot()
        guard files.fileExists(atPath: root.path) else { return [] }
        let paths = try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        guard paths.count <= 1000 else { throw BJJError.domain("RECOVERY_LIMIT", "This workspace exceeds the supported 1,000 deleted projects.") }
        var values: [BJJJSON] = []
        for path in paths {
            do { values.append(try readTrash(path.lastPathComponent).0) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { continue }
        }
        return values.sorted { ($0.s("deletedAt"), $0.s("trashId")) > ($1.s("deletedAt"), $1.s("trashId")) }
    }
    func restoreDeleted(_ id: String) throws -> (BJJProject, Bool) {
        try store.locked {
            let (value, folder) = try readTrash(id)
            let archived = try BJJStore(root: folder.deletingLastPathComponent())
            let project = try archived.load(value.s("projectId"))
            try archived.validateRecordings(project)
            let plan = try BJJRenderPlan(store: archived, project: project)
            try plan.verify(archived)
            _ = try BJJAssets.manifest(archived, project, proxy: true)
            let target = try store.directory(project.id)
            if files.fileExists(atPath: target.path) {
                // Keep the complete deleted folder; this new copy contains only
                // the current review and required media with fresh editable IDs.
                return (try store.recoverCopy(project, sourceStore: archived), true)
            }
            try files.moveItem(at: folder, to: target)
            try? files.removeItem(at: trashEntry(id))
            return (try store.load(project.id), false)
        }
    }
    func permanentlyDelete(_ id: String) throws {
        try store.locked {
            _ = try readTrash(id)
            try files.removeItem(at: trashEntry(id))
        }
    }
}
