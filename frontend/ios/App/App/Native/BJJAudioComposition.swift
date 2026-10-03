import Foundation
import AVFoundation

struct BJJAudioComposition {
    let tracks: [AVCompositionTrack]
    let parameters: [AVAudioMixInputParameters]
    let scale: Double
    let temporaryFiles: [URL]
    var output: AVAssetReaderAudioMixOutput? {
        guard !tracks.isEmpty else { return nil }
        let result = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false])
        let mix = AVMutableAudioMix(); mix.inputParameters = parameters
        result.audioMix = mix; result.alwaysCopiesSampleData = false
        return result
    }
    static func build(media: BJJMedia, project: BJJProject?, store: BJJStore,
                      composition: AVMutableComposition) async throws -> BJJAudioComposition {
        let timeline = project?.reviewTimeline ?? BJJReviewTimeline(sourceDuration: media.videoRange.duration.seconds)
        var audioTracks: [AVCompositionTrack] = []
        var audioParameters: [AVAudioMixInputParameters] = []
        let muted = project.map { $0.settings["originalAudioMuted"] as! Bool } ?? false
        let originalGain: Float = muted ? 0 : Float(project?.settings.n("originalAudioGain") ?? 1)
        let totalVoiceGain = project.map { p in p.allTakes.filter { !($0["muted"] as! Bool) }.map { $0.n("gain") * p.settings.n("voiceoverMasterGain") }.reduce(0, +) } ?? 0
        let mixScale = max(1, Double(originalGain) + totalVoiceGain)
        func track(gain: Double) throws -> AVMutableCompositionTrack {
            guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw BJJError.invalid("Cannot prepare an audio track.") }
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.setVolume(Float(gain / mixScale), at: .zero)
            audioParameters.append(parameters); audioTracks.append(track)
            return track
        }
        func insert(_ track: AVMutableCompositionTrack, source: AVAssetTrack, audioStart: Double, outputStart: Double, duration: Double) throws {
            guard duration > 0 else { return }
            try track.insertTimeRange(CMTimeRange(start: CMTime(seconds: audioStart, preferredTimescale: 48000), duration: CMTime(seconds: duration, preferredTimescale: 48000)), of: source, at: CMTime(seconds: outputStart, preferredTimescale: 48000))
        }
        for source in try await media.asset.loadTracks(withMediaType: .audio).prefix(1) {
            let range = try await source.load(.timeRange), target = try track(gain: Double(originalGain))
            for span in timeline.spans where span.hold == nil {
                let first = max(span.source, range.start.seconds - media.videoRange.start.seconds)
                let last = min(span.source + span.duration, CMTimeRangeGetEnd(range).seconds - media.videoRange.start.seconds)
                try insert(target, source: source, audioStart: media.videoRange.start.seconds + first, outputStart: span.output + first - span.source, duration: last - first)
            }
        }
        if let project {
            for clip in project.allTakes where !(clip["muted"] as! Bool) && clip.n("gain") * project.settings.n("voiceoverMasterGain") > 0 {
                let asset = AVURLAsset(url: try store.asset(project.id, clip.s("asset")))
                guard let source = try await asset.loadTracks(withMediaType: .audio).first else { throw BJJError.invalid("A narration take cannot be decoded.") }
                let sourceRange = try await source.load(.timeRange)
                let target = try track(gain: clip.n("gain") * project.settings.n("voiceoverMasterGain"))
                if let placements = clip["placements"] as? [BJJJSON] {
                    for placement in placements {
                        let length = placement.n("durationTicks") / 48000, audio = placement.n("audioStartTicks") / 48000
                        if placement["holdId"] != nil {
                            guard let start = timeline.position(placement) else { throw BJJError.invalid("A narration pause is missing.") }
                            try insert(target, source: source, audioStart: sourceRange.start.seconds + audio, outputStart: start, duration: length)
                        } else {
                            let anchor = placement.n("sourceTicks") / 48000
                            for span in timeline.spans where span.hold == nil {
                                let first = max(anchor, span.source), last = min(anchor + length, span.source + span.duration)
                                try insert(target, source: source, audioStart: sourceRange.start.seconds + audio + first - anchor, outputStart: span.output + first - span.source, duration: last - first)
                            }
                        }
                    }
                } else {
                    let anchor = clip.n("startSec") + clip.n("timingOffsetMs") / 1000
                    let length = min(clip.n("durationSec"), sourceRange.duration.seconds)
                    for span in timeline.spans where span.hold == nil {
                        let first = max(anchor, span.source), last = min(anchor + length, span.source + span.duration)
                        try insert(target, source: source, audioStart: sourceRange.start.seconds + first - anchor, outputStart: span.output + first - span.source, duration: last - first)
                    }
                }
            }
        }
        var temporaryFiles: [URL] = []
        if !timeline.holds.isEmpty, !audioTracks.isEmpty, let project {
            let path = try store.safeURL(project.id, "temp/silence-\(UUID().uuidString).caf")
            do {
                try await BJJAssets.offMain {
                    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
                    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
                    buffer.frameLength = 4800; buffer.floatChannelData![0].initialize(repeating: 0, count: 4800)
                    let file = try AVAudioFile(forWriting: path, settings: format.settings); try file.write(from: buffer)
                }
                let silence = AVURLAsset(url: path)
                guard let source = try await silence.loadTracks(withMediaType: .audio).first else { throw BJJError.invalid("Cannot prepare review silence.") }
                let range = try await source.load(.timeRange), target = try track(gain: 0)
                try target.insertTimeRange(range, of: source, at: .zero)
                target.scaleTimeRange(CMTimeRange(start: .zero, duration: range.duration), toDuration: CMTime(seconds: timeline.duration, preferredTimescale: 48000))
                temporaryFiles.append(path)
            } catch { try? FileManager.default.removeItem(at: path); throw error }
        }
        return BJJAudioComposition(tracks: audioTracks, parameters: audioParameters, scale: mixScale, temporaryFiles: temporaryFiles)
    }

    /// Decode the same normalized mix and limiter used by export. Stream into PCM
    /// with bounded memory; a silent bed preserves gaps and the project clock.
    @MainActor static func preview(project: BJJProject, store: BJJStore, target: URL) async throws -> AVPlayerItem {
        let media = try await BJJMedia.inspect(store.asset(project.id, project.source.s("asset")),
                                              reference: project.source.s("asset"), originalName: project.name)
        let composition = AVMutableComposition()
        let audio = try await build(media: media, project: project, store: store, composition: composition)
        defer { for path in audio.temporaryFiles { try? FileManager.default.removeItem(at: path) } }
        let proxy = AVURLAsset(url: try store.asset(project.id, project.proxy.s("asset")))
        let videoComposition = AVMutableComposition()
        guard let sourceVideo = try await proxy.loadTracks(withMediaType: .video).first,
              let video = videoComposition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw BJJError.invalid("The preview video is unavailable.")
        }
        try await project.reviewTimeline.insertVideo(sourceVideo, range: CMTimeRange(start: .zero, duration: CMTime(seconds: project.duration, preferredTimescale: 48000)), into: video)
        video.preferredTransform = try await sourceVideo.load(.preferredTransform)
        if let output = audio.output {
            try store.checkSpace(required: Int64(project.outputDuration * 48000 * 8) + 100_000_000)
            try await BJJAssets.offMain {
                let reader = try AVAssetReader(asset: composition)
                reader.add(output)
                reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: project.outputDuration, preferredTimescale: 48000))
                guard reader.startReading() else { throw reader.error ?? BJJError.invalid("Cannot prepare narration preview.") }
                let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
                let file = try AVAudioFile(forWriting: target, settings: format.settings)
                var cursor: Int64 = 0
                func silence(until frame: Int64) throws {
                    while cursor < frame {
                        let count = AVAudioFrameCount(min(4096, frame - cursor))
                        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
                        buffer.frameLength = count
                        for channel in 0..<2 { buffer.floatChannelData![channel].initialize(repeating: 0, count: Int(count)) }
                        try file.write(from: buffer); cursor += Int64(count)
                    }
                }
                while let sample = output.copyNextSampleBuffer() {
                    try autoreleasepool {
                        let scaled = try BJJAudio.scale(sample, gain: Float(audio.scale))
                        let frames = CMSampleBufferGetNumSamples(scaled)
                        let first = Int64((CMSampleBufferGetPresentationTimeStamp(scaled).seconds * 48000).rounded())
                        try silence(until: max(0, first))
                        guard let block = CMSampleBufferGetDataBuffer(scaled) else { throw BJJError.invalid("Missing mixed audio.") }
                        var values = [Float](repeating: 0, count: frames * 2)
                        let status = values.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: frames * 8, destination: $0.baseAddress!) }
                        guard status == noErr else { throw BJJError.invalid("Cannot read mixed audio.") }
                        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
                        buffer.frameLength = AVAudioFrameCount(frames)
                        for frame in 0..<frames { for channel in 0..<2 { buffer.floatChannelData![channel][frame] = values[frame * 2 + channel] } }
                        try file.write(from: buffer); cursor += Int64(frames)
                    }
                }
                guard reader.status == .completed else { throw reader.error ?? BJJError.invalid("Narration preview did not finish.") }
                try silence(until: Int64((project.outputDuration * 48000).rounded()))
            }
            let asset = AVURLAsset(url: target)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first,
                  let track = videoComposition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw BJJError.invalid("Cannot open narration preview.") }
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: project.outputDuration, preferredTimescale: 48000)), of: source, at: .zero)
        }
        let item = AVPlayerItem(asset: videoComposition)
        item.audioTimePitchAlgorithm = .spectral
        return item
    }
}
