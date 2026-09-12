import Foundation
import AVFoundation
import CoreImage
import CoreText
import UIKit

extension Dictionary where Key == String, Value == Any {
    func n(_ key: String) -> Double { (self[key] as! NSNumber).doubleValue }
    func s(_ key: String) -> String { self[key] as! String }
}

struct BJJMedia {
    let asset: AVURLAsset
    let video: AVAssetTrack
    let videoRange: CMTimeRange
    let naturalSize: CGSize
    let orientedSize: CGSize
    let transform: CGAffineTransform
    let fps: Double
    let json: BJJJSON

    static func inspect(_ url: URL, reference: String, originalName: String) async throws -> BJJMedia {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard try await asset.load(.isReadable), let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw BJJError.invalid("This video cannot be decoded on iPhone. Choose a complete MP4 or MOV with H.264 or HEVC video.")
        }
        let range = try await video.load(.timeRange)
        let size = try await video.load(.naturalSize)
        let preferred = try await video.load(.preferredTransform)
        let formats = try await video.load(.formatDescriptions)
        guard let format = formats.first else { throw BJJError.invalid("Video format information is missing.") }
        let coded = CMVideoFormatDescriptionGetDimensions(format)
        let presentation = CMVideoFormatDescriptionGetPresentationDimensions(format, usePixelAspectRatio: true, useCleanAperture: false)
        let sar = presentation.width / max(1, CGFloat(coded.width))
        let transform = CGAffineTransform(scaleX: sar, y: 1).concatenating(preferred)
        let bounds = CGRect(origin: .zero, size: size).applying(transform).standardized
        let oriented = CGSize(width: bounds.width.rounded(), height: bounds.height.rounded())
        let normalized = transform.concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
        let angle = atan2(preferred.b, preferred.a) * 180 / .pi
        guard abs(angle / 90 - (angle / 90).rounded()) < 0.001 else {
            throw BJJError.invalid("This video has a non-right-angle rotation. Rotate it to 0, 90, 180 or 270 degrees before importing.")
        }
        let extensions = (CMFormatDescriptionGetExtensions(format) as NSDictionary?) ?? NSDictionary()
        if let transfer = extensions[kCMFormatDescriptionExtension_TransferFunction] as? String,
           transfer.contains("2084") || transfer.contains("HLG") || transfer.contains("2100") {
            throw BJJError.invalid("HDR footage needs an SDR copy before importing. In iPhone Camera settings, turn off HDR Video for new recordings.")
        }
        let seconds = range.duration.seconds
        guard seconds.isFinite, seconds >= 0.05, seconds <= 86400,
              oriented.width >= 2, oriented.height >= 2, max(oriented.width, oriented.height) <= 4096 else {
            throw BJJError.invalid("Unsupported video duration or dimensions. Use a video up to 4096 pixels on its long edge.")
        }
        let nominal = Double(try await video.load(.nominalFrameRate))
        let fps = nominal > 0 ? nominal : 30
        let audio = try await asset.loadTracks(withMediaType: .audio)
        var audioCodec: Any = NSNull()
        if let first = audio.first {
            let descriptions = try await first.load(.formatDescriptions)
            if let description = descriptions.first { audioCodec = audioCodecName(CMFormatDescriptionGetMediaSubType(description)) }
        }
        let metadata: BJJJSON = [
            "asset": reference, "originalFilename": String(originalName.prefix(240)),
            "durationSec": seconds, "codec": fourCC(CMFormatDescriptionGetMediaSubType(format)),
            "audioCodec": audioCodec, "hasAudio": !audio.isEmpty,
            "codedWidth": Int(coded.width), "codedHeight": Int(coded.height),
            "displayWidth": Int(oriented.width), "displayHeight": Int(oriented.height),
            "sampleAspectRatio": "\(Int((sar * 10000).rounded())):10000",
            "displayAspectRatio": "\(Int(oriented.width)):\(Int(oriented.height))",
            "rotation": angle, "avgFrameRate": fps,
            "videoStartSec": range.start.seconds, "nativeEngine": "AVFoundation"
        ]
        return BJJMedia(asset: asset, video: video, videoRange: range, naturalSize: size,
                        orientedSize: oriented, transform: normalized, fps: fps, json: metadata)
    }
    static func audioCodecName(_ value: AudioFormatID) -> String {
        // Core Audio identifies AAC as 'aac ', not the MP4 sample-entry 'mp4a'.
        // Use the same canonical codec name as FFprobe in desktop projects.
        value == kAudioFormatMPEG4AAC ? "aac" : fourCC(value)
    }
    
    static func fourCC(_ value: FourCharCode) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((value >> $0) & 255) }, encoding: .ascii) ?? "unknown"
    }
}

