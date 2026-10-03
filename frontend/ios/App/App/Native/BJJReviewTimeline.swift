import Foundation
import AVFoundation

/// Source seconds never change. Output ticks include project-owned narration holds.
/// Half-open spans and stable array order make boundary mapping deterministic.
struct BJJReviewTimeline {
    static let capability = "review.pause-narration.v1"
    static let rate: Double = 48000
    struct Span {
        let source: Double
        let output: Double
        let duration: Double
        let hold: BJJJSON?
        var end: Double { output + duration }
    }
    let sourceDuration: Double
    let holds: [BJJJSON]
    var spans: [Span] {
        var result: [Span] = [], source = 0.0, output = 0.0
        for hold in holds {
            let boundary = hold.n("sourceTicks") / Self.rate
            if boundary > source {
                result.append(Span(source: source, output: output, duration: boundary - source, hold: nil))
                output += boundary - source
            }
            let length = hold.n("durationTicks") / Self.rate
            result.append(Span(source: boundary, output: output, duration: length, hold: hold))
            source = boundary; output += length
        }
        if source < sourceDuration { result.append(Span(source: source, output: output, duration: sourceDuration - source, hold: nil)) }
        return result
    }
    var duration: Double { sourceDuration + holds.reduce(0) { $0 + $1.n("durationTicks") / Self.rate } }
    func span(at output: Double) -> Span? { spans.first { output >= $0.output && output < $0.end } }
    func source(at output: Double) -> Double {
        guard let span = span(at: output) else { return output <= 0 ? 0 : sourceDuration }
        return span.hold == nil ? span.source + output - span.output : span.source
    }
    func output(before source: Double) -> Double {
        source + holds.filter { $0.n("sourceTicks") / Self.rate < source }.reduce(0) { $0 + $1.n("durationTicks") / Self.rate }
    }
    func output(after source: Double) -> Double {
        source + holds.filter { $0.n("sourceTicks") / Self.rate <= source }.reduce(0) { $0 + $1.n("durationTicks") / Self.rate }
    }
    init(sourceDuration: Double, holds: [BJJJSON] = []) { self.sourceDuration = sourceDuration; self.holds = holds }
    init(_ json: BJJJSON, sourceDuration: Double, capable: Bool) throws {
        self.sourceDuration = sourceDuration
        guard capable else {
            guard json["reviewTimeline"] == nil, json["reviewNarration"] == nil else { throw BJJError.invalid("Pause narration requires its capability marker.") }
            holds = []; return
        }
        let timeline = try BJJValidate.object(json["reviewTimeline"], "review timeline")
        try BJJValidate.number(timeline["version"], "timeline version", 1...1, integer: true)
        holds = try BJJValidate.objects(timeline["holds"], "narration pauses", maximum: 2000)
        var previous = 0.0, ids = Set<String>()
        for hold in holds {
            guard ids.insert(try BJJValidate.uuid(hold["id"])).inserted else { throw BJJError.invalid("Duplicate narration pause.") }
            let source = try BJJValidate.number(hold["sourceTicks"], "pause source", 0...(sourceDuration * Self.rate).rounded(), integer: true)
            guard source >= previous else { throw BJJError.invalid("Narration pauses are not ordered.") }
            previous = source
            try BJJValidate.number(hold["durationTicks"], "pause duration", 1...(86400 * Self.rate), integer: true)
            let pts = try BJJValidate.number(hold["frozenPTS"], "frozen frame", 0...sourceDuration)
            guard pts < sourceDuration, abs(pts - source / Self.rate) <= 1 else { throw BJJError.invalid("Frozen frame is outside the pause boundary.") }
        }
        guard duration <= 86400 else { throw BJJError.invalid("The output review cannot exceed 24 hours.") }
    }
    var json: BJJJSON { ["version": 1, "holds": holds] }
    /// Split a continuous microphone interval into immutable sample slices anchored
    /// to a source span or a stable hold ID. Later holds do not stretch the WAV.
    func placements(start: Double, duration: Double) -> [BJJJSON] {
        spans.compactMap { span in
            let first = max(start, span.output), last = min(start + duration, span.end)
            guard last - first >= 1 / Self.rate else { return nil }
            let audioFirst = ((first - start) * Self.rate).rounded(), audioLast = ((last - start) * Self.rate).rounded()
            guard audioLast > audioFirst else { return nil }
            var p: BJJJSON = ["audioStartTicks": audioFirst, "durationTicks": audioLast - audioFirst]
            if let hold = span.hold { p["holdId"] = hold.s("id"); p["offsetTicks"] = ((first - span.output) * Self.rate).rounded() }
            else { p["sourceTicks"] = ((span.source + first - span.output) * Self.rate).rounded() }
            return p
        }
    }
    func position(_ placement: BJJJSON) -> Double? {
        if let id = placement["holdId"] as? String,
           let span = spans.first(where: { $0.hold?.s("id") == id }) { return span.output + placement.n("offsetTicks") / Self.rate }
        if let ticks = placement["sourceTicks"] as? NSNumber { return output(after: ticks.doubleValue / Self.rate) }
        return nil
    }
    func validateTake(_ clip: BJJJSON) throws {
        try BJJValidate.uuid(clip["id"]); try BJJValidate.asset(clip["asset"])
        let count = try BJJValidate.number(clip["sampleCount"], "recorded samples", 1...(86400 * Self.rate), integer: true)
        let length = try BJJValidate.number(clip["durationSec"], "recorded duration", 0.001...86400)
        guard abs(length - count / Self.rate) < 1 / Self.rate else { throw BJJError.invalid("Narration sample length is inconsistent.") }
        try BJJValidate.number(clip["sampleRate"], "narration sample rate", Self.rate...Self.rate, integer: true)
        try BJJValidate.number(clip["channels"], "narration channels", 1...1, integer: true)
        try BJJValidate.string(clip["codec"], "narration codec", max: 50); try BJJValidate.timestamp(clip["recordedAt"])
        try BJJValidate.number(clip["gain"], "narration gain", 0...2); try BJJValidate.bool(clip["muted"], "narration mute")
        let placements = try BJJValidate.objects(clip["placements"], "narration placements", maximum: 4001)
        var previousEnd = 0.0
        for p in placements {
            let audio = try BJJValidate.number(p["audioStartTicks"], "audio sample start", 0...count, integer: true)
            let duration = try BJJValidate.number(p["durationTicks"], "audio sample duration", 1...count, integer: true)
            guard audio >= previousEnd, audio + duration <= count + 1 else { throw BJJError.invalid("Narration sample slices overlap or exceed their asset.") }
            previousEnd = audio + duration
            if p["holdId"] != nil {
                try BJJValidate.uuid(p["holdId"])
                let offset = try BJJValidate.number(p["offsetTicks"], "pause audio offset", 0...(86400 * Self.rate), integer: true)
                guard let hold = holds.first(where: { $0["id"] as? String == p["holdId"] as? String }), offset + duration <= hold.n("durationTicks") + 1 else { throw BJJError.invalid("Narration refers to a missing or short pause.") }
                guard p["sourceTicks"] == nil else { throw BJJError.invalid("Ambiguous narration placement.") }
            } else {
                let source = try BJJValidate.number(p["sourceTicks"], "source audio anchor", 0...(sourceDuration * Self.rate), integer: true)
                guard source + duration <= sourceDuration * Self.rate + 1 else { throw BJJError.invalid("Narration exceeds the source.") }
            }
            guard let start = position(p), start + duration / Self.rate <= self.duration + 0.001 else { throw BJJError.invalid("Narration exceeds the output.") }
        }
    }
    /// Insert playing spans and exactly ONE decoded sample per hold. Scaling this
    /// one sample repeats a frame, rather than slowing a multi-frame video range.
    func insertVideo(_ source: AVAssetTrack, range: CMTimeRange, into track: AVMutableCompositionTrack) async throws {
        if holds.isEmpty { try track.insertTimeRange(range, of: source, at: .zero); return }
        for span in spans {
            let at = CMTime(seconds: span.output, preferredTimescale: 48000)
            if let hold = span.hold {
                let pts = CMTimeAdd(range.start, CMTime(seconds: hold.n("frozenPTS"), preferredTimescale: 1000000000))
                guard let asset = source.asset else { throw BJJError.invalid("The paused video asset is unavailable.") }
                let reader = try AVAssetReader(asset: asset)
                reader.timeRange = CMTimeRange(start: CMTimeMaximum(range.start, CMTimeSubtract(pts, CMTime(seconds: 0.0001, preferredTimescale: 1000000000))), end: CMTimeRangeGetEnd(range))
                let output = AVAssetReaderTrackOutput(track: source, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                reader.add(output)
                guard reader.startReading() else { throw reader.error ?? BJJError.invalid("Cannot decode the paused frame.") }
                func pictureSample() -> CMSampleBuffer? {
                    while let sample = output.copyNextSampleBuffer() {
                        if CMSampleBufferGetImageBuffer(sample) != nil { return sample }
                        // Core Media can return marker buffers without a picture.
                    }
                    return nil
                }
                guard let sample = pictureSample() else { throw reader.error ?? BJJError.invalid("The paused frame is unavailable.") }
                let first = CMSampleBufferGetPresentationTimeStamp(sample)
                var frameDuration = CMSampleBufferGetDuration(sample)
                if !frameDuration.isNumeric || frameDuration.seconds <= 0 {
                    if let next = pictureSample() { frameDuration = CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(next), first) }
                    else { frameDuration = CMTimeSubtract(CMTimeRangeGetEnd(range), first) }
                }
                reader.cancelReading()
                guard frameDuration.seconds > 0 else { throw BJJError.invalid("Paused frame has no duration.") }
                try track.insertTimeRange(CMTimeRange(start: first, duration: frameDuration), of: source, at: at)
                track.scaleTimeRange(CMTimeRange(start: at, duration: frameDuration), toDuration: CMTime(seconds: span.duration, preferredTimescale: 48000))
            } else {
                try track.insertTimeRange(CMTimeRange(start: CMTimeAdd(range.start, CMTime(seconds: span.source, preferredTimescale: 48000)), duration: CMTime(seconds: span.duration, preferredTimescale: 48000)), of: source, at: at)
            }
        }
    }
}

