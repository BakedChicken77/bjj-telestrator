import Foundation
import AVFoundation
import SwiftUI
import UIKit

struct BJJNativeReview: Identifiable {
    let id: String
    let name: String
    let duration: Double
    let preview: Bool
    var updatedAt: String = ""
    var problem: String? = nil
    var key: String { "\(preview ? "native" : "original")-\(id)" }
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
            .map { folder in
                let id = folder.lastPathComponent
                do {
                    let json = try store.readJSON(folder.appendingPathComponent("project.json"))
                    let project = try BJJProject(json)
                    guard project.id == id else { throw BJJError.invalid("The review identity differs from its folder.") }
                    return BJJNativeReview(id: id, name: project.name, duration: project.duration, preview: preview,
                                           updatedAt: json.s("updatedAt"))
                } catch {
                    // Keep unsupported/corrupt documents visible; do not migrate or discard them while listing.
                    return BJJNativeReview(id: id, name: "Review needs recovery", duration: 0, preview: preview,
                                           problem: error.localizedDescription)
                }
            }.sorted { ($0.updatedAt, $0.id) > ($1.updatedAt, $1.id) }
    }

    static func copy(_ id: String, from source: BJJStore, to target: BJJStore) throws -> BJJProject {
        let destination = try target.directory(id)
        if FileManager.default.fileExists(atPath: destination.appendingPathComponent("project.json").path) {
            return try target.loadRecoveringRecordings(id)
        }
        let original = try source.readJSON(source.directory(id).appendingPathComponent("project.json"))
        let project = try BJJProject(original)
        guard project.id == id else { throw BJJError.invalid("The selected project identity does not match its folder.") }
        let references = Set([project.source.s("asset"), project.proxy.s("asset")] + project.allTakes.map { $0.s("asset") })
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
        let registry = Dictionary(uniqueKeysWithValues: project.allTakes.map { ($0.s("id"), $0 as Any) })
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
        // The renderer floors the playhead to an output frame but ceils cue starts.
        // Anchor a new drawing to that same frame so an off-grid paused time does
        // not hide it until playback advances. Preserve explicit timing edits.
        let fps = project.exportSettings.n("fps")
        let start = BJJProject.frameIndex(at: time, fps: fps) / fps
        return ["id": UUID().uuidString.lowercased(), "type": tool.rawValue, "startSec": start,
                "endSec": min(project.duration, time + 5),
                "zIndex": min(100000, (project.annotations.map { Int($0.n("zIndex")) }.max() ?? -1) + 1),
                "strokeColor": color, "strokeWidth": 0.006, "strokeOpacity": 1.0,
                "fillColor": color, "fillOpacity": 0.0, "createdAt": stamp, "updatedAt": stamp, "geometry": geometry]
    }
}

struct BJJNativeTransportState: Codable {
    var time: Double = 0
    var speed: Float = 1
    var loopStart: Double = 0
    var loopEnd: Double = 0
    var loopEnabled = false
    func validated(duration: Double) -> BJJNativeTransportState {
        var result = self
        result.time = time.isFinite ? min(duration, max(0, time)) : 0
        result.speed = [Float(0.25), 0.5, 1, 2].contains(speed) ? speed : 1
        result.loopStart = loopStart.isFinite ? min(duration, max(0, loopStart)) : 0
        result.loopEnd = loopEnd.isFinite ? min(duration, max(0, loopEnd)) : duration
        result.loopEnabled = loopEnabled && result.loopEnd - result.loopStart >= 0.2
        return result
    }
}