final class BJJOverlay {
    private var signature = ""
    private var cached: CIImage?
    private let annotations: [BJJJSON]
    private let size: CGSize
    private let fps: Double
    private let fontName: String
    init(annotations: [BJJJSON], size: CGSize, fps: Double) throws {
        self.annotations = annotations.enumerated().sorted {
            if $0.element.n("zIndex") == $1.element.n("zIndex") { return $0.offset < $1.offset }
            return $0.element.n("zIndex") < $1.element.n("zIndex")
        }.map { $0.element }
        self.size = size
        self.fps = fps
        if let url = Bundle.main.url(forResource: "DejaVuSans", withExtension: "ttf", subdirectory: "public/fonts") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        guard UIFont(name: "DejaVuSans", size: 14) != nil else {
            throw BJJError.invalid("The bundled DejaVu Sans font is missing. Rebuild the app with npm run ios:sync.")
        }
        self.fontName = "DejaVuSans"
    }
    func image(at time: Double) -> CIImage? {
        let active = annotations.filter { BJJProject.visible($0, time: time, fps: fps) }
        let next = active.map { $0.s("id") }.joined(separator: ",")
        if next == signature { return cached }
        signature = next
        guard !active.isEmpty else { cached = nil; return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        format.preferredRange = .standard
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { context in
            context.cgContext.setAllowsAntialiasing(true)
            context.cgContext.setShouldAntialias(true)
            context.cgContext.clip(to: CGRect(origin: .zero, size: size))
            for a in active { draw(a, context.cgContext) }
        }
        cached = image.cgImage.map { CIImage(cgImage: $0) }
        return cached
    }
    private func color(_ hex: String, _ alpha: Double) -> UIColor {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return UIColor(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
                       blue: CGFloat(value & 255) / 255, alpha: alpha)
    }
    private func draw(_ a: BJJJSON, _ c: CGContext) {
        let g = a["geometry"] as! BJJJSON
        let smaller = min(size.width, size.height)
        let stroke = color(a.s("strokeColor"), a.n("strokeOpacity"))
        let fill = color(a.s("fillColor"), a.n("fillOpacity"))
        func point(_ x: String, _ y: String) -> CGPoint { CGPoint(x: g.n(x) * size.width, y: g.n(y) * size.height) }
        c.saveGState(); defer { c.restoreGState() }
        c.setStrokeColor(stroke.cgColor)
        c.setFillColor(fill.cgColor)
        c.setLineWidth(a.n("strokeWidth") * smaller)
        c.setLineCap(.round); c.setLineJoin(.round)
        switch a.s("type") {
        case "line", "arrow":
            let p = point("x1", "y1"), q = point("x2", "y2")
            c.move(to: p); c.addLine(to: q); c.strokePath()
            if a.s("type") == "arrow" {
                let length = g.n("arrowheadSize") * smaller
                let angle = atan2(q.y - p.y, q.x - p.x)
                let x = q.x - length * cos(angle), y = q.y - length * sin(angle)
                c.move(to: q)
                c.addLine(to: CGPoint(x: x - length * sin(angle) / 2, y: y + length * cos(angle) / 2))
                c.addLine(to: CGPoint(x: x + length * sin(angle) / 2, y: y - length * cos(angle) / 2))
                c.closePath(); c.setFillColor(stroke.cgColor); c.drawPath(using: .fillStroke)
            }
        case "rectangle":
            let rect = CGRect(x: g.n("x") * size.width, y: g.n("y") * size.height,
                              width: g.n("width") * size.width, height: g.n("height") * size.height)
            c.fill(rect); c.stroke(rect)
        case "ellipse":
            let rect = CGRect(x: (g.n("centerX") - g.n("radiusX")) * size.width,
                              y: (g.n("centerY") - g.n("radiusY")) * size.height,
                              width: g.n("radiusX") * 2 * size.width, height: g.n("radiusY") * 2 * size.height)
            c.fillEllipse(in: rect); c.strokeEllipse(in: rect)
        case "freehand":
            let points = g["points"] as! [BJJJSON]
            c.move(to: CGPoint(x: points[0].n("x") * size.width, y: points[0].n("y") * size.height))
            for p in points.dropFirst() { c.addLine(to: CGPoint(x: p.n("x") * size.width, y: p.n("y") * size.height)) }
            c.strokePath()
        case "text":
            let font = UIFont(name: fontName, size: g.n("fontSize") * smaller)!
            let lines = g.s("text").components(separatedBy: "\n")
            let widths = lines.map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            let width = max(1, widths.max() ?? 1)
            let lineHeight = font.pointSize * 1.2
            let alignment = g.s("alignment")
            let factor: CGFloat = alignment == "center" ? 0.5 : alignment == "right" ? 1 : 0
            let x = g.n("x") * size.width - width * factor
            let y = g.n("y") * size.height
            c.setFillColor(color(g.s("backgroundColor"), g.n("backgroundOpacity")).cgColor)
            c.fill(CGRect(x: x, y: y, width: width, height: CGFloat(lines.count) * lineHeight))
            for (index, line) in lines.enumerated() {
                (line as NSString).draw(at: CGPoint(x: x + (width - widths[index]) * factor,
                                                    y: y + CGFloat(index) * lineHeight),
                                          withAttributes: [.font: font, .foregroundColor: stroke])
            }
        default: break // BJJProject validation rejects unknown annotation types.
        }
    }
}

/// Bounded, streaming AVAssetReader → Core Image overlay → H.264/AAC AVAssetWriter.
/// Only one active overlay state and the encoder's pixel buffers are held in memory.
final class BJJRenderer {
    private let lock = NSLock()
    private var cancelled = false
    private var reader: AVAssetReader?
    private var writer: AVAssetWriter?
    private var inputs: [AVAssetWriterInput] = []
    private var completion: ((Result<Void, Error>) -> Void)?
    private var finishedStreams = 0
    private var expectedStreams = 1
    private var finished = false
    private var monitor: DispatchSourceTimer?
    private var endTime = CMTime.zero
    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        complete(.failure(BJJError.cancelled))
    }
    private func complete(_ result: Result<Void, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        guard let handler = completion else { lock.unlock(); return }
        finished = true
        completion = nil
        let reader = self.reader, writer = self.writer
        self.reader = nil; self.writer = nil; self.inputs = []
        let monitor = self.monitor
        self.monitor = nil
        lock.unlock()
        monitor?.cancel()
        if case .failure = result { reader?.cancelReading(); writer?.cancelWriting() }
        handler(result)
    }
    private func endedStream() {
        lock.lock()
        finishedStreams += 1
        let done = finishedStreams == expectedStreams && !finished
        let writer = self.writer
        lock.unlock()
        if done {
            if writer?.status == .writing { writer?.endSession(atSourceTime: endTime) }
            writer?.finishWriting { [self] in
                if writer?.status == .completed { complete(.success(Void())) }
                else { complete(.failure(writer?.error ?? BJJError.invalid("Video encoding did not complete."))) }
            }
        }
    }
    private func shouldStop() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled || finished
    }
    static func outputSize(_ source: CGSize, maximum: CGFloat? = nil) -> CGSize {
        let scale = maximum.map { min(1, $0 / max(source.width, source.height)) } ?? 1
        return CGSize(width: max(2, (source.width * scale / 2).rounded(.toNearestOrEven) * 2),
                      height: max(2, (source.height * scale / 2).rounded(.toNearestOrEven) * 2))
    }
    func render(media: BJJMedia, project: BJJProject?, store: BJJStore, output: URL,
                proxy: Bool = false, progress: @escaping (Double) -> Void) async throws {
        let duration = media.videoRange.duration
        let fps = min(60, project?.exportSettings.n("fps") ?? min(30, media.fps))
        let size = Self.outputSize(media.orientedSize, maximum: proxy ? 1920 : nil)
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw BJJError.invalid("Unable to prepare a video track.")
        }
        try video.insertTimeRange(media.videoRange, of: media.video, at: .zero)
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
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = size
        videoComposition.frameDuration = CMTime(seconds: 1 / fps, preferredTimescale: 60000)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: video)
        layer.setTransform(media.transform.concatenating(CGAffineTransform(scaleX: size.width / media.orientedSize.width,
                                                                          y: size.height / media.orientedSize.height)), at: .zero)
        instruction.layerInstructions = [layer]
        videoComposition.instructions = [instruction]
        let reader = try AVAssetReader(asset: composition)
        reader.timeRange = CMTimeRange(start: .zero, duration: duration)
        let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: [video], videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        videoOutput.videoComposition = videoComposition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw BJJError.invalid("This video cannot be prepared for rendering.") }
        reader.add(videoOutput)
        var audioOutput: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ])
            let mix = AVMutableAudioMix(); mix.inputParameters = audioParameters; output.audioMix = mix
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw BJJError.invalid("The audio mix could not be prepared.") }
            reader.add(output); audioOutput = output
        }
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let quality = project?.exportSettings.n("crf") ?? 23
        let bitrate = Int(min(60_000_000, max(1_000_000, Double(size.width * size.height) * fps * 0.12 * pow(2, (23 - quality) / 6))))
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: fps, AVVideoMaxKeyFrameIntervalKey: Int(fps * 2)]
        ])
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        guard writer.canAdd(videoInput) else { throw BJJError.invalid("H.264 export is not available for this resolution.") }
        writer.add(videoInput)
        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192000])
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw BJJError.invalid("AAC audio export could not be prepared.") }
            writer.add(input); audioInput = input
        }
        let overlay = try BJJOverlay(annotations: project?.annotations ?? [], size: size, fps: fps)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: colorSpace])
        self.reader = reader; self.writer = writer
        self.inputs = [videoInput] + (audioInput.map { [$0] } ?? [])
        endTime = duration
        expectedStreams = audioInput == nil ? 1 : 2
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock(); completion = { continuation.resume(with: $0) }; let wasCancelled = cancelled; lock.unlock()
            if wasCancelled { complete(.failure(BJJError.cancelled)); return }
            guard writer.startWriting(), reader.startReading() else {
                complete(.failure(reader.error ?? writer.error ?? BJJError.invalid("The encoder could not start."))); return
            }
            writer.startSession(atSourceTime: .zero)
            // Failed encoders can stop requesting input. Observe their machine state
            // so an I/O or codec failure always settles the export promise.
            let monitor = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "bjj.encode.status"))
            monitor.schedule(deadline: .now() + 1, repeating: 1)
            monitor.setEventHandler { [weak self] in
                if writer.status == .failed || reader.status == .failed {
                    self?.complete(.failure(writer.error ?? reader.error ?? BJJError.invalid("Media encoding failed.")))
                }
            }
            lock.lock(); self.monitor = monitor; lock.unlock()
            monitor.resume()
            var videoEnded = false
            var lastProgress = -1.0
            videoInput.requestMediaDataWhenReady(on: DispatchQueue(label: "bjj.encode.video")) { [self] in
                while videoInput.isReadyForMoreMediaData && !videoEnded && !shouldStop() {
                    autoreleasepool {
                        guard let sample = videoOutput.copyNextSampleBuffer() else {
                            videoEnded = true
                            if reader.status == .failed { complete(.failure(reader.error ?? BJJError.invalid("Video decoding failed."))) }
                            else { videoInput.markAsFinished(); endedStream() }
                            return
                        }
                        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                        guard let source = CMSampleBufferGetImageBuffer(sample), let pool = adaptor.pixelBufferPool else {
                            complete(.failure(BJJError.invalid("A decoded video frame is unavailable."))); return
                        }
                        var destination: CVPixelBuffer?
                        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &destination) == kCVReturnSuccess, let destination else {
                            complete(.failure(BJJError.invalid("Not enough memory to render this resolution."))); return
                        }
                        var image = CIImage(cvPixelBuffer: source)
                        if let overlayImage = overlay.image(at: pts.seconds) { image = overlayImage.composited(over: image) }
                        context.render(image, to: destination, bounds: CGRect(origin: .zero, size: size), colorSpace: colorSpace)
                        guard adaptor.append(destination, withPresentationTime: pts) else {
                            complete(.failure(writer.error ?? BJJError.invalid("Unable to encode a video frame."))); return
                        }
                        if pts.seconds - lastProgress >= 0.2 { lastProgress = pts.seconds; progress(pts.seconds) }
                    }
                }
            }
            if let audioInput, let audioOutput {
                var audioEnded = false
                audioInput.requestMediaDataWhenReady(on: DispatchQueue(label: "bjj.encode.audio")) { [self] in
                    while audioInput.isReadyForMoreMediaData && !audioEnded && !shouldStop() {
                        autoreleasepool {
                            guard let sample = audioOutput.copyNextSampleBuffer() else {
                                audioEnded = true
                                if reader.status == .failed { complete(.failure(reader.error ?? BJJError.invalid("Audio decoding failed."))) }
                                else { audioInput.markAsFinished(); endedStream() }
                                return
                            }
                            do {
                                let scaled = try BJJAudio.scale(sample, gain: Float(mixScale))
                                if !audioInput.append(scaled) { complete(.failure(writer.error ?? BJJError.invalid("Unable to encode the audio mix."))) }
                            } catch { complete(.failure(error)) }
                        }
                    }
                }
            }
        }
        progress(duration.seconds)
    }
}

