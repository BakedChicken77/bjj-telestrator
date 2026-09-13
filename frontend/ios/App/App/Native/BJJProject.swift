import Foundation
import CoreFoundation

// The complete JSON document is retained so additive future fields survive an edit.
typealias BJJJSON = [String: Any]

enum BJJError: LocalizedError {
    case invalid(String)
    case domain(String, String)
    case cancelled
    var code: String {
        switch self {
        case .domain(let code, _): return code
        case .cancelled: return "JOB_CANCELLED"
        case .invalid: return "PROJECT_INVALID"
        }
    }
    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .domain(_, let message): return message
        case .cancelled: return "The operation was cancelled."
        }
    }
}

enum BJJValidate {
    static func object(_ value: Any?, _ label: String) throws -> BJJJSON {
        guard let result = value as? BJJJSON else { throw BJJError.invalid("Invalid \(label).") }
        return result
    }
    static func objects(_ value: Any?, _ label: String, maximum: Int) throws -> [BJJJSON] {
        guard let result = value as? [BJJJSON], result.count <= maximum else {
            throw BJJError.invalid("Invalid or excessive \(label).")
        }
        return result
    }
    @discardableResult static func number(_ value: Any?, _ label: String, _ range: ClosedRange<Double>, integer: Bool = false) throws -> Double {
        guard let result = value as? NSNumber, CFGetTypeID(result) != CFBooleanGetTypeID(),
              result.doubleValue.isFinite, range.contains(result.doubleValue),
              !integer || result.doubleValue.rounded() == result.doubleValue else {
            throw BJJError.invalid("\(label) is outside its valid range.")
        }
        return result.doubleValue
    }
    @discardableResult static func string(_ value: Any?, _ label: String, max: Int = 2000) throws -> String {
        guard let result = value as? String, !result.isEmpty, result.count <= max else {
            throw BJJError.invalid("Invalid \(label).")
        }
        return result
    }
    @discardableResult static func uuid(_ value: Any?) throws -> String {
        let result = try string(value, "identifier", max: 36)
        guard UUID(uuidString: result)?.uuidString.lowercased() == result else {
            throw BJJError.invalid("Invalid resource identifier.")
        }
        return result
    }
    static func bool(_ value: Any?, _ label: String) throws {
        guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else {
            throw BJJError.invalid("Invalid \(label).")
        }
    }
    static func timestamp(_ value: Any?) throws {
        let text = try string(value, "timestamp", max: 80)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if formatter.date(from: text) == nil {
            formatter.formatOptions = [.withInternetDateTime]
            guard formatter.date(from: text) != nil else { throw BJJError.invalid("Invalid timestamp.") }
        }
    }
    static func color(_ value: Any?) throws {
        let text = try string(value, "color", max: 7)
        guard text.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil else {
            throw BJJError.invalid("Colors must use #RRGGBB.")
        }
    }
    @discardableResult static func asset(_ value: Any?) throws -> String {
        let text = try string(value, "asset reference", max: 250)
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard !text.contains("\\"), !text.contains(":"), !text.contains("\0"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw BJJError.invalid("Unsafe asset reference.")
        }
        return text
    }
    static func media(_ m: BJJJSON) throws {
        try asset(m["asset"])
        try string(m["originalFilename"], "filename", max: 240)
        try number(m["durationSec"], "duration", 0.001...86400)
        for field in ["codedWidth", "codedHeight", "displayWidth", "displayHeight"] {
            try number(m[field], field, 1...32768, integer: true)
        }
        try number(m["rotation"], "rotation", -360...360)
        try number(m["avgFrameRate"], "frame rate", 0.001...1000)
        try bool(m["hasAudio"], "audio flag")
        for field in ["codec", "sampleAspectRatio", "displayAspectRatio"] { try string(m[field], field, max: 100) }
        if !(m["audioCodec"] is NSNull) { try string(m["audioCodec"], "audio codec", max: 100) }
        for key in ["transferFunction", "colorPrimaries", "colorMatrix", "colorRange", "averageFrameRateRational", "nominalFrameRateRational", "timeBase"] {
            if let value = m[key], !(value is NSNull) { try string(value, key, max: 100) }
        }
        if let value = m["dolbyVision"], !(value is NSNull) { try bool(value, "Dolby Vision flag") }
    }
}

