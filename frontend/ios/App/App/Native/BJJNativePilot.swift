import Foundation
import AVFoundation
import SwiftUI
import UIKit

struct BJJNativeReview: Identifiable {
    let id: String
    let name: String
    let duration: Double
    let preview: Bool
}

/// Pilot projects have a separate root. Reading the original library never calls
/// load(), which can migrate schema-1 documents as a side effect.
enum BJJNativePilot {
    static func previewRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BJJTelestrator/native-preview/projects", isDirectory: true)
    }
    static func reviews(_ store: BJJStore, preview: Bool) throws -> [BJJNativeReview] {
        try FileManager.default.contentsOfDirectory(at: store.root, includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
            .compactMap { folder in
                guard let json = try? store.readJSON(folder.appendingPathComponent("project.json")),
                      let project = try? BJJProject(json), project.id == folder.lastPathComponent else { return nil }
                return BJJNativeReview(id: project.id, name: project.name, duration: project.duration, preview: preview)
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    static func copy(_ id: String, from source: BJJStore, to target: BJJStore) throws -> BJJProject {
        let destination = try target.directory(id)
        if FileManager.default.fileExists(atPath: destination.appendingPathComponent("project.json").path) {
            return try target.loadRecoveringRecordings(id)
        }
        let original = try source.readJSON(source.directory(id).appendingPathComponent("project.json"))
        let project = try BJJProject(original)
        guard project.id == id else { throw BJJError.invalid("The selected project identity does not match its folder.") }
        let references = Set([project.source.s("asset"), project.proxy.s("asset")] + project.voiceovers.map { $0.s("asset") })
        let files = try references.map { reference -> (String, URL, Int64) in
            let url = try BJJAssets.file(source, id, reference)
            return (reference, url, Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0))
        }
        try target.checkSpace(required: files.reduce(Int64(100_000_000)) { $0 + $1.2 })
        let staging = target.root.appendingPathComponent(".copy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        for (reference, input, _) in files {
            let output = staging.appendingPathComponent(reference)
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: input, to: output)
            guard try BJJAssets.digest(input) == BJJAssets.digest(output) else {
                throw BJJError.invalid("The preview copy could not be verified. Your original was preserved.")
            }
        }
        for folder in ["source", "proxy", "voiceover", "exports", "temp"] {
            try FileManager.default.createDirectory(at: staging.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        var document = original
        document["nativePreviewCopy"] = true
        try target.writeJSON(document, to: staging.appendingPathComponent("project.json"))
        let registry = Dictionary(uniqueKeysWithValues: project.voiceovers.map { ($0.s("id"), $0 as Any) })
        try target.writeJSON(registry, to: staging.appendingPathComponent("voiceover/assets.json"))
        try FileManager.default.moveItem(at: staging, to: destination)
        return try target.load(id)
    }
}

enum BJJNativeTool: String, CaseIterable, Identifiable {
    case arrow, freehand, line, ellipse, rectangle, text
    var id: String { rawValue }
    var title: String { self == .freehand ? "Pen" : rawValue.capitalized }
    var symbol: String {
        switch self {
        case .arrow: return "arrow.up.right"
        case .freehand: return "pencil.tip"
        case .line: return "line.diagonal"
        case .ellipse: return "circle"
        case .rectangle: return "rectangle"
        case .text: return "textformat"
        }
    }
}

enum BJJNativeGeometry {
    static func point(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: min(1, max(0, (point.x - rect.minX) / max(1, rect.width))),
                y: min(1, max(0, (point.y - rect.minY) / max(1, rect.height))))
    }
    static func annotation(tool: BJJNativeTool, points: [CGPoint], time: Double,
                           project: BJJProject, color: String, text: String) throws -> BJJJSON {
        guard let first = points.first, let last = points.last, time.isFinite,
              time >= 0, time < project.duration - 0.001 else {
            throw BJJError.invalid("Move the playhead before the end of the video to draw.")
        }
        let x = min(first.x, last.x), y = min(first.y, last.y)
        let width = abs(first.x - last.x), height = abs(first.y - last.y)
        var geometry: BJJJSON
        switch tool {
        case .arrow, .line:
            guard hypot(width, height) > 0.002 else { throw BJJError.cancelled }
            geometry = ["x1": first.x, "y1": first.y, "x2": last.x, "y2": last.y]
            if tool == .arrow { geometry["arrowheadSize"] = 0.035 }
        case .rectangle:
            guard width > 0.002, height > 0.002 else { throw BJJError.cancelled }
            geometry = ["x": x, "y": y, "width": width, "height": height]
        case .ellipse:
            guard width > 0.002, height > 0.002 else { throw BJJError.cancelled }
            geometry = ["centerX": x + width / 2, "centerY": y + height / 2, "radiusX": width / 2, "radiusY": height / 2]
        case .freehand:
            guard points.count > 1 else { throw BJJError.cancelled }
            geometry = ["points": points.prefix(4000).map { ["x": $0.x, "y": $0.y] }, "smoothing": 0]
        case .text:
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BJJError.invalid("Enter the text for your cue first.") }
            geometry = ["x": first.x, "y": first.y, "text": String(text.prefix(2000)), "fontSize": 0.045,
                        "alignment": "left", "backgroundColor": "#000000", "backgroundOpacity": 0.6]
        }
        let stamp = BJJProject.now()
        return ["id": UUID().uuidString.lowercased(), "type": tool.rawValue, "startSec": time,
                "endSec": min(project.duration, time + 5),
                "zIndex": min(100000, (project.annotations.map { Int($0.n("zIndex")) }.max() ?? -1) + 1),
                "strokeColor": color, "strokeWidth": 0.006, "strokeOpacity": 1.0,
                "fillColor": color, "fillOpacity": 0.0, "createdAt": stamp, "updatedAt": stamp, "geometry": geometry]
    }
}

