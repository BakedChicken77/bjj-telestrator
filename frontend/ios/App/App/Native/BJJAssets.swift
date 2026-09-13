import Foundation
import CryptoKit

/// Hashing and verification run off the main actor with bounded one-MiB reads.
final class BJJJobCancellation {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw BJJError.cancelled }
    }
}

enum BJJAssets {
    static let mib: Int64 = 1024 * 1024
    static func file(_ store: BJJStore, _ id: String, _ reference: String) throws -> URL {
        try BJJValidate.asset(reference)
        var cursor = try store.directory(id)
        for part in reference.split(separator: "/") {
            cursor.appendPathComponent(String(part))
            guard try cursor.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw BJJError.domain("ASSET_UNSAFE", "Symbolic links are not supported for project assets.")
            }
        }
        let url = try store.asset(id, reference)
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw BJJError.domain("ASSET_MISSING", "A required media asset is missing.")
        }
        return url
    }
    static func digest(_ url: URL, cancellation: BJJJobCancellation? = nil) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            try cancellation?.check()
            let count: Int = try autoreleasepool {
                let chunk = try handle.read(upToCount: Int(mib)) ?? Data()
                hash.update(data: chunk)
                return chunk.count
            }
            if count == 0 { break }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func fingerprint(_ url: URL) throws -> [String] {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey])
        return [String(values.fileSize ?? 0), String(values.contentModificationDate?.timeIntervalSince1970 ?? 0),
                String(values.creationDate?.timeIntervalSince1970 ?? 0)]
    }
    static func required(_ project: BJJProject, proxy: Bool = false) -> [String: (String, BJJJSON)] {
        var result = [project.source.s("asset"): ("source", project.source)]
        if proxy { result[project.proxy.s("asset")] = ("proxy", project.proxy) }
        for clip in project.voiceovers {
            result[clip.s("asset")] = ("voiceover", clip.filter { ["durationSec", "codec", "sampleRate", "channels", "recordedAt"].contains($0.key) })
        }
        return result
    }
    static func manifest(_ store: BJJStore, _ project: BJJProject, proxy: Bool = false, cancellation: BJJJobCancellation? = nil) throws -> [BJJJSON] {
        store.assetLock.lock(); defer { store.assetLock.unlock() }
        let path = try store.safeURL(project.id, "assets.json"), cachePath = try store.safeURL(project.id, "assets.cache.json")
        var existing: [String: BJJJSON] = [:]
        if FileManager.default.fileExists(atPath: path.path) {
            let manifest = try store.readJSON(path)
            guard manifest["version"] as? Int == 1 else { throw BJJError.domain("ASSET_MANIFEST_INVALID", "The asset inventory needs a newer app.") }
            for entry in try BJJValidate.objects(manifest["assets"], "assets", maximum: 100_000) {
                let reference = try BJJValidate.string(entry["reference"], "asset reference", max: 1024)
                guard existing[reference] == nil else { throw BJJError.domain("ASSET_MANIFEST_INVALID", "The asset inventory contains duplicate references.") }
                existing[reference] = entry
            }
        }
        var cache = FileManager.default.fileExists(atPath: cachePath.path) ? try store.readJSON(cachePath) : [:]
        var result = [BJJJSON](), changed = false
        for (reference, (kind, metadata)) in required(project, proxy: proxy).sorted(by: { $0.key < $1.key }) {
            let url = try file(store, project.id, reference), stamp = try fingerprint(url)
            let old = existing[reference]
            if let old, (cache[reference] as? [String]) == stamp {
                result.append(old); continue
            }
            let digest = try digest(url, cancellation: cancellation), size = Int64(stamp[0]) ?? 0
            guard try stamp == fingerprint(url) else { throw BJJError.domain("ASSET_CHANGED", "A media file changed while it was checked. Restore its original and retry.") }
            if let old, old["sha256"] as? String != digest || (old["byteSize"] as? NSNumber)?.int64Value != size {
                throw BJJError.domain("ASSET_CHANGED", "A retained media asset has changed. Restore its original file before exporting.")
            }
            let entry: BJJJSON = ["assetId": old?["assetId"] ?? UUID().uuidString.lowercased(), "kind": kind,
                                 "reference": reference, "byteSize": size, "sha256": digest, "metadata": metadata]
            existing[reference] = entry; cache[reference] = stamp; result.append(entry); changed = true
        }
        if changed {
            try store.writeJSON(["version": 1, "assets": existing.keys.sorted().compactMap { existing[$0] }], to: path)
            try store.writeJSON(cache, to: cachePath)
        }
        return result
    }
    static func estimate(_ operation: String, output: Int64, working: Int64 = 0, incoming: Int64 = 0) -> BJJJSON {
        let subtotal = output + working + incoming
        let safety = max(100 * mib, Int64(ceil(Double(subtotal) * 0.2)))
        return ["operation": operation, "incomingBytes": incoming, "outputBytes": output,
                "workingBytes": working, "safetyBytes": safety, "requiredBytes": subtotal + safety]
    }
    static func exportEstimate(_ project: BJJProject) -> BJJJSON {
        let size = BJJRenderer.outputSize(CGSize(width: project.source.n("displayWidth"), height: project.source.n("displayHeight")))
        let bitrate = min(60_000_000, max(1_000_000, Double(size.width * size.height) * project.exportSettings.n("fps") * 0.12 * pow(2, (23 - project.exportSettings.n("crf")) / 6)))
        let output = Int64(ceil(project.duration * (bitrate + 192000) / 8))
        // AVFoundation streams frames/audio; allow output relocation plus metadata.
        return estimate("export", output: output, working: output + 32 * mib)
    }
    static func proxyEstimate(_ duration: Double, incoming: Int64 = 0) -> BJJJSON {
        estimate("import", output: Int64(ceil(duration * 12_000_000 / 8)), working: 32 * mib, incoming: incoming)
    }
    static func recordingEstimate(_ duration: Double) -> BJJJSON {
        estimate("recording", output: Int64(ceil(duration * 48000 * 2)), working: 16 * mib)
    }
    static func summary(_ store: BJJStore, _ project: BJJProject) throws -> BJJJSON {
        let folder = try store.directory(project.id)
        var totals: [String: Int64] = ["sourceBytes": 0, "proxyBytes": 0, "recordingBytes": 0, "exportBytes": 0, "temporaryBytes": 0, "metadataBytes": 0]
        let categories = ["source": "sourceBytes", "proxy": "proxyBytes", "voiceover": "recordingBytes", "temp": "temporaryBytes"]
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else {
            throw BJJError.domain("STORAGE_UNAVAILABLE", "Could not inspect project storage.")
        }
        var count = 0
        for case let file as URL in files {
            count += 1
            guard count <= 100_000 else { throw BJJError.domain("STORAGE_LIMIT", "This project has too many storage entries to inspect.") }
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else { continue }
            if values.isSymbolicLink == true { files.skipDescendants(); continue }
            if values.isRegularFile != true { continue }
            let relative = String(file.path.dropFirst(folder.path.count + 1))
            let first = String(relative.split(separator: "/").first ?? "")
            let category = first == "exports" && file.pathExtension == "mp4" ? "exportBytes" : categories[first, default: "metadataBytes"]
            totals[category, default: 0] += Int64(values.fileSize ?? 0)
        }
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: store.root.path)
        var result: BJJJSON = totals.mapValues { $0 as Any }
        result["projectId"] = project.id; result["revision"] = project.revision
        result["totalBytes"] = totals.values.reduce(0, +)
        result["availableBytes"] = (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        result["exportEstimate"] = exportEstimate(project); result["recordingsRetained"] = true
        return result
    }
    static func offMain<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try work()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    static func previewCleanup(_ store: BJJStore, id: String, revision: Int? = nil, remove: Bool = false, now: Date = Date()) throws -> BJJJSON {
        try store.locked {
            let project = try store.load(id)
            if remove, project.revision != revision { throw BJJError.domain("PROJECT_CONFLICT", "The project changed. Save and retry cleanup.") }
            try store.requireUnleased(id)
            let folder = try store.directory(id)
            var references: Set<String> = [project.proxy.s("asset")]
            func collect(_ value: Any, depth: Int = 0) throws {
                guard depth <= 64 else { throw BJJError.domain("CLEANUP_BLOCKED", "Recovery metadata is too deeply nested. Preview files were retained.") }
                if let text = value as? String, text.hasPrefix("proxy/") { references.insert(text) }
                else if let array = value as? [Any] { for item in array { try collect(item, depth: depth + 1) } }
                else if let object = value as? BJJJSON { for item in object.values { try collect(item, depth: depth + 1) } }
            }
            guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else { throw BJJError.domain("CLEANUP_BLOCKED", "Recovery files could not be checked.") }
            var count = 0, total: Int64 = 0
            for case let file as URL in files {
                count += 1
                guard count <= 100_000 else { throw BJJError.domain("CLEANUP_BLOCKED", "This project has too many files to safely check retention.") }
                let properties = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
                guard properties.isSymbolicLink != true else { throw BJJError.domain("CLEANUP_BLOCKED", "Linked recovery files must be repaired before preview cleanup.") }
                guard properties.isRegularFile == true, file.pathExtension == "json" else { continue }
                if file.deletingLastPathComponent() == folder && ["assets.json", "assets.cache.json", "project.index.json"].contains(file.lastPathComponent) { continue }
                total += Int64(properties.fileSize ?? 0)
                guard (properties.fileSize ?? 0) <= 32 * 1024 * 1024, total <= 256 * mib else { throw BJJError.domain("CLEANUP_BLOCKED", "Recovery metadata exceeds the bounded cleanup scan. Files were retained.") }
                do { try collect(BJJPackageJSON.read(Data(contentsOf: file))) }
                catch { throw BJJError.domain("CLEANUP_BLOCKED", "Damaged recovery metadata prevents safe cleanup. Files were retained.") }
            }
            let proxy = try store.safeURL(id, "proxy")
            let candidates = try FileManager.default.contentsOfDirectory(at: proxy, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey])
            var eligible = [URL](), bytes: Int64 = 0
            for file in candidates {
                let name = file.deletingPathExtension().lastPathComponent
                guard file.pathExtension == "mp4", UUID(uuidString: name)?.uuidString.lowercased() == name,
                      !references.contains("proxy/\(file.lastPathComponent)") else { continue }
                let values = try file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey])
                if values.isRegularFile == true, let date = values.contentModificationDate, now.timeIntervalSince(date) >= 86400 {
                    eligible.append(file); bytes += Int64(values.fileSize ?? 0)
                }
            }
            if remove { for file in eligible { try FileManager.default.removeItem(at: file) } }
            return ["files": eligible.count, "bytes": bytes, "graceHours": 24, "removed": remove]
        }
    }
}