struct BJJProject {
    let json: BJJJSON
    var id: String { json["projectId"] as! String }
    var revision: Int { (json["revision"] as! NSNumber).intValue }
    var name: String { json["projectName"] as! String }
    var source: BJJJSON { json["source"] as! BJJJSON }
    var proxy: BJJJSON { json["proxy"] as! BJJJSON }
    var settings: BJJJSON { json["settings"] as! BJJJSON }
    var exportSettings: BJJJSON { json["exportSettings"] as! BJJJSON }
    var duration: Double { (source["durationSec"] as! NSNumber).doubleValue }
    var annotations: [BJJJSON] { json["annotations"] as! [BJJJSON] }
    var voiceovers: [BJJJSON] { json["voiceovers"] as! [BJJJSON] }

    init(_ document: BJJJSON) throws {
        let value = try BJJProjectMigrations.migrate(document)
        try BJJValidate.number(value["revision"], "project revision", 1...9007199254740991, integer: true)
        try BJJValidate.uuid(value["projectId"])
        let name = try BJJValidate.string(value["projectName"], "project name", max: 160)
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BJJError.invalid("Enter a project name.") }
        try BJJValidate.timestamp(value["createdAt"])
        try BJJValidate.timestamp(value["updatedAt"])
        let source = try BJJValidate.object(value["source"], "source")
        try BJJValidate.media(source)
        if BJJColor.isHDR(source) && !(value["requiredCapabilities"] as! [String]).contains(BJJColor.capability) {
            throw BJJError.invalid("The HDR delivery capability is missing.")
        }
        try BJJValidate.media(BJJValidate.object(value["proxy"], "proxy"))
        let duration = (source["durationSec"] as! NSNumber).doubleValue
        let settings = try BJJValidate.object(value["settings"], "settings")
        try BJJValidate.number(settings["defaultAnnotationDuration"], "default duration", 0.001...3600)
        try BJJValidate.number(settings["seekStepSec"], "seek step", 0.001...60)
        try BJJValidate.number(settings["largeSeekStepSec"], "large seek step", 0.001...3600)
        try BJJValidate.number(settings["originalAudioGain"], "original gain", 0...2)
        try BJJValidate.number(settings["voiceoverMasterGain"], "voiceover gain", 0...2)
        try BJJValidate.bool(settings["originalAudioMuted"], "original mute")
        let exportSettings = try BJJValidate.object(value["exportSettings"], "export settings")
        try BJJValidate.number(exportSettings["fps"], "export frame rate", 0.01...120)
        try BJJValidate.number(exportSettings["crf"], "quality", 0...40, integer: true)
        let preset = try BJJValidate.string(exportSettings["preset"], "encoding preset", max: 30)
        guard ["ultrafast", "superfast", "veryfast", "faster", "fast", "medium", "slow", "slower", "veryslow"].contains(preset) else {
            throw BJJError.invalid("Invalid encoding preset.")
        }
        var ids = Set<String>()
        for a in try BJJValidate.objects(value["annotations"], "annotations", maximum: 2000) {
            let id = try BJJValidate.uuid(a["id"])
            guard ids.insert(id).inserted else { throw BJJError.invalid("Duplicate annotation identifier.") }
            let start = try BJJValidate.number(a["startSec"], "annotation start", 0...duration)
            let end = try BJJValidate.number(a["endSec"], "annotation end", 0...duration)
            guard start < end else { throw BJJError.invalid("Annotation end must follow its start.") }
            try BJJValidate.number(a["zIndex"], "layer", 0...100000, integer: true)
            try BJJValidate.number(a["strokeWidth"], "stroke width", 0.000001...0.1)
            for field in ["strokeOpacity", "fillOpacity"] { try BJJValidate.number(a[field], field, 0...1) }
            for field in ["strokeColor", "fillColor"] { try BJJValidate.color(a[field]) }
            try BJJValidate.timestamp(a["createdAt"])
            try BJJValidate.timestamp(a["updatedAt"])
            let g = try BJJValidate.object(a["geometry"], "geometry")
            let type = try BJJValidate.string(a["type"], "annotation type", max: 20)
            func n(_ key: String) throws -> Double { try BJJValidate.number(g[key], key, 0...1) }
            switch type {
            case "line", "arrow":
                for field in ["x1", "y1", "x2", "y2"] { _ = try n(field) }
                if type == "arrow" { try BJJValidate.number(g["arrowheadSize"], "arrowhead", 0.000001...0.5) }
            case "rectangle":
                let x = try n("x"), y = try n("y"), w = try n("width"), h = try n("height")
                guard w > 0, h > 0, x + w <= 1.000001, y + h <= 1.000001 else { throw BJJError.invalid("Rectangle must fit inside the video.") }
            case "ellipse":
                let x = try n("centerX"), y = try n("centerY"), rx = try n("radiusX"), ry = try n("radiusY")
                guard rx > 0, ry > 0, x - rx >= -0.000001, y - ry >= -0.000001,
                      x + rx <= 1.000001, y + ry <= 1.000001 else { throw BJJError.invalid("Ellipse must fit inside the video.") }
            case "freehand":
                let points = try BJJValidate.objects(g["points"], "freehand points", maximum: 20000)
                guard points.count >= 2 else { throw BJJError.invalid("A freehand path needs two points.") }
                for p in points { try BJJValidate.number(p["x"], "point x", 0...1); try BJJValidate.number(p["y"], "point y", 0...1) }
                try BJJValidate.number(g["smoothing"], "smoothing", 0...0)
            case "text":
                _ = try n("x"); _ = try n("y")
                try BJJValidate.string(g["text"], "text")
                try BJJValidate.number(g["fontSize"], "font size", 0.000001...0.5)
                let alignment = try BJJValidate.string(g["alignment"], "alignment", max: 10)
                guard ["left", "center", "right"].contains(alignment) else { throw BJJError.invalid("Invalid text alignment.") }
                try BJJValidate.color(g["backgroundColor"])
                try BJJValidate.number(g["backgroundOpacity"], "text background opacity", 0...1)
            default: throw BJJError.invalid("Unsupported annotation type: \(type).")
            }
        }
        for clip in try BJJValidate.objects(value["voiceovers"], "voiceovers", maximum: 200) {
            let id = try BJJValidate.uuid(clip["id"])
            guard ids.insert(id).inserted else { throw BJJError.invalid("Duplicate clip identifier.") }
            try BJJValidate.asset(clip["asset"])
            let start = try BJJValidate.number(clip["startSec"], "clip start", 0...duration)
            let length = try BJJValidate.number(clip["durationSec"], "clip duration", 0.001...duration)
            let end = try BJJValidate.number(clip["endSec"], "clip end", 0.001...(duration + 60))
            let offset = try BJJValidate.number(clip["timingOffsetMs"], "timing offset", -60000...60000) / 1000
            guard abs(end - start - length) < 0.001, start + offset >= 0, end + offset <= duration + 0.001 else {
                throw BJJError.invalid("Voiceover must fit the video timeline.")
            }
            try BJJValidate.number(clip["gain"], "clip gain", 0...2)
            try BJJValidate.bool(clip["muted"], "clip mute")
            try BJJValidate.timestamp(clip["recordedAt"])
            try BJJValidate.string(clip["codec"], "clip codec", max: 50)
            try BJJValidate.number(clip["sampleRate"], "sample rate", 1...384000, integer: true)
            try BJJValidate.number(clip["channels"], "channels", 1...8, integer: true)
        }
        json = value
    }

    func summary() -> BJJJSON {
        ["projectId": id, "projectName": name, "updatedAt": json["updatedAt"]!,
         "durationSec": duration, "annotationCount": annotations.count, "revision": revision]
    }
    static func now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
    static func visible(_ annotation: BJJJSON, time: Double, fps: Double) -> Bool {
        // Round every boundary up to the first output frame at or after it.
        let frame = (time * fps + 0.00001).rounded(.down)
        let start = ((annotation["startSec"] as! NSNumber).doubleValue * fps - 0.000001).rounded(.up)
        let end = ((annotation["endSec"] as! NSNumber).doubleValue * fps - 0.000001).rounded(.up)
        return frame >= start && frame < end
    }
}

