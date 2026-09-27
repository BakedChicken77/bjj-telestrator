import Foundation
import AVFoundation
import CryptoKit
import ZIPFoundation

final class BJJPackageWork {
    let cancellation = BJJJobCancellation()
    private let lock = NSLock()
    private var stage = "inspecting", done: Int64 = 0, total: Int64?
    private var renderer: BJJRenderer?
    func cancel() {
        cancellation.cancel()
        lock.lock(); let encoder = renderer; lock.unlock()
        encoder?.cancel()
    }
    func useRenderer(_ renderer: BJJRenderer?) {
        lock.lock(); self.renderer = renderer; lock.unlock()
        do { try cancellation.check() } catch { renderer?.cancel() }
    }
    func update(_ stage: String, _ done: Int64 = 0, _ total: Int64? = nil) {
        lock.lock(); defer { lock.unlock() }
        self.stage = stage; self.done = done; self.total = total
    }
    func state() -> BJJJSON {
        lock.lock(); defer { lock.unlock() }
        return ["stage": stage, "completedUnits": done, "totalUnits": total.map { $0 as Any } ?? NSNull(),
                "progress": total.flatMap { $0 > 0 ? min(1, Double(done) / Double($0)) : nil }.map { $0 as Any } ?? NSNull()]
    }
}

