#if DEBUG
import Foundation
import AVFoundation

/// UI automation never opens, resets, or edits the user's real library.
@MainActor enum BJJUITestFixture {
    static var root: URL? {
        guard let value = ProcessInfo.processInfo.environment["BJJ_UI_TEST_SESSION"],
              let id = UUID(uuidString: value) else { return nil }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BJJUITests/\(id.uuidString)")
    }
    static func library() -> BJJNativeLibrary? {
        root.map { BJJNativeLibrary(root: $0.appendingPathComponent("projects"), originalRoot: $0.appendingPathComponent("originals")) }
    }
    static func prepare(_ library: BJJNativeLibrary) async {
        guard let root, library.root == root.appendingPathComponent("projects") else { return }
        await library.refresh()
        guard library.reviews.isEmpty, library.error == nil else { return }
        do {
            let source = root.appendingPathComponent("fixture-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: source) }
            try await video(source)
            await library.importFile(source, openWhenReady: false)
            if ProcessInfo.processInfo.environment["BJJ_UI_TEST_PAUSES"] == "1", let review = library.continuation {
                let store = try BJJStore(root: library.root), initial = try store.load(review.id)
                let holdID = UUID().uuidString.lowercased()
                var document = initial.json, takes = [BJJJSON]()
                document["requiredCapabilities"] = (initial.json["requiredCapabilities"] as! [String]) + [BJJReviewTimeline.capability]
                document["reviewTimeline"] = BJJReviewTimeline(sourceDuration: initial.duration, holds: [["id": holdID, "sourceTicks": 48000, "durationTicks": 48000, "frozenPTS": 1.0]]).json
                for _ in 0..<2 {
                    let id = UUID().uuidString.lowercased(), asset = "voiceover/\(UUID().uuidString.lowercased()).wav"
                    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
                    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24000)!
                    buffer.frameLength = 24000
                    for frame in 0..<24000 { buffer.floatChannelData![0][frame] = Float(sin(Double(frame) * 2 * .pi * 440 / 48000) * 0.1) }
                    let file = try AVAudioFile(forWriting: store.safeURL(initial.id, asset), settings: format.settings)
                    try file.write(from: buffer)
                    takes.append(["id": id, "asset": asset, "durationSec": 0.5, "sampleCount": 24000,
                        "gain": 1.0, "muted": false, "recordedAt": BJJProject.now(), "codec": "pcm_f32le", "sampleRate": 48000, "channels": 1,
                        "placements": [["audioStartTicks": 0, "durationTicks": 24000, "holdId": holdID, "offsetTicks": 0]]])
                }
                try store.writeJSON(Dictionary(uniqueKeysWithValues: takes.map { ($0.s("id"), $0 as Any) }), to: store.safeURL(initial.id, "voiceover/assets.json"))
                document["reviewNarration"] = takes
                _ = try store.save(BJJProject(document)); await library.refresh()
            }
        } catch { library.error = error.localizedDescription }
    }
    private static func video(_ url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 320, AVVideoHeightKey: 180])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        writer.add(input)
        guard writer.startWriting() else { throw BJJError.invalid("UI fixture encoder failed.") }
        writer.startSession(atSourceTime: .zero)
        for index in 0..<120 {
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else { throw BJJError.invalid("UI fixture encoder stopped.") }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            var pixel: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool,
                  CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel) == kCVReturnSuccess, let pixel else {
                throw BJJError.invalid("Cannot allocate UI fixture frame.")
            }
            CVPixelBufferLockBaseAddress(pixel, [])
            memset(CVPixelBufferGetBaseAddress(pixel), 80, CVPixelBufferGetDataSize(pixel))
            CVPixelBufferUnlockBaseAddress(pixel, [])
            guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(index), timescale: 30)) else {
                throw BJJError.invalid("Cannot append UI fixture frame.")
            }
        }
        input.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in writer.finishWriting { continuation.resume() } }
        guard writer.status == .completed else { throw BJJError.invalid("UI fixture did not finish.") }
    }
}

extension BJJUITestFixture {
    static func tipStore() -> BJJTipStore? {
        guard root != nil, ProcessInfo.processInfo.environment["BJJ_UI_TEST_TIPS"] == "1" else { return nil }
        return BJJTipStore(client: BJJTipUITestClient())
    }
}

@MainActor private final class BJJTipUITestClient: BJJTipClient {
    var canMakePayments: Bool { true }
    func storefront() async -> String? { "USA" }
    func products(for ids: Set<String>) async throws -> [BJJTipProduct] {
        BJJTipCatalog.amounts.compactMap { amount in
            let id = BJJTipCatalog.id(for: amount)
            guard ids.contains(id) else { return nil }
            return BJJTipProduct(id: id, price: Decimal(amount), currency: "USD",
                                 displayPrice: "$\(amount).00", consumable: true)
        }
    }
    func purchase(_ product: BJJTipProduct) async throws -> BJJTipPurchaseResult { .cancelled }
    func updates() -> AsyncStream<BJJTipTransaction> { AsyncStream { $0.finish() } }
    func unfinished() -> AsyncStream<BJJTipTransaction> { AsyncStream { $0.finish() } }
}
#endif