final class BJJStore {
    let root: URL
    private let writeFile: (Data, URL) throws -> Void
    private let lock = NSRecursiveLock()
    let assetLock = NSLock()
    private var leases: [String: Int] = [:]

    func acquireLease(_ id: String) throws {
        lock.lock(); defer { lock.unlock() }
        _ = try load(id)
        leases[id, default: 0] += 1
    }
    func releaseLease(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        leases[id] = max(0, leases[id, default: 0] - 1)
    }
    init(root: URL? = nil, writeFile: @escaping (Data, URL) throws -> Void = { data, url in try data.write(to: url, options: .atomic) }) throws {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BJJTelestrator/projects", isDirectory: true)
        self.writeFile = writeFile
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }
    func directory(_ id: String) throws -> URL {
        try BJJValidate.uuid(id)
        let directory = root.appendingPathComponent(id, isDirectory: true)
        guard (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw BJJError.domain("ASSET_UNSAFE", "Symbolic links are not supported for project directories.")
        }
        guard directory.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else {
            throw BJJError.invalid("Unsafe project directory.")
        }
        return directory
    }
    func asset(_ id: String, _ reference: String) throws -> URL {
        let url = try safeURL(id, reference)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BJJError.domain("ASSET_MISSING", "A project media asset is missing. Restore its original file.")
        }
        return url
    }
    func safeURL(_ id: String, _ reference: String) throws -> URL {
        try BJJValidate.asset(reference)
        let directory = try directory(id).resolvingSymlinksInPath()
        var cursor = directory
        for part in reference.split(separator: "/") {
            cursor.appendPathComponent(String(part))
            if (try? cursor.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw BJJError.domain("ASSET_UNSAFE", "Symbolic links are not supported for project files.")
            }
        }
        let url = directory.appendingPathComponent(reference).resolvingSymlinksInPath()
        guard url.path.hasPrefix(directory.path + "/") else {
            throw BJJError.domain("ASSET_UNSAFE", "Unsafe project file reference.")
        }
        return url
    }
    func readJSON(_ url: URL) throws -> BJJJSON {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size < 32 * 1024 * 1024 else { throw BJJError.invalid("Project metadata exceeds 32 MiB.") }
        return try BJJValidate.object(JSONSerialization.jsonObject(with: Data(contentsOf: url)), "project JSON")
    }
    func writeJSON(_ json: BJJJSON, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        guard data.count < 32 * 1024 * 1024 else { throw BJJError.invalid("Project metadata exceeds 32 MiB. Reduce annotation points or the number of objects.") }
        try writeFile(data, url)
    }
    func load(_ id: String) throws -> BJJProject {
        lock.lock(); defer { lock.unlock() }
        try finishSaveTransaction(id)
        let url = try directory(id).appendingPathComponent("project.json")
        var json = try readJSON(url)
        let validated = try BJJProject(json)
        guard validated.id == id else { throw BJJError.domain("PROJECT_CORRUPT", "The project identifier does not match its storage.") }
        if (json["schemaVersion"] as? Int) != BJJProjectMigrations.currentVersion {
            _ = try asset(id, validated.source["asset"] as! String)
            _ = try asset(id, validated.proxy["asset"] as! String)
            for clip in validated.voiceovers { _ = try asset(id, clip["asset"] as! String) }
            let backup = url.deletingLastPathComponent().appendingPathComponent("project.pre-migration-v1.json")
            let original = try Data(contentsOf: url)
            if FileManager.default.fileExists(atPath: backup.path) {
                guard try Data(contentsOf: backup) == original else {
                    throw BJJError.domain("PROJECT_CORRUPT", "The preserved migration copy differs. Restore from a verified backup.")
                }
            } else { try original.write(to: backup, options: .atomic) }
            try writeJSON(validated.json, to: url)
            json = try BJJProject(readJSON(url)).json
        } else { json = validated.json }
        return try BJJProject(json)
    }
    func loadRecoveringRecordings(_ id: String) throws -> BJJProject {
        lock.lock(); defer { lock.unlock() }
        let project = try load(id)
        // Recovery is a real storage revision, never an invisible change to an
        // existing revision. Ordinary loads/exports read only committed JSON.
        if try pendingRecordings(id).isEmpty { return project }
        return try save(project)
    }
    func list() throws -> [BJJJSON] {
        lock.lock(); defer { lock.unlock() }
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        var results: [BJJJSON] = []
        for folder in folders where UUID(uuidString: folder.lastPathComponent) != nil {
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent("project.json").path) {
                do { results.append(try load(folder.lastPathComponent).summary()) }
                catch {
                    results.append(["projectId": folder.lastPathComponent, "projectName": "Unavailable project",
                                    "updatedAt": "", "durationSec": 0, "annotationCount": 0,
                                    "unavailableCode": (error as? BJJError)?.code ?? "PROJECT_CORRUPT"])
                }
            }
        }
        return results.sorted { ($0["updatedAt"] as! String) > ($1["updatedAt"] as! String) }
    }
    func save(_ input: BJJProject, creating: Bool = false, acknowledgeRecordings: Bool = true, replacingProxy: Bool = false) throws -> BJJProject {
        lock.lock(); defer { lock.unlock() }
        let previous = creating ? nil : try load(input.id)
        if let previous, previous.revision != input.revision {
            throw BJJError.domain("PROJECT_CONFLICT", "This project changed in another session. Keep your edits as a copy or reload the saved version.")
        }
        var pending = try pendingRecordings(input.id)
        var merged = input.json
        var clips = input.voiceovers
        for (id, value) in pending {
            if clips.contains(where: { $0["id"] as? String == id }) {
                if acknowledgeRecordings { pending.removeValue(forKey: id) }
            } else if previous?.voiceovers.contains(where: { $0["id"] as? String == id }) != true {
                clips.append(try BJJValidate.object(value, "recovered recording"))
            }
            // Once this transaction publishes the take, it is no longer pending.
            // A later intentional removal must not recover it for a second time.
            if acknowledgeRecordings { pending.removeValue(forKey: id) }
        }
        merged["voiceovers"] = clips
        let project = try BJJProject(merged)
        if let previous {
            guard previous.revision == project.revision else {
                throw BJJError.domain("PROJECT_CONFLICT", "This project changed in another session. Keep your edits as a copy or reload the saved version.")
            }
            for field in replacingProxy ? ["source", "createdAt"] : ["source", "proxy", "createdAt"] {
                guard NSDictionary(dictionary: ["value": project.json[field]!]).isEqual(to: ["value": previous.json[field]!]) else {
                    throw BJJError.invalid("Imported media metadata cannot be replaced by an edit.")
                }
            }
        }
        _ = try asset(project.id, project.source["asset"] as! String)
        let proxyURL = try safeURL(project.id, project.proxy["asset"] as! String)
        // Preserve pending edits even when the unchanged derived preview is missing.
        // Creation and privileged replacement still require a validated file.
        if creating || replacingProxy || FileManager.default.fileExists(atPath: proxyURL.path) {
            _ = try asset(project.id, project.proxy["asset"] as! String)
        }
        try validateRecordings(project)
        var json = project.json
        guard creating || project.revision < 9007199254740991 else { throw BJJError.invalid("The project revision limit was reached.") }
        let target = try directory(project.id).appendingPathComponent("project.json")
        guard !creating || !FileManager.default.fileExists(atPath: target.path) else { throw BJJError.invalid("This project already exists.") }
        json["revision"] = creating ? 1 : project.revision + 1
        json["updatedAt"] = BJJProject.now()
        try writeJSON(["version": 1, "expectedRevision": previous?.revision ?? 0,
                       "project": json, "pendingRecordings": pending],
                      to: safeURL(project.id, "save-transaction.json"))
        try finishSaveTransaction(project.id)
        return try BJJProject(json)
    }
    private func finishSaveTransaction(_ id: String) throws {
        let journal = try safeURL(id, "save-transaction.json")
        guard FileManager.default.fileExists(atPath: journal.path) else { return }
        let transaction = try readJSON(journal)
        try BJJValidate.number(transaction["version"], "save transaction version", 1...1, integer: true)
        let expected = Int(try BJJValidate.number(transaction["expectedRevision"], "prior revision", 0...9007199254740990, integer: true))
        let project = try BJJProject(BJJValidate.object(transaction["project"], "save transaction project"))
        let pending = try BJJValidate.object(transaction["pendingRecordings"], "pending recordings")
        guard project.id == id, project.revision == expected + 1 else { throw BJJError.domain("PROJECT_CORRUPT", "The pending save does not match this project.") }
        let path = try safeURL(id, "project.json")
        if FileManager.default.fileExists(atPath: path.path) {
            let current = try BJJProject(readJSON(path))
            guard current.revision == expected || (current.revision == project.revision && NSDictionary(dictionary: current.json).isEqual(to: project.json)) else {
                throw BJJError.domain("PROJECT_CONFLICT", "A pending save conflicts with newer storage. Preserve this project and recover a copy.")
            }
        } else if expected != 0 { throw BJJError.domain("PROJECT_CORRUPT", "The prior document for this pending save is missing.") }
        // Replay is idempotent after either atomic write. The journal remains
        // durable until both the document and its recording receipts are stored.
        try writeJSON(project.json, to: path)
        try writeJSON(pending, to: safeURL(id, "voiceover/pending.json"))
        try FileManager.default.removeItem(at: journal)
    }
    func validateRecordings(_ project: BJJProject) throws {
        let registry = try recordings(project.id)
        for clip in project.voiceovers {
            guard let original = registry[clip["id"] as! String] as? BJJJSON else { throw BJJError.invalid("Unknown voiceover asset.") }
            for field in ["id", "asset", "durationSec", "recordedAt", "codec", "sampleRate", "channels"] {
                guard NSDictionary(dictionary: ["value": clip[field]!]).isEqual(to: ["value": original[field]!]) else {
                    throw BJJError.invalid("Recorded media metadata cannot be changed.")
                }
            }
            _ = try asset(project.id, clip["asset"] as! String)
        }
    }
    func recordings(_ id: String) throws -> BJJJSON {
        let url = try directory(id).appendingPathComponent("voiceover/assets.json")
        return FileManager.default.fileExists(atPath: url.path) ? try readJSON(url) : [:]
    }
    private func pendingRecordings(_ id: String) throws -> BJJJSON {
        let url = try directory(id).appendingPathComponent("voiceover/pending.json")
        return FileManager.default.fileExists(atPath: url.path) ? try readJSON(url) : [:]
    }
    func registerClip(_ id: String, clip: BJJJSON) throws {
        lock.lock(); defer { lock.unlock() }
        var registry = try recordings(id)
        registry[clip["id"] as! String] = clip
        try writeJSON(registry, to: directory(id).appendingPathComponent("voiceover/assets.json"))
        var pending = try pendingRecordings(id)
        pending[clip["id"] as! String] = clip
        try writeJSON(pending, to: directory(id).appendingPathComponent("voiceover/pending.json"))
        // Pending is a durable recording journal. A normal save incorporates it
        // atomically; do not advance the editor's revision behind its back.
        _ = try load(id)
    }
    func createDirectory(id: String = UUID().uuidString.lowercased()) throws -> (String, URL) {
        let url = try directory(id)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw BJJError.invalid("This project directory already exists.") }
        for folder in ["source", "proxy", "voiceover", "exports", "temp"] {
            try FileManager.default.createDirectory(at: url.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        return (id, url)
    }
    func locked<T>(_ work: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try work()
    }
    func requireUnleased(_ id: String) throws {
        try locked {
            guard leases[id, default: 0] == 0 else { throw BJJError.domain("ASSET_BUSY", "Finish or cancel active media operations before deleting this project.") }
        }
    }
    func delete(_ id: String) throws {
        try locked { try BJJProjectVersions(store: self).trash(id, revision: load(id).revision) }
    }
    static func sanitized(_ name: String) -> String {
        let clean = String(name.prefix(120)).replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "-", options: .regularExpression)
        let trimmed = clean.trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        return trimmed.isEmpty ? "review" : trimmed
    }
    func checkSpace(required: Int64) throws {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: root.path)
        let available = (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        guard available >= required else { throw BJJError.domain("STORAGE_LOW", "Not enough free space on this iPhone. Free storage or remove completed MP4s, then retry.") }
    }
}