enum BJJProjectPackage {
    struct Manifest {
        let json: BJJJSON
        let project: BJJProject
        let rawProject: Data
        let assets: [BJJJSON]
        let includeProxy: Bool
    }
    private static func normalizedMedia(_ value: BJJJSON) -> BJJJSON {
        var result = value
        result["videoStartSec"] = result["videoStartSec"] ?? 0
        result["videoStreamIndex"] = result["videoStreamIndex"] ?? 0
        result["audioStreamIndex"] = result["audioStreamIndex"] ?? NSNull()
        return result
    }
    static func manifest(_ archive: BJJPackageArchive, _ cancellation: BJJJobCancellation) throws -> Manifest {
        let raw = try archive.metadata("manifest.json", cancellation: cancellation).0
        let value = try BJJPackageJSON.read(raw)
        guard value["format"] as? String == "bjjproj", try BJJValidate.number(value["version"], "package version", 1...1, integer: true) == 1 else { throw BJJError.domain("PACKAGE_UNSUPPORTED", "This package needs a newer app or uses another format.") }
        let (bytes, hash) = try archive.metadata("project.json", cancellation: cancellation)
        let header = try BJJValidate.object(value["project"], "package project")
        guard header["entry"] as? String == "project.json", header["sha256"] as? String == hash,
              try BJJValidate.number(header["byteSize"], "project bytes", 1...Double(archive.limits.metadata), integer: true) == Double(bytes.count) else { throw BJJPackageArchive.invalid("The project document failed checksum verification.") }
        let project = try BJJProject(BJJPackageJSON.read(bytes))
        try BJJValidate.bool(value["includeProxy"], "proxy inclusion")
        let includeProxy = value["includeProxy"] as! Bool
        let expected = BJJAssets.required(project, proxy: includeProxy)
        let assets = try BJJValidate.objects(value["assets"], "package assets", maximum: archive.limits.files)
        guard assets.count == expected.count, project.source.s("asset") != project.proxy.s("asset"),
              !project.voiceovers.contains(where: { [project.source.s("asset"), project.proxy.s("asset")].contains($0.s("asset")) }) else { throw BJJPackageArchive.invalid("The package is missing required media.") }
        var refs = Set<String>(), identifiers = Set<String>(), names: Set<String> = ["manifest.json", "project.json"]
        for asset in assets {
            let id = try BJJValidate.uuid(asset["assetId"])
            let reference = try BJJValidate.asset(asset["reference"])
            let name = try BJJValidate.string(asset["entry"], "package entry", max: 100)
            let hash = try BJJValidate.string(asset["sha256"], "asset checksum", max: 64)
            guard name == "assets/\(id)", let item = archive.items[name], let wanted = expected[reference],
                  refs.insert(reference).inserted, identifiers.insert(id).inserted,
                  asset["kind"] as? String == wanted.0, hash.count == 64,
                  hash.allSatisfy({ "0123456789abcdef".contains($0) }),
                  try BJJValidate.number(asset["byteSize"], "asset bytes", 1...Double(archive.limits.perFile), integer: true) == Double(item.bytes) else { throw BJJPackageArchive.invalid("The package asset inventory is inconsistent.") }
            let metadata = try BJJValidate.object(asset["metadata"], "asset metadata")
            if wanted.0 == "source" || wanted.0 == "proxy" {
                try BJJValidate.media(metadata)
                guard NSDictionary(dictionary: normalizedMedia(metadata)).isEqual(to: normalizedMedia(wanted.1)) else { throw BJJPackageArchive.invalid("The media metadata differs from the project.") }
            } else {
                guard NSDictionary(dictionary: metadata).isEqual(to: wanted.1) else { throw BJJPackageArchive.invalid("The recording metadata differs from the project.") }
            }
            names.insert(name)
        }
        guard names == Set(archive.items.keys) else { throw BJJPackageArchive.invalid("The package contains undeclared or extra files.") }
        return Manifest(json: value, project: project, rawProject: bytes, assets: assets, includeProxy: includeProxy)
    }
    static func estimate(_ store: BJJStore, _ project: BJJProject, includeProxy: Bool) throws -> BJJJSON {
        var total: Int64 = Int64(try BJJPackageJSON.data(project.json).count) + BJJAssets.mib
        for reference in BJJAssets.required(project, proxy: includeProxy).keys {
            let file = try BJJAssets.file(store, project.id, reference)
            total += Int64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
        return BJJAssets.estimate("backup", output: total)
    }
    /// The caller holds a project lease until verification and final publication.
    static func backup(_ store: BJJStore, project: BJJProject, output: URL, includeProxy: Bool,
                       work: BJJPackageWork, limits: BJJPackageLimits = BJJPackageLimits()) throws {
        work.update("inspecting")
        let planning = try estimate(store, project, includeProxy: includeProxy)
        try store.checkSpace(required: (planning["requiredBytes"] as! NSNumber).int64Value)
        let assets = try BJJAssets.manifest(store, project, proxy: includeProxy, cancellation: work.cancellation).map { asset -> BJJJSON in
            var result = asset; result["entry"] = "assets/\(asset.s("assetId"))"; return result
        }
        let document = try BJJPackageJSON.data(project.json)
        let value: BJJJSON = ["format": "bjjproj", "version": 1, "includeProxy": includeProxy,
                              "project": ["entry": "project.json", "sha256": digest(document), "byteSize": document.count], "assets": assets]
        let header = try BJJPackageJSON.data(value)
        let total = assets.reduce(Int64(document.count + header.count)) { $0 + ($1["byteSize"] as! NSNumber).int64Value }
        guard total <= Int64(min(limits.expanded, limits.compressed)),
              max(document.count, header.count) <= Int(limits.metadata),
              assets.allSatisfy({ ($0["byteSize"] as! NSNumber).uint64Value <= limits.perFile }) else { throw BJJPackageArchive.invalid("This project exceeds supported package limits.") }
        guard !FileManager.default.fileExists(atPath: output.path) else { throw BJJPackageArchive.invalid("The backup destination already exists.") }
        var completed = false, done: Int64 = 0
        defer { if !completed { try? FileManager.default.removeItem(at: output) } }
        try autoreleasepool {
            let archive = try Archive(url: output, accessMode: .create)
            for (name, data) in [("manifest.json", header), ("project.json", document)] {
                try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(data.count), bufferSize: Int(BJJAssets.mib)) { position, size in
                    try work.cancellation.check()
                    let chunk = data.subdata(in: Int(position)..<min(data.count, Int(position) + size))
                    done += Int64(chunk.count); return chunk
                }
            }
            for asset in assets {
                let file = try BJJAssets.file(store, project.id, asset.s("reference"))
                let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
                var bytes: Int64 = 0, hash = SHA256()
                let expected = (asset["byteSize"] as! NSNumber).int64Value
                try archive.addEntry(with: asset.s("entry"), type: .file, uncompressedSize: expected, bufferSize: Int(BJJAssets.mib)) { position, amount in
                    try work.cancellation.check()
                    guard position == bytes else { throw BJJPackageArchive.invalid("Unexpected package write position.") }
                    let chunk = try handle.read(upToCount: amount) ?? Data()
                    guard chunk.count == amount else { throw BJJError.domain("ASSET_CHANGED", "A media asset changed during backup.") }
                    bytes += Int64(chunk.count); done += Int64(chunk.count); hash.update(data: chunk)
                    work.update("packing", done, total); return chunk
                }
                guard bytes == expected, hash.finalize().map({ String(format: "%02x", $0) }).joined() == asset.s("sha256") else { throw BJJError.domain("ASSET_CHANGED", "A media asset changed during backup. Its original was preserved.") }
            }
        }
        let reader = try BJJPackageArchive(output, limits: limits)
        let checked = try manifest(reader, work.cancellation)
        var verified: Int64 = 0
        for asset in checked.assets {
            let hash = try reader.stream(asset.s("entry"), cancellation: work.cancellation) { data in
                verified += Int64(data.count); work.update("validating", verified, total)
            }
            guard hash == asset.s("sha256") else { throw BJJPackageArchive.invalid("The written backup failed checksum verification.") }
        }
        let handle = try FileHandle(forWritingTo: output); defer { try? handle.close() }
        try handle.synchronize(); try work.cancellation.check(); completed = true
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func remap(_ project: BJJProject, id: String) -> (BJJJSON, [String: String]) {
        var map = [project.id: id]
        for item in project.annotations + project.voiceovers { map[item.s("id")] = UUID().uuidString.lowercased() }
        let suffix = URL(fileURLWithPath: project.source.s("asset")).pathExtension.lowercased()
        let extensionName = !suffix.isEmpty && suffix.count <= 10 && suffix.allSatisfy({ "abcdefghijklmnopqrstuvwxyz0123456789".contains($0) }) ? suffix : "mp4"
        map[project.source.s("asset")] = "source/\(UUID().uuidString.lowercased()).\(extensionName)"
        map[project.proxy.s("asset")] = "proxy/\(UUID().uuidString.lowercased()).mp4"
        for clip in project.voiceovers { map[clip.s("asset")] = "voiceover/\(map[clip.s("id")]!).wav" }
        let literal: Set<String> = ["text", "projectName", "originalFilename", "label", "note", "name"]
        func rewrite(_ value: Any) -> Any {
            if let string = value as? String { return map[string] ?? string }
            if let array = value as? [Any] { return array.map(rewrite) }
            if let object = value as? BJJJSON { return object.reduce(into: BJJJSON()) { $0[$1.key] = literal.contains($1.key) ? $1.value : rewrite($1.value) } }
            return value
        }
        var json = rewrite(project.json) as! BJJJSON
        json["revision"] = 1; json["createdAt"] = BJJProject.now(); json["updatedAt"] = BJJProject.now()
        json["projectName"] = String(project.name.prefix(144)) + " (restored copy)"
        return (json, map)
    }
    private struct Stage {
        let store: BJJStore
        let folder: URL
        let manifest: Manifest
        var json: BJJJSON
    }
    private static func extract(_ store: BJJStore, source: URL, staging: URL, id: String,
                                work: BJJPackageWork, limits: BJJPackageLimits) throws -> Stage {
        work.update("inspecting")
        let archive = try BJJPackageArchive(source, limits: limits)
        let manifest = try manifest(archive, work.cancellation)
        let bytes = manifest.assets.reduce(Int64(0)) { $0 + ($1["byteSize"] as! NSNumber).int64Value }
        let proxyBytes = manifest.includeProxy ? 0 : Int64(ceil(manifest.project.duration * 12_000_000 / 8))
        let estimate = BJJAssets.estimate("restore", output: proxyBytes, working: 32 * BJJAssets.mib, incoming: bytes)
        try store.checkSpace(required: (estimate["requiredBytes"] as! NSNumber).int64Value)
        guard !FileManager.default.fileExists(atPath: staging.path) else { throw BJJPackageArchive.invalid("Restore staging is already in use.") }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        let staged = try BJJStore(root: staging)
        let (_, folder) = try staged.createDirectory(id: id)
        let (json, map) = remap(manifest.project, id: id)
        var copied: Int64 = 0
        for asset in manifest.assets {
            let target = folder.appendingPathComponent(map[asset.s("reference")]!)
            guard FileManager.default.createFile(atPath: target.path, contents: nil) else { throw BJJPackageArchive.invalid("A restored asset could not be created.") }
            let handle = try FileHandle(forWritingTo: target); defer { try? handle.close() }
            let hash = try archive.stream(asset.s("entry"), cancellation: work.cancellation) { data in
                try handle.write(contentsOf: data); copied += Int64(data.count); work.update("extracting", copied, bytes)
            }
            try handle.synchronize()
            guard hash == asset.s("sha256") else { throw BJJPackageArchive.invalid("A required media asset failed SHA-256 verification.") }
        }
        try manifest.rawProject.write(to: folder.appendingPathComponent("package-original-project.json"), options: .atomic)
        try staged.writeJSON(manifest.json, to: folder.appendingPathComponent("package-original-manifest.json"))
        try staged.writeJSON(["version": 1, "references": map], to: folder.appendingPathComponent("package-reference-map.json"))
        return Stage(store: staged, folder: folder, manifest: manifest, json: json)
    }
    @MainActor static func restore(_ store: BJJStore, source: URL, staging: URL, id: String,
                                   work: BJJPackageWork, limits: BJJPackageLimits = BJJPackageLimits(),
                                   publish: ((URL, BJJProject) throws -> BJJProject)? = nil) async throws -> BJJProject {
        // Only this operation's private staging directory may be removed.
        guard !FileManager.default.fileExists(atPath: staging.path) else { throw BJJPackageArchive.invalid("Restore staging is already in use.") }
        defer { try? FileManager.default.removeItem(at: staging) }
        var stage = try await BJJAssets.offMain { try extract(store, source: source, staging: staging, id: id, work: work, limits: limits) }
        work.update("validating"); try work.cancellation.check()
        let metadata = stage.json["source"] as! BJJJSON
        let media = try await BJJMedia.inspect(stage.folder.appendingPathComponent(metadata.s("asset")), reference: metadata.s("asset"), originalName: metadata.s("originalFilename"))
        guard abs(media.videoRange.duration.seconds - stage.manifest.project.duration) <= 0.001,
              abs(media.videoRange.start.seconds - ((metadata["videoStartSec"] as? NSNumber)?.doubleValue ?? 0)) <= 0.001,
              media.orientedSize == CGSize(width: metadata.n("displayWidth"), height: metadata.n("displayHeight")) else { throw BJJPackageArchive.invalid("The source does not match its saved timing or orientation.") }
        let proxyRef = (stage.json["proxy"] as! BJJJSON).s("asset")
        let proxyURL = stage.folder.appendingPathComponent(proxyRef)
        if !stage.manifest.includeProxy {
            work.update("preparing_preview")
            let renderer = BJJRenderer()
            work.useRenderer(renderer)
            defer { work.useRenderer(nil) }
            try await renderer.render(media: media, project: nil, store: stage.store, output: proxyURL, proxy: true) { seconds in
                work.update("preparing_preview", Int64(seconds * 1000), Int64(media.videoRange.duration.seconds * 1000))
            }
        }
        try work.cancellation.check()
        let proxy = try await BJJMedia.inspect(proxyURL, reference: proxyRef, originalName: "preview.mp4")
        guard !BJJColor.isHDR(proxy.json), ["avc1", "h264"].contains(proxy.json.s("codec")),
              proxy.orientedSize == BJJRenderer.outputSize(media.orientedSize, maximum: 1920), abs(proxy.json.n("rotation")) < 0.001,
              proxy.fps <= 30.01, abs(proxy.videoRange.duration.seconds - media.videoRange.duration.seconds) <= max(0.1, 1 / min(30, media.fps)),
              proxy.json["hasAudio"] as? Bool == media.json["hasAudio"] as? Bool,
              proxy.json["hasAudio"] as? Bool != true || proxy.json["audioCodec"] as? String == "aac" else { throw BJJPackageArchive.invalid("The preview failed its timing, orientation, codec or audio check.") }
        if !stage.manifest.includeProxy {
            var metadata = proxy.json; metadata["durationSec"] = media.videoRange.duration.seconds
            stage.json["proxy"] = metadata
        }
        let prepared = stage
        let project = try await BJJAssets.offMain { () throws -> BJJProject in
            let project = try BJJProject(prepared.json)
            var registry: BJJJSON = [:]
            for clip in project.voiceovers {
                try work.cancellation.check()
                let audio = try AVAudioFile(forReading: prepared.folder.appendingPathComponent(clip.s("asset")))
                let format = audio.fileFormat.streamDescription.pointee
                guard clip.s("codec") == "pcm_s16le", format.mFormatID == kAudioFormatLinearPCM, format.mBitsPerChannel == 16,
                      format.mFormatFlags & kAudioFormatFlagIsFloat == 0,
                      audio.fileFormat.sampleRate == clip.n("sampleRate"), Double(audio.fileFormat.channelCount) == clip.n("channels"),
                      abs(Double(audio.length) / audio.fileFormat.sampleRate - clip.n("durationSec")) <= 1 / audio.fileFormat.sampleRate else { throw BJJPackageArchive.invalid("A recording does not match its saved duration or audio format.") }
                let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 65536)!
                var frames: AVAudioFramePosition = 0
                while audio.framePosition < audio.length {
                    try work.cancellation.check(); try audio.read(into: buffer)
                    guard buffer.frameLength > 0 else { throw BJJPackageArchive.invalid("A recording is truncated.") }
                    frames += AVAudioFramePosition(buffer.frameLength)
                }
                guard frames == audio.length else { throw BJJPackageArchive.invalid("A recording is truncated.") }
                registry[clip.s("id")] = clip
            }
            try prepared.store.writeJSON(registry, to: prepared.folder.appendingPathComponent("voiceover/assets.json"))
            let saved = try prepared.store.save(project, creating: true)
            let reopened = try prepared.store.load(saved.id)
            _ = try BJJAssets.manifest(prepared.store, reopened, proxy: true, cancellation: work.cancellation)
            return reopened
        }
        try work.cancellation.check()
        return try publish?(stage.folder, project) ?? install(store, folder: stage.folder, project: project, work: work)
    }
    static func install(_ store: BJJStore, folder: URL, project: BJJProject, work: BJJPackageWork) throws -> BJJProject {
        try store.locked {
            try work.cancellation.check()
            let target = try store.directory(project.id)
            guard !FileManager.default.fileExists(atPath: target.path) else { throw BJJError.domain("PROJECT_CONFLICT", "This new project identifier already exists. Restore again to create another copy.") }
            try FileManager.default.moveItem(at: folder, to: target)
            do { return try store.load(project.id) }
            catch { try FileManager.default.moveItem(at: target, to: folder); throw error }
        }
    }
}
