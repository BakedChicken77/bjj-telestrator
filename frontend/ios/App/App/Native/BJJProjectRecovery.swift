import Foundation

extension BJJStore {
    func recoveryDirectory(_ id: String) throws -> URL {
        let result = try directory(id).appendingPathComponent("recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return result
    }
    func writeDraft(_ value: BJJJSON) throws {
        let project = try BJJProject(BJJValidate.object(value["project"], "recovery project"))
        let writer = try BJJValidate.uuid(value["writerId"])
        try BJJValidate.uuid(value["draftId"])
        _ = try load(project.id)
        try writeJSON(value, to: recoveryDirectory(project.id).appendingPathComponent("\(writer).json"))
    }
    func recoveryDrafts(_ id: String) throws -> [BJJJSON] {
        let directory = try recoveryDirectory(id)
        let paths = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return paths.filter { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }.map { path in
            do { return try readJSON(path) }
            catch { return ["corrupt": true, "writerId": path.deletingPathExtension().lastPathComponent] }
        }
    }
    func clearDraft(_ id: String, writer: String, draft: String) throws {
        try BJJValidate.uuid(writer); try BJJValidate.uuid(draft)
        let path = try recoveryDirectory(id).appendingPathComponent("\(writer).json")
        if FileManager.default.fileExists(atPath: path.path), try readJSON(path)["draftId"] as? String == draft {
            try FileManager.default.removeItem(at: path)
        }
    }
    func recoverCopy(_ draft: BJJProject, suffix: String = " (recovered copy)", sourceStore: BJJStore? = nil) throws -> BJJProject {
        try locked { try copyReview(draft, suffix: suffix, sourceStore: sourceStore ?? self) }
    }
    private func copyReview(_ draft: BJJProject, suffix: String, sourceStore: BJJStore) throws -> BJJProject {
        let original = try sourceStore.load(draft.id)
        for field in ["source", "proxy", "createdAt"] {
            guard NSDictionary(dictionary: ["value": draft.json[field]!]).isEqual(to: ["value": original.json[field]!]) else {
                throw BJJError.invalid("Recovery cannot change imported media metadata.")
            }
        }
        let registry = try sourceStore.recordings(draft.id)
        for clip in draft.voiceovers {
            guard let registered = registry[clip["id"] as! String] as? BJJJSON else { throw BJJError.invalid("Unknown recovery recording.") }
            for field in ["id", "asset", "durationSec", "recordedAt", "codec", "sampleRate", "channels"] {
                guard NSDictionary(dictionary: ["value": clip[field]!]).isEqual(to: ["value": registered[field]!]) else {
                    throw BJJError.invalid("Recorded media metadata cannot be changed.")
                }
            }
        }
        let entries = try BJJAssets.manifest(sourceStore, draft, proxy: true)
        let bytes = entries.reduce(Int64(0)) { $0 + ($1["byteSize"] as! NSNumber).int64Value }
        let estimate = BJJAssets.estimate("duplicate", output: 0, incoming: bytes)
        try checkSpace(required: (estimate["requiredBytes"] as! NSNumber).int64Value)
        let hashes = Dictionary(uniqueKeysWithValues: entries.map { ($0.s("reference"), $0.s("sha256")) })
        func copyAsset(_ reference: String, to target: URL) throws {
            let source = try BJJAssets.file(sourceStore, draft.id, reference)
            try FileManager.default.copyItem(at: source, to: target)
            guard try BJJAssets.digest(target) == hashes[reference], try BJJAssets.digest(source) == hashes[reference] else {
                throw BJJError.domain("ASSET_CHANGED", "A copied asset failed checksum verification. The original was preserved.")
            }
        }
        let (id, folder) = try createDirectory()
        do {
            var mapping = [draft.id: id]
            for object in draft.annotations + draft.voiceovers { mapping[object["id"] as! String] = UUID().uuidString.lowercased() }
            let literalFields: Set<String> = ["text", "projectName", "originalFilename"]
            func remap(_ value: Any) -> Any {
                if let text = value as? String { return mapping[text] ?? text }
                if let array = value as? [Any] { return array.map(remap) }
                if let object = value as? BJJJSON {
                    // User content is literal even when it equals an object UUID.
                    return object.reduce(into: BJJJSON()) { result, entry in
                        result[entry.key] = literalFields.contains(entry.key) ? entry.value : remap(entry.value)
                    }
                }
                return value
            }
            var json = remap(draft.json) as! BJJJSON
            json["revision"] = 1
            json["createdAt"] = BJJProject.now(); json["updatedAt"] = BJJProject.now()
            json["projectName"] = String(draft.name.prefix(160 - suffix.count)) + suffix
            for media in [draft.source, draft.proxy] {
                let ref = media["asset"] as! String
                let target = folder.appendingPathComponent(ref)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try copyAsset(ref, to: target)
            }
            var clips = json["voiceovers"] as! [BJJJSON]
            var newRegistry: BJJJSON = [:]
            for index in clips.indices {
                let ref = "voiceover/\(clips[index]["id"] as! String).wav"
                try copyAsset(draft.voiceovers[index]["asset"] as! String, to: folder.appendingPathComponent(ref))
                clips[index]["asset"] = ref
                newRegistry[clips[index]["id"] as! String] = clips[index]
            }
            json["voiceovers"] = clips
            try writeJSON(newRegistry, to: folder.appendingPathComponent("voiceover/assets.json"))
            return try save(BJJProject(json), creating: true)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }
}