@MainActor final class BJJNativeEditorSession: ObservableObject, Identifiable {
    let id: String
    let store: BJJStore
    let player: AVPlayer
    @Published private(set) var project: BJJProject
    @Published private(set) var speed: Float = 1
    @Published private(set) var loopStart = 0.0
    @Published private(set) var loopEnd = 0.0
    @Published private(set) var loopEnabled = false
    @Published var time = 0.0
    @Published var playing = false
    @Published var drawing = false { didSet { if drawing { pause() } } }
    @Published var selecting = false
    @Published var selectedID: String?
    @Published var previewCue: BJJJSON?
    var editRevision: Int?
    @Published var cueDraft: BJJJSON?
    @Published var inspectingCue = false
    @Published var draftOrder: [BJJJSON]?
    var gestureSnapshot: BJJJSON?
    var cueEditDirty: Bool {
        guard let cueDraft else { return false }
        return !NSDictionary(dictionary: cueDraft).isEqual(to: selectedCue ?? [:]) || draftOrder != nil
    }
    @Published var tool: BJJNativeTool = .arrow
    @Published var color = "#FF453A"
    @Published var text = "Cue"
    @Published var error: String? { didSet { if error != nil { BJJDiagnostics.shared.record(.editorError) } } }
    @Published var thumbnails: [UIImage] = []
    @Published var exporting = false
    @Published var exportProgress = 0.0
    @Published var shareURL: URL?
    @Published private(set) var undoCount = 0
    @Published private(set) var redoCount = 0
    @Published var recording = false
    @Published var preparingAudio = false
    @Published var recordingVideoPaused = false
    @Published var outputTime = 0.0
    @Published var recordingLevel: Float = -160
    @Published var audioRoute = ""
    @Published var notice: String?
    @Published var completedExportID: String?
    @Published var retryExportID: String?
    @Published var exportURL: URL?
    private let capture = BJJNativeRecording()
    private var previewFiles: [URL] = []
    private var playbackTimeline: BJJReviewTimeline
    private var previewGeneration = 0
    private var undoStack: [BJJJSON] = []
    private var redoStack: [BJJJSON] = []
    private var observer: Any?
    private var endObserver: NSObjectProtocol?
    private var seekTask: Task<Void, Never>?
    private var seeking = false
    private let preferences: UserDefaults?
    var importJobID: String?
    private var service: BJJService?
    private var exportCancelled = false
    private var jobID: String?
    private var closed = false
    private var seekGeneration = 0
    init(project: BJJProject, store: BJJStore, service: BJJService? = nil, preferences: UserDefaults? = .standard) throws {
        BJJDiagnostics.shared.record(.editorOpen)
        self.project = project; self.store = store; id = project.id
        playbackTimeline = BJJReviewTimeline(sourceDuration: project.duration)
        self.service = service; self.preferences = preferences; loopEnd = project.duration
        player = AVPlayer(url: try store.asset(project.id, project.proxy.s("asset")))
        player.volume = (project.settings["originalAudioMuted"] as? Bool) == true ? 0 : Float(min(1, project.settings.n("originalAudioGain")))
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1.0 / 30, preferredTimescale: 600), queue: .main) { [weak self] value in
            Task { @MainActor in
                guard let self, !self.closed, !self.seeking else { return }
                if self.recording { self.recordingLevel = self.capture.level; self.capture.checkClock() }
                let seconds = value.seconds
                if seconds.isFinite { self.outputTime = min(self.project.outputDuration, max(0, seconds)); self.time = self.playbackTimeline.source(at: self.outputTime) }
                self.playing = self.player.rate != 0
                if self.loopEnabled, self.playing, self.time >= self.loopEnd {
                    self.seek(self.loopStart, resume: true)
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                guard let self, !self.closed, !self.seeking else { return }
                guard let item = note.object as? AVPlayerItem, item === self.player.currentItem else { return }
                if self.recording { self.capture.stop(); return }
                if self.loopEnabled { self.seek(self.loopStart, resume: true) } else { self.pause() }
            }
        }
        if let service {
            let exports = (try? service.listExports(id)) ?? []
            retryExportID = exports.first { ["failed", "cancelled"].contains($0["status"] as? String ?? "") }?["jobId"] as? String
        }
        capture.finished = { [weak self] clip, failure, reason in
            guard let self else { return }
            self.recording = false; self.recordingVideoPaused = false; self.playing = false
            if let failure { self.error = failure.localizedDescription; return }
            if let clip {
                do {
                    var json = self.project.json
                    if clip["kind"] as? String == "review-narration-v1" { json = try BJJReviewReceipt.apply(clip, to: json) }
                    else { json["voiceovers"] = self.project.voiceovers + [clip] }
                    try self.commitDocument(json)
                    self.notice = reason ?? "Take saved. Play it back to check the timing."
                } catch { self.error = "The audio was preserved, but the review could not save. Reopen it to recover the take. \(error.localizedDescription)" }
            } else { self.notice = reason }
        }
        capture.meterChanged = { [weak self] value in self?.recordingLevel = value }
        if let data = preferences?.data(forKey: "native-review.\(id)"),
           let saved = try? JSONDecoder().decode(BJJNativeTransportState.self, from: data) {
            let state = saved.validated(duration: project.duration)
            speed = state.speed; loopStart = state.loopStart; loopEnd = state.loopEnd; loopEnabled = state.loopEnabled
            seek(state.time)
        }
    }
    func pause() {
        player.pause(); playing = false
        // Fence a pending seek that intended to resume playback, including loop wrap.
        seekGeneration += 1; seekTask?.cancel(); seekTask = nil
        player.currentItem?.cancelPendingSeeks(); seeking = false
        savePosition()
    }
    func togglePlayback() {
        BJJDiagnostics.shared.record(.playback)
        guard !recording, !preparingAudio else { return }
        if playing { pause(); return }
        drawing = false
        let target: Double
        if loopEnabled && (time < loopStart || time >= loopEnd) { target = loopStart }
        else { target = time >= project.duration - 0.05 ? 0 : time }
        if target == time { seekOutput(outputTime, resume: true) } else { seek(target, resume: true) }
    }
    func seek(_ seconds: Double, resume: Bool = false) {
        guard seconds.isFinite else { return }
        seekOutput(project.reviewTimeline.output(before: min(project.duration, max(0, seconds))), resume: resume)
    }
    func seekOutput(_ seconds: Double, resume: Bool = false) {
        guard seconds.isFinite, !closed, !recording else { return }
        pause(); seekGeneration += 1
        let generation = seekGeneration
        let target = min(project.outputDuration, max(0, seconds))
        seeking = true; outputTime = target; time = project.reviewTimeline.source(at: target)
        // Coalesce rapid slider changes while retaining an immediate visual playhead.
        seekTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 25_000_000)
            guard let self, !Task.isCancelled, !self.closed, self.seekGeneration == generation else { return }
            self.player.seek(to: CMTime(seconds: target, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                Task { @MainActor in
                    guard let self, self.seekGeneration == generation, !self.closed else { return }
                    self.seeking = false
                    if finished {
                        let resolved = self.player.currentTime().seconds
                        if resolved.isFinite { self.outputTime = min(self.project.outputDuration, max(0, resolved)); self.time = self.playbackTimeline.source(at: self.outputTime) }
                        if resume { self.player.playImmediately(atRate: self.speed); self.playing = true }
                    }
                    self.savePosition()
                }
            }
        }
    }
    func setSpeed(_ value: Float) {
        guard !recording, [Float(0.25), 0.5, 1, 2].contains(value) else { return }
        speed = value
        if playing { player.rate = value }
        savePosition()
    }
    func setLoop(start: Double, end: Double, enabled: Bool) throws {
        guard start.isFinite, end.isFinite, start >= 0, end <= project.duration, end - start >= 0.2 else {
            throw BJJError.invalid("Choose an end at least 0.2 seconds after the start, within the video.")
        }
        loopStart = start; loopEnd = end; loopEnabled = enabled; savePosition()
    }
    func toggleLoop() {
        do { try setLoop(start: loopStart, end: loopEnd, enabled: !loopEnabled) }
        catch { self.error = error.localizedDescription }
    }
    func markLoop(start: Bool) {
        do { try setLoop(start: start ? time : loopStart, end: start ? loopEnd : time, enabled: loopEnabled) }
        catch { self.error = error.localizedDescription }
    }
    private func savePosition() {
        let state = BJJNativeTransportState(time: time, speed: speed, loopStart: loopStart, loopEnd: loopEnd, loopEnabled: loopEnabled)
        if let data = try? JSONEncoder().encode(state) { preferences?.set(data, forKey: "native-review.\(id)") }
    }
    private var documentState: BJJJSON {
        ["annotations": project.annotations, "voiceovers": project.voiceovers, "settings": project.settings,
         "requiredCapabilities": project.json["requiredCapabilities"]!, "reviewTimeline": project.json["reviewTimeline"] ?? NSNull(), "reviewNarration": project.json["reviewNarration"] ?? NSNull()]
    }
    func commitDocument(_ json: BJJJSON) throws {
        guard !exporting, !recording, !preparingAudio else { throw BJJError.invalid("Finish the current operation before editing.") }
        let previous = documentState
        let saved = try store.save(BJJProject(json))
        BJJDiagnostics.shared.record(.editSaved, value: Double(saved.revision))
        let audioChanged = !NSDictionary(dictionary: ["takes": project.allTakes, "holds": project.reviewTimeline.holds, "settings": project.settings]).isEqual(to: ["takes": saved.allTakes, "holds": saved.reviewTimeline.holds, "settings": saved.settings])
        undoStack.append(previous); if undoStack.count > 50 { undoStack.removeFirst() }
        redoStack.removeAll(); project = saved; cancelCueEdit(); syncHistory()
        if audioChanged { Task { await self.prepareAudio() } }
    }
    func commit(_ annotations: [BJJJSON]) throws {
        var json = project.json; json["annotations"] = annotations
        try commitDocument(json)
        if !annotations.contains(where: { $0.s("id") == selectedID }) { selectedID = nil }
    }
    func updateAudio(clip: BJJJSON? = nil, removing: String? = nil, settings: BJJJSON? = nil) {
        do {
            var json = project.json
            if let settings { json["settings"] = settings }
            if let clip {
                json["voiceovers"] = project.voiceovers.map { $0.s("id") == clip.s("id") ? clip : $0 }
                if project.pauseAware { json["reviewNarration"] = project.reviewNarration.map { $0.s("id") == clip.s("id") ? clip : $0 } }
            }
            if let removing {
                json["voiceovers"] = project.voiceovers.filter { $0.s("id") != removing }
                if project.pauseAware { json["reviewNarration"] = project.reviewNarration.filter { $0.s("id") != removing } }
            }
            try commitDocument(json)
        } catch { self.error = error.localizedDescription }
    }
    func prepareAudio() async {
        BJJDiagnostics.shared.record(.audioPreview)
        guard !closed, !recording, !preparingAudio else { return }
        let preparationBegan = ProcessInfo.processInfo.systemUptime
        let timingJobID = importJobID; importJobID = nil
        defer { if let timingJobID { service?.mediaJobs.recordMetric(timingJobID, "audio_preview", seconds: ProcessInfo.processInfo.systemUptime - preparationBegan) } }
        pause(); preparingAudio = true; previewGeneration += 1
        let generation = previewGeneration
        let oldPosition = max(0, player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0)
        let oldSpan = playbackTimeline.span(at: oldPosition)
        let sourcePosition = time
        var position = project.reviewTimeline.output(before: sourcePosition)
        if let oldSpan, abs(oldSpan.source - sourcePosition) < 0.001, let id = oldSpan.hold?["id"] as? String,
           let span = project.reviewTimeline.spans.first(where: { $0.hold?["id"] as? String == id }) {
            position = span.output + min(span.duration, oldPosition - oldSpan.output)
        }
        player.isMuted = true
        defer { preparingAudio = false }
        do {
            let path = try store.safeURL(id, "temp/mix-\(UUID().uuidString).caf")
            previewFiles.append(path)
            let item = try await BJJAudioComposition.preview(project: project, store: store, target: path)
            guard !closed, generation == previewGeneration else { try? FileManager.default.removeItem(at: path); return }
            playbackTimeline = project.reviewTimeline
            player.replaceCurrentItem(with: item); player.volume = 1; player.isMuted = false
            seekOutput(position)
            // The previous item is no longer using these files.
            for old in previewFiles where old != path { try? FileManager.default.removeItem(at: old) }
            previewFiles = [path]
        } catch { self.error = "Audio preview could not be prepared. \(error.localizedDescription)" }
    }
    func startRecording() async {
        guard !closed, !recording, !preparingAudio, !exporting else { return }
        cancelCueEdit(); pause(); drawing = false; speed = 1; loopEnabled = false
        recording = true
        BJJDiagnostics.shared.record(.recordingStart)
        do {
            try await capture.begin(project: project, store: store, player: player)
            guard !closed, recording else { capture.stop(); return }
            audioRoute = capture.route; playing = true
        } catch {
            recording = false; pause()
            BJJDiagnostics.shared.record(.recordingError, error: error)
            if !(error is CancellationError), (error as? BJJError)?.code != "CANCELLED" { self.error = error.localizedDescription }
        }
    }
    func toggleRecordingVideo() async {
        do { try await capture.toggleVideoPause(); recordingVideoPaused = capture.videoPaused; playing = !recordingVideoPaused && recording }
        catch { self.error = error.localizedDescription }
    }
    func stopRecording() { capture.stop() }
    func removeNarrationPause(_ id: String) {
        do {
            var json = project.json
            var timeline = project.json["reviewTimeline"] as? BJJJSON ?? [:]
            timeline["holds"] = project.reviewTimeline.holds.filter { $0.s("id") != id }; json["reviewTimeline"] = timeline
            json["reviewNarration"] = project.reviewNarration.map { take -> BJJJSON in
                var take = take; take["placements"] = (take["placements"] as! [BJJJSON]).filter { $0["holdId"] as? String != id }; return take
            }
            try commitDocument(json)
        } catch { self.error = error.localizedDescription }
    }
    func nudgeReviewTake(_ id: String, delta: Double) {
        guard let take = project.reviewNarration.first(where: { $0.s("id") == id }) else { return }
        do {
            let timeline = project.reviewTimeline
            var changed = take, result: [BJJJSON] = []
            for p in take["placements"] as! [BJJJSON] {
                guard let position = timeline.position(p), position + delta >= 0, position + delta + p.n("durationTicks") / 48000 <= timeline.duration else { throw BJJError.invalid("The take must fit the review timeline.") }
                let slices = timeline.placements(start: position + delta, duration: p.n("durationTicks") / 48000)
                result += slices.map { slice -> BJJJSON in var slice = slice; slice["audioStartTicks"] = slice.n("audioStartTicks") + p.n("audioStartTicks"); return slice }
            }
            changed["placements"] = result; updateAudio(clip: changed)
        } catch { self.error = error.localizedDescription }
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
        BJJDiagnostics.shared.record(.history, value: redo ? 1 : 0)
        guard !exporting, !recording, !preparingAudio, !inspectingCue else { return }; cancelCueEdit()
        guard let state = redo ? redoStack.last : undoStack.last else { return }
        do {
            var json = project.json
            for (key, value) in state { if value is NSNull { json.removeValue(forKey: key) } else { json[key] = value } }
            let previous = documentState
            let saved = try store.save(BJJProject(json))
            if redo { redoStack.removeLast(); undoStack.append(previous) }
            else { undoStack.removeLast(); redoStack.append(previous) }
            project = saved; syncHistory()
            Task { await self.prepareAudio() }
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
    func export(options: BJJExportOptions? = nil, retry: String? = nil) async {
        guard !exporting, !recording, !preparingAudio else { return }
        cancelCueEdit(); pause(); exporting = true; exportProgress = 0; exportCancelled = false
        defer { exporting = false; jobID = nil }
        do {
            if service == nil { service = try BJJService(store: store) }
            guard let service else { return }
            let job: BJJExportJob
            if let retry { job = try service.retryExport(retry) }
            else { job = try await service.createExport(id, expectedRevision: project.revision, options: options) }
            retryExportID = job.jobId
            jobID = job.jobId
            if exportCancelled || closed { _ = try service.cancel(job.jobId); return }
            while !Task.isCancelled, !closed {
                let current = try service.job(job.jobId)
                exportProgress = current.progress / 100
                if current.status == "completed" {
                    releaseExport(); exportURL = try service.acquireExportFile(job.jobId)
                    completedExportID = job.jobId; retryExportID = nil; return
                }
                if current.status == "cancelled" { return }
                if current.status == "failed" { throw BJJError.invalid(current.error ?? "Export failed.") }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            _ = try service.cancel(job.jobId)
        } catch { self.error = error.localizedDescription }
    }
    func releaseExport() {
        if let completedExportID { service?.releaseExportFile(completedExportID) }
        completedExportID = nil; exportURL = nil; shareURL = nil
    }
    func cancelExport() { exportCancelled = true; if let jobID { _ = try? service?.cancel(jobID) } }
    func close() {
        BJJDiagnostics.shared.record(.editorClose)
        guard !closed else { return }
        capture.stop(); closed = true; previewGeneration += 1; cancelCueEdit(); pause(); cancelExport(); releaseExport()
        if let observer { player.removeTimeObserver(observer); self.observer = nil }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }
        player.replaceCurrentItem(with: nil)
        for file in previewFiles { try? FileManager.default.removeItem(at: file) }
    }
}
