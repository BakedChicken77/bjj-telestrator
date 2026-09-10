import XCTest
import AVFoundation
import CoreImage
import CryptoKit
@testable import App

@MainActor final class BJJNativeTests: XCTestCase {
    private var root: URL!
    private var store: BJJStore!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = try BJJStore(root: root)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func annotation(start: Double = 1, end: Double = 2) -> BJJJSON {
        ["id": UUID().uuidString.lowercased(), "type": "rectangle", "startSec": start, "endSec": end,
         "zIndex": 1, "strokeColor": "#ff0000", "strokeWidth": 0.02, "strokeOpacity": 1.0,
         "fillColor": "#ff0000", "fillOpacity": 1.0,
         "geometry": ["x": 0.1, "y": 0.1, "width": 0.4, "height": 0.4],
         "createdAt": BJJProject.now(), "updatedAt": BJJProject.now()]
    }
    private func project() throws -> BJJProject {
        let (id, folder) = try store.createDirectory()
        try Data([0]).write(to: folder.appendingPathComponent("source/input.mp4"))
        try Data([0]).write(to: folder.appendingPathComponent("proxy/input.mp4"))
        let media: BJJJSON = ["asset": "source/input.mp4", "originalFilename": "input.mp4", "durationSec": 4.0,
             "codec": "avc1", "audioCodec": NSNull(), "hasAudio": false, "codedWidth": 320, "codedHeight": 180,
             "displayWidth": 320, "displayHeight": 180, "sampleAspectRatio": "1:1", "displayAspectRatio": "16:9",
             "rotation": 0, "avgFrameRate": 30.0]
        var proxy = media; proxy["asset"] = "proxy/input.mp4"
        let result = try BJJProject(["schemaVersion": 1, "projectId": id, "projectName": "Native acceptance",
             "createdAt": BJJProject.now(), "updatedAt": BJJProject.now(), "source": media, "proxy": proxy,
             "settings": ["defaultAnnotationDuration": 5.0, "seekStepSec": 0.1, "largeSeekStepSec": 1.0,
                          "originalAudioGain": 1.0, "originalAudioMuted": false, "voiceoverMasterGain": 1.0],
             "exportSettings": ["fps": 30.0, "crf": 23, "preset": "medium"],
             "annotations": [annotation()], "voiceovers": [BJJJSON]()])
        return try store.save(result, creating: true)
    }
    func testHalfOpenFrameBoundaries() {
        let a = annotation()
        XCTAssertFalse(BJJProject.visible(a, time: 29.0 / 30, fps: 30))
        XCTAssertTrue(BJJProject.visible(a, time: 1, fps: 30))
        XCTAssertTrue(BJJProject.visible(a, time: 59.0 / 30, fps: 30))
        XCTAssertFalse(BJJProject.visible(a, time: 2, fps: 30))
        let fractional = annotation(start: 1.01, end: 1.99)
        XCTAssertFalse(BJJProject.visible(fractional, time: 1, fps: 30))
        XCTAssertTrue(BJJProject.visible(fractional, time: 31.0 / 30, fps: 30))
    }
    func testSchemaUnknownFieldsGeometryAndDuplicateIDs() throws {
        var json = try project().json
        json["futureOption"] = ["keep": true]
        let saved = try store.save(BJJProject(json))
        XCTAssertEqual((try store.load(saved.id).json["futureOption"] as? BJJJSON)?["keep"] as? Bool, true)
        var a = annotation(); a["geometry"] = ["x": 0.9, "y": 0.1, "width": 0.4, "height": 0.2]
        json["annotations"] = [a]; XCTAssertThrowsError(try BJJProject(json))
        a = annotation(); json["annotations"] = [a, a]; XCTAssertThrowsError(try BJJProject(json))
        a["startSec"] = true; json["annotations"] = [a]; XCTAssertThrowsError(try BJJProject(json))
    }
    func testPathTraversalAndImmutableSource() throws {
        let p = try project()
        XCTAssertThrowsError(try store.directory("../escape"))
        XCTAssertThrowsError(try store.asset(p.id, "../../escape"))
        let outside = root.appendingPathComponent("outside.mp4"); try Data([1]).write(to: outside)
        let link = try store.directory(p.id).appendingPathComponent("source/link.mp4")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try store.asset(p.id, "source/link.mp4"))
        var changed = p.json, source = p.source
        source["codedWidth"] = 42; changed["source"] = source
        XCTAssertThrowsError(try store.save(BJJProject(changed)))
    }
    func testByteRangeParsing() throws {
        XCTAssertEqual(try BJJByteRange.parse("bytes=20-29", size: 100), BJJByteRange(first: 20, last: 29))
        XCTAssertEqual(try BJJByteRange.parse("bytes=-10", size: 100), BJJByteRange(first: 90, last: 99))
        XCTAssertEqual(try BJJByteRange.parse("bytes=90-", size: 100).count, 10)
        XCTAssertThrowsError(try BJJByteRange.parse("bytes=100-", size: 100))
        XCTAssertThrowsError(try BJJByteRange.parse("bytes=0-9,20-29", size: 100))
    }
    private func tone(_ url: URL, frequency: Double, duration: Double) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(duration * 48000))!
        buffer.frameLength = buffer.frameCapacity
        for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][i] = Float(0.2 * sin(2 * .pi * frequency * Double(i) / 48000)) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
    private func clip(_ p: BJJProject) throws -> BJJJSON {
        let id = UUID().uuidString.lowercased(), reference = "voiceover/\(UUID().uuidString.lowercased()).wav"
        try tone(store.directory(p.id).appendingPathComponent(reference), frequency: 880, duration: 1)
        let value: BJJJSON = ["id": id, "asset": reference, "startSec": 1.0, "durationSec": 1.0, "endSec": 2.0,
            "gain": 1.0, "muted": false, "timingOffsetMs": 125.0, "recordedAt": BJJProject.now(),
            "codec": "pcm_f32le", "sampleRate": 48000, "channels": 1]
        try store.registerClip(p.id, clip: value)
        return value
    }
    func testInterruptedRecordingSurvivesStaleSaveAndUndoSafeRemoval() throws {
        let p = try project(); let take = try clip(p)
        _ = try store.save(p)
        let reopened = try BJJStore(root: root).load(p.id)
        XCTAssertEqual(reopened.voiceovers.count, 1)
        _ = try store.save(reopened)
        _ = try store.save(p)
        XCTAssertEqual(try store.load(p.id).voiceovers.count, 0)
        XCTAssertNoThrow(try store.asset(p.id, take.s("asset")))
        _ = try store.save(reopened)
        XCTAssertEqual(try store.load(p.id).voiceovers.count, 1)
    }
    private func silentVideo(_ url: URL, rotated: Bool = false) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 320, AVVideoHeightKey: 180])
        if rotated { input.transform = CGAffineTransform(translationX: 180, y: 0).rotated(by: .pi / 2) }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error! }
        writer.startSession(atSourceTime: .zero)
        for i in 0..<120 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let frame = buffer!
            CVPixelBufferLockBaseAddress(frame, [])
            let bytes = CVPixelBufferGetBaseAddress(frame)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(frame)
            for y in 0..<180 { for x in 0..<320 {
                let p = y * stride + x * 4
                bytes[p] = 80; bytes[p + 1] = 45; bytes[p + 2] = 20; bytes[p + 3] = 255
            } }
            CVPixelBufferUnlockBaseAddress(frame, [])
            guard adaptor.append(frame, withPresentationTime: CMTime(value: Int64(i), timescale: 30)) else { throw writer.error! }
        }
        input.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in writer.finishWriting { continuation.resume() } }
        guard writer.status == .completed else { throw writer.error! }
    }
    private func sourceVideo(rotated: Bool = false, audio: Bool = false) async throws -> URL {
        let video = root.appendingPathComponent("\(UUID().uuidString).mp4")
        try await silentVideo(video, rotated: rotated)
        guard audio else { return video }
        let wave = root.appendingPathComponent("tone.wav"); try tone(wave, frequency: 440, duration: 4)
        let composition = AVMutableComposition()
        for (url, type) in [(video, AVMediaType.video), (wave, AVMediaType.audio)] {
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: type)
            let source = try XCTUnwrap(tracks.first)
            let track = composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid)!
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 4, preferredTimescale: 48000)), of: source, at: .zero)
        }
        let output = root.appendingPathComponent("with-audio.mp4")
        let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)!
        session.outputURL = output; session.outputFileType = .mp4
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in session.exportAsynchronously { continuation.resume() } }
        guard session.status == .completed else { throw session.error! }
        return output
    }
    private func redPixels(_ url: URL, time: Double) throws -> Int {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let image = try generator.copyCGImage(at: CMTime(seconds: time, preferredTimescale: 600), actualTime: nil)
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        return data.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let pixels = bytes.bindMemory(to: UInt8.self)
            return stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0] > 180 && pixels[$0 + 1] < 80 && pixels[$0 + 2] < 80 }.count
        }
    }
    func testRealNativeMP4ExportBurnsTimedPixelsAndPreservesSourceAudio() async throws {
        let source = try await sourceVideo(audio: true)
        let before = SHA256.hash(data: try Data(contentsOf: source))
        let service = try BJJService(store: store)
        let imported = try await service.importFile(source, originalName: "synthetic.mp4")
        var json = imported.json; json["annotations"] = [annotation()]
        let project = try store.save(BJJProject(json))
        let job = try service.createExport(project.id)
        let deadline = Date().addingTimeInterval(90)
        while ["queued", "running"].contains(try service.job(job.jobId).status) && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(try service.job(job.jobId).status, "completed", try service.job(job.jobId).error ?? "")
        let output = try service.exportedFile(job.jobId)
        let result = try await BJJMedia.inspect(output, reference: "exports/result.mp4", originalName: "result.mp4")
        XCTAssertEqual(result.json.s("codec"), "avc1")
        XCTAssertEqual(result.json["audioCodec"] as? String, "mp4a")
        XCTAssertEqual(result.orientedSize, CGSize(width: 320, height: 180))
        XCTAssertEqual(result.videoRange.duration.seconds, 4, accuracy: 0.1)
        XCTAssertEqual(try redPixels(output, time: 0.5), 0)
        XCTAssertGreaterThan(try redPixels(output, time: 1), 500)
        XCTAssertEqual(try redPixels(output, time: 2), 0)
        XCTAssertEqual(before, SHA256.hash(data: try Data(contentsOf: source)))
        let originalAudioEnergy = try await audioEnergy(output, from: 0.2, to: 0.8)
        XCTAssertGreaterThan(originalAudioEnergy, 0.05)
        XCTAssertEqual(try BJJStore(root: root).load(project.id).annotations.count, 1)
    }
    func testRotatedSilentVideoExportsPortrait() async throws {
        let source = try await sourceVideo(rotated: true)
        let media = try await BJJMedia.inspect(source, reference: "source/a.mp4", originalName: "a.mp4")
        XCTAssertEqual(media.orientedSize, CGSize(width: 180, height: 320))
        let output = root.appendingPathComponent("portrait.mp4")
        try await BJJRenderer().render(media: media, project: nil, store: store, output: output) { _ in }
        let probe = try await BJJMedia.inspect(output, reference: "exports/portrait.mp4", originalName: "portrait.mp4")
        XCTAssertEqual(probe.orientedSize, CGSize(width: 180, height: 320))
        XCTAssertEqual(probe.json["hasAudio"] as? Bool, false)
        XCTAssertEqual(probe.json.n("rotation"), 0, accuracy: 0.01)
    }
    private func audioEnergy(_ url: URL, from: Double, to: Double) async throws -> Double {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2])
        reader.add(output); reader.startReading()
        var energy = 0.0, count = 0
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let bytes = CMBlockBufferGetDataLength(block)
            var values = [Float](repeating: 0, count: bytes / MemoryLayout<Float>.size)
            _ = values.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!) }
            let start = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            for frame in 0..<(values.count / 2) {
                let t = start + Double(frame) / 48000
                if t >= from && t < to { energy += Double(values[frame * 2] * values[frame * 2]); count += 1 }
            }
        }
        return count == 0 ? 0 : sqrt(energy / Double(count))
    }
    func testVoiceoverMixNudgeAndOriginalMute() async throws {
        let source = try await sourceVideo(audio: true)
        let service = try BJJService(store: store)
        let imported = try await service.importFile(source, originalName: "mix.mp4")
        _ = try clip(imported)
        var json = try store.load(imported.id).json
        var settings = imported.settings; settings["originalAudioMuted"] = true; json["settings"] = settings
        let project = try store.save(BJJProject(json))
        let media = try await BJJMedia.inspect(store.asset(project.id, project.source.s("asset")), reference: project.source.s("asset"), originalName: "mix.mp4")
        let output = root.appendingPathComponent("mixed.mp4")
        try await BJJRenderer().render(media: media, project: project, store: store, output: output) { _ in }
        let before = try await audioEnergy(output, from: 0.5, to: 0.9)
        let active = try await audioEnergy(output, from: 1.3, to: 1.8)
        let after = try await audioEnergy(output, from: 2.3, to: 2.8)
        XCTAssertLessThan(before, 0.005); XCTAssertGreaterThan(active, 0.08); XCTAssertLessThan(after, 0.005)
    }
    func testQueuedJobCancellationPersists() throws {
        let project = try project()
        let service = try BJJService(store: store)
        let job = try service.createExport(project.id)
        XCTAssertEqual(job.status, "queued")
        XCTAssertEqual(try service.cancel(job.jobId).status, "cancelled")
        XCTAssertEqual(try BJJService(store: store).job(job.jobId).status, "cancelled")
    }
}
