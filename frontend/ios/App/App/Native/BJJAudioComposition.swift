import Foundation
import AVFoundation

struct BJJAudioComposition {
    let tracks: [AVCompositionTrack]
    let parameters: [AVAudioMixInputParameters]
    let scale: Double
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
        let duration = media.videoRange.duration
        var audioTracks: [AVCompositionTrack] = []
        var audioParameters: [AVAudioMixInputParameters] = []
        let muted = project.map { $0.settings["originalAudioMuted"] as! Bool } ?? false
        let originalGain: Float = muted ? 0 : Float(project?.settings.n("originalAudioGain") ?? 1)
        // AVAudioMix volume is documented in [0, 1]. Normalize there, then apply
        // the common gain to decoded float PCM before AAC encoding.
        let totalVoiceGain = project.map { p in p.voiceovers.filter { !($0["muted"] as! Bool) }.map { $0.n("gain") * p.settings.n("voiceoverMasterGain") }.reduce(0, +) } ?? 0
        let mixScale = max(1, Double(originalGain) + totalVoiceGain)
        let originalTracks = try await media.asset.loadTracks(withMediaType: .audio)
        for sourceAudio in originalTracks.prefix(1) {
            let range = try await sourceAudio.load(.timeRange)
            let shared = CMTimeRangeGetIntersection(range, otherRange: media.videoRange)
            guard shared.isValid, shared.duration.seconds > 0,
                  let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try track.insertTimeRange(shared, of: sourceAudio, at: CMTimeSubtract(shared.start, media.videoRange.start))
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.setVolume(originalGain / Float(mixScale), at: .zero)
            audioParameters.append(parameters); audioTracks.append(track)
        }
        if let project {
            for clip in project.voiceovers where !(clip["muted"] as! Bool) && clip.n("gain") * project.settings.n("voiceoverMasterGain") > 0 {
                let url = try store.asset(project.id, clip.s("asset"))
                let asset = AVURLAsset(url: url)
                guard let source = try await asset.loadTracks(withMediaType: .audio).first,
                      let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    throw BJJError.invalid("A voiceover cannot be decoded.")
                }
                let sourceRange = try await source.load(.timeRange)
                let start = clip.n("startSec") + clip.n("timingOffsetMs") / 1000
                let length = min(clip.n("durationSec"), min(sourceRange.duration.seconds, max(0, duration.seconds - start)))
                guard length > 0 else { continue }
                let range = CMTimeRange(start: sourceRange.start, duration: CMTime(seconds: length, preferredTimescale: 48000))
                try track.insertTimeRange(range, of: source, at: CMTime(seconds: start, preferredTimescale: 48000))
                let parameters = AVMutableAudioMixInputParameters(track: track)
                parameters.setVolume(Float(clip.n("gain") * project.settings.n("voiceoverMasterGain") / mixScale), at: .zero)
                audioParameters.append(parameters); audioTracks.append(track)
            }
        }
        return BJJAudioComposition(tracks: audioTracks, parameters: audioParameters, scale: mixScale)
    }

    /// Decode the same normalized mix and limiter used by export. Stream into PCM
    /// with bounded memory; a silent bed preserves gaps and the project clock.
    @MainActor static func preview(project: BJJProject, store: BJJStore, target: URL) async throws -> AVPlayerItem {
        let media = try await BJJMedia.inspect(store.asset(project.id, project.source.s("asset")),
                                              reference: project.source.s("asset"), originalName: project.name)
        let composition = AVMutableComposition()
        let audio = try await build(media: media, project: project, store: store, composition: composition)
        let proxy = AVURLAsset(url: try store.asset(project.id, project.proxy.s("asset")))
        let videoComposition = AVMutableComposition()
        guard let sourceVideo = try await proxy.loadTracks(withMediaType: .video).first,
              let video = videoComposition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw BJJError.invalid("The preview video is unavailable.")
        }
        try video.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: project.duration, preferredTimescale: 60000)), of: sourceVideo, at: .zero)
        video.preferredTransform = try await sourceVideo.load(.preferredTransform)
        if let output = audio.output {
            try store.checkSpace(required: Int64(project.duration * 48000 * 8) + 100_000_000)
            try await BJJAssets.offMain {
                let reader = try AVAssetReader(asset: composition)
                reader.add(output)
                reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: project.duration, preferredTimescale: 48000))
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
                try silence(until: Int64((project.duration * 48000).rounded()))
            }
            let asset = AVURLAsset(url: target)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first,
                  let track = videoComposition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw BJJError.invalid("Cannot open narration preview.") }
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: project.duration, preferredTimescale: 48000)), of: source, at: .zero)
        }
        let item = AVPlayerItem(asset: videoComposition)
        item.audioTimePitchAlgorithm = .spectral
        return item
    }
}