extension BJJProject {
    var pauseAware: Bool { (json["requiredCapabilities"] as! [String]).contains(BJJReviewTimeline.capability) }
    var reviewTimeline: BJJReviewTimeline { try! BJJReviewTimeline(json, sourceDuration: duration, capable: pauseAware) }
    var reviewNarration: [BJJJSON] { json["reviewNarration"] as? [BJJJSON] ?? [] }
    var allTakes: [BJJJSON] { voiceovers + reviewNarration }
    var outputDuration: Double { reviewTimeline.duration }
}

/// A compound receipt publishes its take and new holds through the existing atomic
/// save journal. It cannot append a take against a different timeline revision.
enum BJJReviewReceipt {
    static func apply(_ receipt: BJJJSON, to document: BJJJSON) throws -> BJJJSON {
        var json = document
        let take = try BJJValidate.object(receipt["take"], "recorded take")
        var takes = json["reviewNarration"] as? [BJJJSON] ?? []
        if takes.contains(where: { $0["id"] as? String == take["id"] as? String }) { return json }
        guard receipt["baseRevision"] as? Int == json["revision"] as? Int else {
            throw BJJError.domain("PROJECT_CONFLICT", "A preserved narration take belongs to an earlier review revision. Preserve a recovery copy before resolving it.")
        }
        var capabilities = json["requiredCapabilities"] as! [String]
        if !capabilities.contains(BJJReviewTimeline.capability) { capabilities.append(BJJReviewTimeline.capability) }
        json["requiredCapabilities"] = capabilities
        let old = (json["reviewTimeline"] as? BJJJSON)?["holds"] as? [BJJJSON] ?? []
        let added = try BJJValidate.objects(receipt["holds"], "recorded pauses", maximum: 2000)
        let holds = (old + added).enumerated().sorted {
            $0.element.n("sourceTicks") == $1.element.n("sourceTicks") ? $0.offset < $1.offset : $0.element.n("sourceTicks") < $1.element.n("sourceTicks")
        }.map { $0.element }
        var timeline = json["reviewTimeline"] as? BJJJSON ?? [:]
        timeline["version"] = 1; timeline["holds"] = holds; json["reviewTimeline"] = timeline
        takes.append(take); json["reviewNarration"] = takes
        return try BJJProject(json).json
    }
}