enum BJJAudio {
    static func scale(_ sample: CMSampleBuffer, gain: Float) throws -> CMSampleBuffer {
        guard let source = CMSampleBufferGetDataBuffer(sample), let format = CMSampleBufferGetFormatDescription(sample) else {
            throw BJJError.invalid("An audio sample could not be decoded.")
        }
        let length = CMBlockBufferGetDataLength(source)
        guard length > 0, length % MemoryLayout<Float>.size == 0 else { throw BJJError.invalid("Invalid decoded audio sample size.") }
        var values = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
        let read = values.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(source, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
        guard read == kCMBlockBufferNoErr else { throw BJJError.invalid("The decoded audio buffer is unavailable.") }
        for index in values.indices { values[index] = min(0.98, max(-0.98, values[index] * gain)) }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: length,
            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == kCMBlockBufferNoErr, let block else {
            throw BJJError.invalid("Unable to allocate an audio buffer.")
        }
        let copied = values.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length) }
        guard copied == kCMBlockBufferNoErr else { throw BJJError.invalid("Unable to prepare the audio mix.") }
        var result: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault,
            dataBuffer: block, formatDescription: format, sampleCount: CMSampleBufferGetNumSamples(sample),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sample), packetDescriptions: nil, sampleBufferOut: &result)
        guard status == noErr, let result else { throw BJJError.invalid("Unable to encode a mixed audio sample.") }
        return result
    }
}
