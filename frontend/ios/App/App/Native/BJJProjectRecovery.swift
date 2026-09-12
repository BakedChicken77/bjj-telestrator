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
    func recoverCopy(_ draft: BJJProject) throws -> BJJProject {
        let original = try load(draft.id)
        for field in ["source", "proxy", "createdAt"] {
            guard NSDictionary(dictionary: ["value": draft.json[field]!]).isEqual(to: ["value": original.json[field]!]) else {
                throw BJJError.invalid("Recovery cannot change imported media metadata.")
            }
        }
        let registry = try recordings(draft.id)
        for clip in draft.voiceovers {
            guard let registered = registry[clip["id"] as! String] as? BJJJSON else { throw BJJError.invalid("Unknown recovery recording.") }
            for field in ["id", "asset", "durationSec", "recordedAt", "codec", "sampleRate", "channels"] {
                guard NSDictionary(dictionary: ["value": clip[field]!]).isEqual(to: ["value": registered[field]!]) else {
                    throw BJJError.invalid("Recorded media metadata cannot be changed.")
                }
            }
        }
        let refs = Set([draft.source["asset"] as! String, draft.proxy["asset"] as! String] + draft.voiceovers.map { $0["asset"] as! String })
        var bytes: Int64 = 32 * 1024 * 1024
        for ref in refs { bytes += Int64(try asset(draft.id, ref).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        try checkSpace(required: bytes)
        let (id, folder) = try createDirectory()
        do {
            var mapping = [draft.id: id]
            for object in draft.annotations + draft.voiceovers { mapping[object["id"] as! String] = UUID().uuidString.lowercased() }
            func remap(_ value: Any) -> Any {
                if let text = value as? String { return mapping[text] ?? text }
                if let array = value as? [Any] { return array.map(remap) }
                if let object = value as? BJJJSON { return object.mapValues(remap) }
                return value
            }
            var json = remap(draft.json) as! BJJJSON
            json["revision"] = 1
            json["createdAt"] = BJJProject.now(); json["updatedAt"] = BJJProject.now()
            json["projectName"] = String(draft.name.prefix(142)) + " (recovered copy)"
            for media in [draft.source, draft.proxy] {
                let ref = media["asset"] as! String
                let target = folder.appendingPathComponent(ref)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: asset(draft.id, ref), to: target)
            }
            var clips = json["voiceovers"] as! [BJJJSON]
            var newRegistry: BJJJSON = [:]
            for index in clips.indices {
                let ref = "voiceover/\(clips[index]["id"] as! String).wav"
                try FileManager.default.copyItem(at: asset(draft.id, draft.voiceovers[index]["asset"] as! String), to: folder.appendingPathComponent(ref))
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