@MainActor final class BJJNativeEditorSession: ObservableObject, Identifiable {
    let id: String
    let store: BJJStore
    let player: AVPlayer
    @Published private(set) var project: BJJProject
    @Published var time = 0.0
    @Published var playing = false
    @Published var drawing = false { didSet { if drawing { pause() } } }
    @Published var tool: BJJNativeTool = .arrow
    @Published var color = "#FF453A"
    @Published var text = "Cue"
    @Published var error: String?
    @Published var thumbnails: [UIImage] = []
    @Published var exporting = false
    @Published var exportProgress = 0.0
    @Published var shareURL: URL?
    @Published private(set) var undoCount = 0
    @Published private(set) var redoCount = 0
    private var undoStack: [[BJJJSON]] = []
    private var redoStack: [[BJJJSON]] = []
    private var observer: Any?
    private var service: BJJService?
    private var jobID: String?
    private var closed = false
    private var seekGeneration = 0
    init(project: BJJProject, store: BJJStore) throws {
        self.project = project; self.store = store; id = project.id
        player = AVPlayer(url: try store.asset(project.id, project.proxy.s("asset")))
        player.volume = (project.settings["originalAudioMuted"] as? Bool) == true ? 0 : Float(min(1, project.settings.n("originalAudioGain")))
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1.0 / 30, preferredTimescale: 600), queue: .main) { [weak self] value in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                let seconds = value.seconds
                if seconds.isFinite { self.time = min(self.project.duration, max(0, seconds)) }
                self.playing = self.player.rate != 0
            }
        }
    }
    func pause() { player.pause(); playing = false }
    func togglePlayback() {
        if playing { pause() } else {
            drawing = false
            if time >= project.duration - 0.05 { seek(0) }
            player.play(); playing = true
        }
    }
    func seek(_ seconds: Double) {
        pause(); seekGeneration += 1
        let generation = seekGeneration
        let target = min(project.duration, max(0, seconds))
        player.currentItem?.cancelPendingSeeks()
        time = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.seekGeneration == generation, !self.closed else { return }
                let resolved = self.player.currentTime().seconds
                if resolved.isFinite { self.time = min(self.project.duration, max(0, resolved)) }
            }
        }
    }
    func commit(_ annotations: [BJJJSON]) throws {
        var json = project.json; json["annotations"] = annotations
        let previous = project.annotations
        let saved = try store.save(BJJProject(json))
        undoStack.append(previous); if undoStack.count > 50 { undoStack.removeFirst() }
        redoStack.removeAll(); project = saved; syncHistory()
    }
    func add(_ points: [CGPoint]) {
        do { try commit(project.annotations + [try BJJNativeGeometry.annotation(tool: tool, points: points, time: time, project: project, color: color, text: text)]) }
        catch BJJError.cancelled { }
        catch { self.error = error.localizedDescription }
    }
    func remove(_ id: String) {
        do { try commit(project.annotations.filter { $0.s("id") != id }) }
        catch { self.error = error.localizedDescription }
    }
    func history(redo: Bool) {
        guard let annotations = redo ? redoStack.last : undoStack.last else { return }
        do {
            var json = project.json; json["annotations"] = annotations
            let saved = try store.save(BJJProject(json))
            if redo { redoStack.removeLast(); undoStack.append(project.annotations) }
            else { undoStack.removeLast(); redoStack.append(project.annotations) }
            project = saved; syncHistory()
        } catch { self.error = error.localizedDescription }
    }
    private func syncHistory() { undoCount = undoStack.count; redoCount = redoStack.count }
    func prepareThumbnails() async {
        guard thumbnails.isEmpty else { return }
        do {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: try store.asset(id, project.proxy.s("asset"))))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 180, height: 100)
            for index in 0..<8 {
                guard !Task.isCancelled, !closed else { generator.cancelAllCGImageGeneration(); return }
                let result = try await generator.image(at: CMTime(seconds: project.duration * Double(index) / 8, preferredTimescale: 600))
                thumbnails.append(UIImage(cgImage: result.image))
            }
        } catch { /* The player remains usable when thumbnails cannot decode. */ }
    }
    func export() async {
        guard !exporting else { return }
        pause(); exporting = true; exportProgress = 0
        defer { exporting = false; jobID = nil }
        do {
            if service == nil { service = try BJJService(store: store) }
            guard let service else { return }
            let job = try await service.createExport(id, expectedRevision: project.revision)
            jobID = job.jobId
            while !Task.isCancelled, !closed {
                let current = try service.job(job.jobId)
                exportProgress = current.progress / 100
                if current.status == "completed" { shareURL = try service.exportedFile(job.jobId); return }
                if current.status == "cancelled" { return }
                if current.status == "failed" { throw BJJError.invalid(current.error ?? "Export failed.") }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            _ = try service.cancel(job.jobId)
        } catch { self.error = error.localizedDescription }
    }
    func cancelExport() { if let jobID { _ = try? service?.cancel(jobID) } }
    func close() {
        guard !closed else { return }
        closed = true; pause(); cancelExport()
        if let observer { player.removeTimeObserver(observer); self.observer = nil }
        player.replaceCurrentItem(with: nil)
    }
}
