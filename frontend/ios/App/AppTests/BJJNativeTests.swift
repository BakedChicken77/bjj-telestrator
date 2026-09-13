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
    func testHighFrameRateAndVariablePTSKeepSourceTime() async throws {
        let fixture = try XCTUnwrap(Bundle(for: BJJNativeTests.self).url(forResource: "media-timing-conformance", withExtension: "json"))
        for item in try store.readJSON(fixture)["cases"] as! [BJJJSON] {
            let original = root.appendingPathComponent("\(item.s("name")).mp4")
            try XCTUnwrap(Data(base64Encoded: item.s("movieBase64"))).write(to: original)
            let media = try await BJJMedia.inspect(original, reference: "source/original.mp4", originalName: "original.mp4")
            let reader = try AVAssetReader(asset: media.asset)
            let samples = AVAssetReaderTrackOutput(track: media.video, outputSettings: nil)
            samples.alwaysCopiesSampleData = false
            XCTAssertTrue(reader.canAdd(samples)); reader.add(samples)
            XCTAssertTrue(reader.startReading())
            var timestamps = [Double]()
            while let sample = samples.copyNextSampleBuffer() { timestamps.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds) }
            XCTAssertEqual(reader.status, .completed)
            timestamps.sort()
            let expected = (item["ptsTicks"] as! [NSNumber]).map { $0.doubleValue / item.n("timescale") }
            XCTAssertEqual(timestamps.count, expected.count)
            for (actual, expected) in zip(timestamps, expected) { XCTAssertEqual(actual, expected, accuracy: 0.000001) }
            let imported = try await BJJService(store: store).importFile(original, originalName: "timing.mp4")
            var document = imported.json; document["annotations"] = [annotation(start: 0.5, end: 1.5)]
            let project = try store.save(BJJProject(document))
            let output = root.appendingPathComponent("\(item.s("name"))-export.mp4")
            try await BJJRenderer().render(media: media, project: project, store: store, output: output) { _ in }
            for movie in [try store.asset(project.id, project.proxy.s("asset")), output] {
                let result = try await BJJMedia.inspect(movie, reference: "proxy/result.mp4", originalName: "result.mp4")
                XCTAssertEqual(result.fps, 30, accuracy: 0.001)
                XCTAssertEqual(result.videoRange.duration.seconds, 2, accuracy: 0.1)
                XCTAssertEqual(try dominantPixels(movie, time: 29.0 / 30, channel: 1), 0)
                XCTAssertGreaterThan(try dominantPixels(movie, time: 1, channel: 1), 40000)
            }
            XCTAssertEqual(try redPixels(output, time: 14.0 / 30), 0)
            XCTAssertGreaterThan(try redPixels(output, time: 0.5), 1500)
            XCTAssertGreaterThan(try redPixels(output, time: 44.0 / 30), 1500)
            XCTAssertEqual(try redPixels(output, time: 1.5), 0)
            XCTAssertEqual(try BJJAssets.digest(store.asset(project.id, project.source.s("asset"))), item.s("sha256"))
        }
    }
    func testPreviewCleanupRetainsReferencesGraceAndLeases() throws {
        let project = try project()
        let folder = try store.directory(project.id)
        let stale = folder.appendingPathComponent("proxy/\(UUID().uuidString.lowercased()).mp4")
        let pinned = folder.appendingPathComponent("proxy/\(UUID().uuidString.lowercased()).mp4")
        let recent = folder.appendingPathComponent("proxy/\(UUID().uuidString.lowercased()).mp4")
        for file in [stale, pinned, recent] { try Data([1, 2, 3]).write(to: file) }
        for file in [stale, pinned] { try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -172800)], ofItemAtPath: file.path) }
        try store.writeJSON(["version": 1, "retainedProxy": "proxy/\(pinned.lastPathComponent)"], to: folder.appendingPathComponent("retained.json"))
        XCTAssertEqual(try BJJAssets.previewCleanup(store, id: project.id)["files"] as? Int, 1)
        try store.acquireLease(project.id)
        XCTAssertThrowsError(try BJJAssets.previewCleanup(store, id: project.id, revision: project.revision, remove: true))
        store.releaseLease(project.id)
        let result = try BJJAssets.previewCleanup(store, id: project.id, revision: project.revision, remove: true)
        XCTAssertEqual(result["files"] as? Int, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pinned.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try store.asset(project.id, project.source.s("asset")).path))
        try Data("{broken".utf8).write(to: folder.appendingPathComponent("retained.json"))
        XCTAssertThrowsError(try BJJAssets.previewCleanup(store, id: project.id, revision: project.revision, remove: true))
    }
    func testPackageQueuedCancellationAndInterruptedStagingRecovery() throws {
        let jobs = try BJJPackageJobs(store: store)
        let cancelled = UUID().uuidString.lowercased()
        _ = try jobs.create(operation: "restore", requestId: cancelled)
        XCTAssertEqual(try jobs.cancel(cancelled).s("status"), "cancelled")
        XCTAssertEqual(try jobs.create(operation: "restore", requestId: cancelled).s("status"), "cancelled")
        let pending = UUID().uuidString.lowercased()
        _ = try jobs.create(operation: "restore", requestId: pending)
        let partial = try jobs.path(pending, "staging")
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: false)
        try Data([1, 2, 3]).write(to: partial.appendingPathComponent("uncommitted"))
        let reopened = try BJJPackageJobs(store: store)
        XCTAssertEqual(try reopened.get(pending).s("errorCode"), "PACKAGE_INTERRUPTED")
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertEqual(try reopened.get(cancelled).s("status"), "cancelled")
        try reopened.remove(pending)
        XCTAssertThrowsError(try reopened.get(pending))
        XCTAssertThrowsError(try reopened.path("../outside", "job.json"))
    }
    func testPortablePackageSharedFixturesAndNativeRoundTrip() async throws {
        let fixture = try XCTUnwrap(Bundle(for: BJJNativeTests.self).url(forResource: "package-conformance", withExtension: "json"))
        let value = try store.readJSON(fixture)
        var exported = false
        for item in value["cases"] as! [BJJJSON] {
            let id = UUID().uuidString.lowercased()
            let source = root.appendingPathComponent("\(id).bjjproj"), staging = root.appendingPathComponent("stage-\(id)")
            try XCTUnwrap(Data(base64Encoded: item.s("archiveBase64"))).write(to: source)
            if item["valid"] as! Bool {
                let copy = try await BJJProjectPackage.restore(store, source: source, staging: staging, id: id, work: BJJPackageWork())
                XCTAssertNotEqual(copy.id, "11111111-1111-4111-8111-111111111111")
                XCTAssertEqual(copy.revision, 1)
                XCTAssertEqual(copy.annotations[0].n("startSec"), 0.5)
                XCTAssertEqual(copy.annotations[0].n("endSec"), 1.5)
                XCTAssertEqual(copy.voiceovers[0].n("startSec"), 0.75)
                XCTAssertEqual(copy.voiceovers[0].n("endSec"), 1)
                XCTAssertEqual(try BJJAssets.digest(store.asset(copy.id, copy.source.s("asset"))), value.s("sourceSHA256"))
                XCTAssertEqual(try BJJAssets.digest(store.asset(copy.id, copy.voiceovers[0].s("asset"))), value.s("voiceoverSHA256"))
                if !exported {
                    exported = true
                    var edit = copy.json; edit["projectName"] = "Edited native restored review"
                    let saved = try store.save(BJJProject(edit))
                    let backup = root.appendingPathComponent("native-backup.bjjproj")
                    try await BJJAssets.offMain { [store = self.store!] in
                        try BJJProjectPackage.backup(store, project: saved, output: backup, includeProxy: false, work: BJJPackageWork())
                    }
                    let again = try await BJJProjectPackage.restore(store, source: backup, staging: root.appendingPathComponent("again"), id: UUID().uuidString.lowercased(), work: BJJPackageWork())
                    XCTAssertNotEqual(again.annotations[0].s("id"), saved.annotations[0].s("id"))
                    XCTAssertNotEqual(again.voiceovers[0].s("id"), saved.voiceovers[0].s("id"))
                    let original = try store.asset(again.id, again.source.s("asset"))
                    let media = try await BJJMedia.inspect(original, reference: again.source.s("asset"), originalName: "synthetic.mp4")
                    let output = root.appendingPathComponent("package-export.mp4")
                    try await BJJRenderer().render(media: media, project: again, store: store, output: output) { _ in }
                    let inspected = try await BJJMedia.inspect(output, reference: "exports/output.mp4", originalName: "output.mp4")
                    XCTAssertEqual(inspected.json.s("codec"), "avc1")
                    XCTAssertEqual(inspected.json.s("audioCodec"), "aac")
                    XCTAssertEqual(inspected.videoRange.duration.seconds, 2, accuracy: 0.1)
                    XCTAssertEqual(try redPixels(output, time: 0.25), 0)
                    XCTAssertGreaterThan(try redPixels(output, time: 0.5), 1500)
                    XCTAssertEqual(try redPixels(output, time: 1.5), 0)
                    XCTAssertEqual(try BJJAssets.digest(original), value.s("sourceSHA256"))
                    print("P1.05 native portable round trip: H264/AAC 320x180 2s, bytes=\(try output.resourceValues(forKeys: [.fileSizeKey]).fileSize!), source_sha256=\(value.s("sourceSHA256"))")
                }
            } else {
                do {
                    _ = try await BJJProjectPackage.restore(store, source: source, staging: staging, id: id, work: BJJPackageWork())
                    XCTFail("Accepted invalid package: \(item.s("name"))")
                } catch { XCTAssertFalse(FileManager.default.fileExists(atPath: try store.directory(id).path), item.s("name")) }
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path), item.s("name"))
        }
    }
    func testRealPQAndHLGProduceSDRBeforeCompositing() async throws {
        let fixture = try XCTUnwrap(Bundle(for: BJJNativeTests.self).url(forResource: "hdr-conformance", withExtension: "json"))
        let cases = try store.readJSON(fixture)["cases"] as! [BJJJSON]
        for item in cases {
            let data = try XCTUnwrap(Data(base64Encoded: item.s("movieBase64")))
            let original = root.appendingPathComponent("\(item.s("name")).mp4")
            try data.write(to: original)
            XCTAssertEqual(try BJJAssets.digest(original), item.s("sha256"))
            let inspected = try await BJJMedia.inspect(original, reference: "source/ramp.mp4", originalName: "ramp.mp4")
            XCTAssertEqual(inspected.json.s("transferFunction"), item.s("transferFunction"))
            let service = try BJJService(store: store)
            let imported = try await service.importFile(original, originalName: "ramp.mp4")
            XCTAssertTrue((imported.json["requiredCapabilities"] as! [String]).contains(BJJColor.capability))
            var document = imported.json; document["annotations"] = [annotation(start: 0.5, end: 1.5)]
            let project = try store.save(BJJProject(document))
            let result = root.appendingPathComponent("\(item.s("name"))-review.mp4")
            try await BJJRenderer().render(media: inspected, project: project, store: store, output: result) { _ in }
            let preview = try store.asset(project.id, project.proxy.s("asset"))
            var ramps = [[Int]]()
            for url in [preview, result] {
                let media = try await BJJMedia.inspect(url, reference: "proxy/output.mp4", originalName: "output.mp4")
                XCTAssertEqual(media.json.s("codec"), "avc1")
                XCTAssertEqual(media.json.s("transferFunction"), "bt709")
                XCTAssertEqual(media.json.s("colorPrimaries"), "bt709")
                XCTAssertEqual(media.json.s("colorMatrix"), "bt709")
                XCTAssertEqual(media.videoRange.duration.seconds, 2, accuracy: 1.0 / 30)
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
                let cg = try generator.copyCGImage(at: CMTime(seconds: 0.25, preferredTimescale: 600), actualTime: nil)
                var pixels = [UInt8](repeating: 0, count: 320 * 180 * 4)
                pixels.withUnsafeMutableBytes { bytes in
                    let context = CGContext(data: bytes.baseAddress, width: 320, height: 180, bitsPerComponent: 8,
                        bytesPerRow: 320 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                    context.draw(cg, in: CGRect(x: 0, y: 0, width: 320, height: 180))
                }
                let ramp = (item["sampleX"] as! [Int]).map { Int(pixels[(135 * 320 + $0) * 4]) }
                XCTAssertLessThan(ramp[0], 12, "\(ramp)")
                XCTAssertGreaterThan(ramp[7], 210, "\(ramp)")
                for index in 1..<8 { XCTAssertGreaterThan(ramp[index], ramp[index - 1] + 1, "Highlights/shadows collapsed: \(ramp)") }
                ramps.append(ramp)
            }
            for index in 0..<8 { XCTAssertLessThanOrEqual(abs(ramps[0][index] - ramps[1][index]), 6, "Preview/export differ: \(ramps)") }
            XCTAssertEqual(try redPixels(result, time: 0.25), 0)
            XCTAssertGreaterThan(try redPixels(result, time: 0.5), 1500)
            XCTAssertGreaterThan(try redPixels(result, time: 1.25), 1500)
            XCTAssertEqual(try redPixels(result, time: 1.5), 0)
            XCTAssertEqual(try BJJAssets.digest(store.asset(project.id, project.source.s("asset"))), item.s("sha256"))
            print("P1.04 HDR \(item.s("name")): ramps=\(ramps), H.264 Rec.709 320x180 2s bytes=\(try result.resourceValues(forKeys: [.fileSizeKey]).fileSize!), source_sha256=\(item.s("sha256"))")
        }
    }
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
    func testCheckpointRestoreRetainsRecordingAndBeforeRestoreVersion() throws {
        let initial = try project(); let take = try clip(initial)
        let original = try store.loadRecoveringRecordings(initial.id)
        let versions = BJJProjectVersions(store: store)
        let checkpoint = try versions.checkpoint(original.id, revision: original.revision, label: "Primeira revisão")
        var edit = original.json; edit["annotations"] = [BJJJSON](); edit["voiceovers"] = [BJJJSON](); edit["projectName"] = "After edits"
        let saved = try store.save(BJJProject(edit))
        let restored = try versions.restoreCheckpoint(original.id, checkpoint: checkpoint.s("checkpointId"), revision: saved.revision)
        XCTAssertEqual(restored.revision, saved.revision + 1)
        XCTAssertTrue(NSArray(array: restored.annotations).isEqual(to: original.annotations))
        XCTAssertTrue(NSArray(array: restored.voiceovers).isEqual(to: original.voiceovers))
        let entries = try versions.checkpoints(original.id)
        XCTAssertEqual(entries.count, 2)
        let before = try XCTUnwrap(entries.first { $0.s("label").hasPrefix("Before restoring") })
        let previous = try versions.restoreCheckpoint(original.id, checkpoint: before.s("checkpointId"), revision: restored.revision)
        XCTAssertEqual(previous.name, "After edits"); XCTAssertEqual(previous.voiceovers.count, 0)
        XCTAssertNoThrow(try store.asset(original.id, take.s("asset")))
        XCTAssertEqual(try BJJStore(root: root).load(original.id).revision, previous.revision)
        XCTAssertThrowsError(try versions.trash(original.id, revision: restored.revision))
        XCTAssertThrowsError(try versions.duplicate(original.id, revision: restored.revision))
        XCTAssertThrowsError(try versions.checkpoint(original.id, revision: restored.revision, label: "Stale"))
        XCTAssertThrowsError(try versions.restoreCheckpoint(original.id, checkpoint: checkpoint.s("checkpointId"), revision: restored.revision))
    }
    func testCheckpointWriteFailurePreservesCurrentReview() throws {
        let original = try project()
        let versions = BJJProjectVersions(store: store)
        let checkpoint = try versions.checkpoint(original.id, revision: original.revision, label: "Initial")
        var edit = original.json; edit["annotations"] = [BJJJSON]()
        let saved = try store.save(BJJProject(edit))
        let failed = try BJJStore(root: root, writeFile: { data, url in
            if url.deletingLastPathComponent().lastPathComponent == "checkpoints" { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        })
        XCTAssertThrowsError(try BJJProjectVersions(store: failed).restoreCheckpoint(original.id, checkpoint: checkpoint.s("checkpointId"), revision: saved.revision))
        XCTAssertEqual(try store.load(original.id).revision, saved.revision)
        XCTAssertEqual(try store.load(original.id).annotations.count, 0)
        XCTAssertNoThrow(try failed.requireUnleased(original.id))
        XCTAssertEqual(try versions.checkpoints(original.id).count, 1)
    }
    func testIndependentDuplicateAndTrashCollisionPreserveOriginals() throws {
        let initial = try project(); _ = try clip(initial)
        let recorded = try store.loadRecoveringRecordings(initial.id)
        var document = recorded.json, cue = recorded.annotations[0]
        cue["type"] = "text"
        cue["geometry"] = ["x": 0.2, "y": 0.3, "text": cue.s("id"), "fontSize": 0.04,
                           "alignment": "left", "backgroundColor": "#000000", "backgroundOpacity": 0.0]
        document["annotations"] = [cue]
        document["futureOptional"] = ["annotationRef": cue.s("id"), "clipRef": recorded.voiceovers[0].s("id")]
        let original = try store.save(BJJProject(document))
        let versions = BJJProjectVersions(store: store)
        let copy = try versions.duplicate(original.id, revision: original.revision)
        XCTAssertNotEqual(copy.id, original.id); XCTAssertEqual(copy.revision, 1)
        XCTAssertNotEqual(copy.annotations[0].s("id"), original.annotations[0].s("id"))
        XCTAssertNotEqual(copy.voiceovers[0].s("id"), original.voiceovers[0].s("id"))
        XCTAssertTrue(NSDictionary(dictionary: copy.annotations[0]["geometry"] as! BJJJSON).isEqual(to: cue["geometry"] as! BJJJSON))
        XCTAssertTrue(NSDictionary(dictionary: copy.source).isEqual(to: original.source))
        XCTAssertTrue(NSDictionary(dictionary: copy.proxy).isEqual(to: original.proxy))
        XCTAssertEqual((copy.json["futureOptional"] as! BJJJSON).s("annotationRef"), copy.annotations[0].s("id"))
        XCTAssertEqual((copy.json["futureOptional"] as! BJJJSON).s("clipRef"), copy.voiceovers[0].s("id"))
        XCTAssertEqual(try BJJAssets.digest(store.asset(copy.id, copy.source.s("asset"))), try BJJAssets.digest(store.asset(original.id, original.source.s("asset"))))
        var edit = copy.json; edit["annotations"] = [BJJJSON](); edit["voiceovers"] = [BJJJSON]()
        _ = try store.save(BJJProject(edit))
        XCTAssertEqual(try store.load(original.id).voiceovers.count, 1)
        try versions.trash(original.id, revision: original.revision)
        let entry = try XCTUnwrap(versions.deleted().first)
        let archived = try versions.readTrash(entry.s("trashId")).1
        try FileManager.default.copyItem(at: archived, to: store.directory(original.id))
        let (restored, copied) = try versions.restoreDeleted(entry.s("trashId"))
        XCTAssertTrue(copied); XCTAssertNotEqual(restored.id, original.id)
        XCTAssertEqual(try versions.deleted().count, 1)
        XCTAssertEqual(try store.load(original.id).revision, original.revision)
        try versions.permanentlyDelete(entry.s("trashId"))
        XCTAssertEqual(try versions.deleted().count, 0)
        XCTAssertNoThrow(try store.asset(restored.id, restored.voiceovers[0].s("asset")))
        XCTAssertNoThrow(try store.asset(original.id, original.source.s("asset")))
    }
    func testDeletedRecoveryRejectsSymlinksAndKeepsLeasedProject() throws {
        let original = try project()
        let versions = BJJProjectVersions(store: store)
        try store.acquireLease(original.id)
        XCTAssertThrowsError(try versions.trash(original.id, revision: original.revision))
        store.releaseLease(original.id)
        XCTAssertThrowsError(try versions.permanentlyDelete("../source"))
        try FileManager.default.createDirectory(at: versions.trashRoot(), withIntermediateDirectories: true)
        let identifier = UUID().uuidString.lowercased()
        try FileManager.default.createSymbolicLink(at: versions.trashEntry(identifier), withDestinationURL: store.directory(original.id))
        XCTAssertThrowsError(try versions.restoreDeleted(identifier))
        XCTAssertThrowsError(try versions.permanentlyDelete(identifier))
        XCTAssertNoThrow(try store.asset(original.id, original.source.s("asset")))
    }
    func testSharedConformanceAndIdempotentMigration() throws {
        let url = try XCTUnwrap(Bundle(for: BJJNativeTests.self).url(forResource: "project-conformance", withExtension: "json"))
        let fixtures = try BJJValidate.object(JSONSerialization.jsonObject(with: Data(contentsOf: url)), "fixtures")
        let cases = try BJJValidate.objects(fixtures["cases"], "cases", maximum: 100)
        for item in cases {
            let value = try BJJValidate.object(item["document"], "document")
            if item["valid"] as? Bool == true { XCTAssertNoThrow(try BJJProject(value), item["name"] as! String) }
            else { XCTAssertThrowsError(try BJJProject(value), item["name"] as! String) }
        }
        let migrated = try BJJProject(BJJValidate.object(cases[0]["document"], "legacy"))
        XCTAssertTrue(NSDictionary(dictionary: migrated.json).isEqual(to: fixtures["migrationExpected"] as! BJJJSON))
        XCTAssertTrue(NSDictionary(dictionary: migrated.json).isEqual(to: try BJJProject(migrated.json).json))
    }
    func testMigrationRetainsExactOriginalAndConditionalSaveExport() async throws {
        let p = try project(); let path = try store.directory(p.id).appendingPathComponent("project.json")
        var legacy = p.json; legacy["schemaVersion"] = 1; legacy.removeValue(forKey: "revision"); legacy.removeValue(forKey: "requiredCapabilities")
        let bytes = try JSONSerialization.data(withJSONObject: legacy, options: [.prettyPrinted])
        try bytes.write(to: path)
        let migrated = try store.load(p.id)
        XCTAssertEqual(migrated.revision, 1)
        XCTAssertEqual(try Data(contentsOf: path.deletingLastPathComponent().appendingPathComponent("project.pre-migration-v1.json")), bytes)
        let saved = try store.save(migrated)
        XCTAssertEqual(saved.revision, 2)
        XCTAssertThrowsError(try store.save(migrated))
        let service = try BJJService(store: store)
        do { _ = try await service.createExport(p.id, expectedRevision: 1); XCTFail("Stale export must be rejected") }
        catch { XCTAssertEqual((error as? BJJError)?.code, "PROJECT_CONFLICT") }
        XCTAssertEqual(try store.load(p.id).revision, 2)
    }
    func testRecoveryJournalAndIndependentCopy() throws {
        let p = try project()
        var json = p.json; json["projectName"] = "Recovered edit"
        let writer = UUID().uuidString.lowercased(), first = UUID().uuidString.lowercased(), second = UUID().uuidString.lowercased()
        let draft: BJJJSON = ["version": 1, "writerId": writer, "draftId": first, "project": json, "savedAt": BJJProject.now()]
        try store.writeDraft(draft)
        XCTAssertEqual(try BJJStore(root: root).recoveryDrafts(p.id).count, 1)
        var newer = draft; newer["draftId"] = second
        try store.writeDraft(newer)
        try store.clearDraft(p.id, writer: writer, draft: first)
        XCTAssertEqual(try store.recoveryDrafts(p.id).count, 1)
        let copy = try store.recoverCopy(BJJProject(json))
        XCTAssertNotEqual(copy.id, p.id)
        XCTAssertNotEqual(copy.annotations[0]["id"] as? String, p.annotations[0]["id"] as? String)
        XCTAssertEqual(try Data(contentsOf: store.asset(copy.id, copy.source["asset"] as! String)), try Data(contentsOf: store.asset(p.id, p.source["asset"] as! String)))
        XCTAssertEqual(try store.load(p.id).name, p.name)
        try store.clearDraft(p.id, writer: writer, draft: second)
        XCTAssertEqual(try store.recoveryDrafts(p.id).count, 0)
    }
    func testSharedExportPlanConformanceAndCachedAssetIdentity() throws {
        let url = try XCTUnwrap(Bundle(for: BJJNativeTests.self).url(forResource: "export-plan-conformance", withExtension: "json"))
        let fixtures = try store.readJSON(url)
        for item in fixtures["cases"] as! [BJJJSON] {
            let value = item["plan"] as! BJJJSON
            if item["valid"] as? Bool == true {
                XCTAssertNoThrow(try BJJRenderPlan(value, projectId: "11111111-1111-4111-8111-111111111111", revision: 1), item["name"] as! String)
            } else {
                XCTAssertThrowsError(try BJJRenderPlan(value, projectId: "11111111-1111-4111-8111-111111111111", revision: 1), item["name"] as! String)
            }
        }
        let p = try project()
        let plan = try BJJRenderPlan(store: store, project: p)
        let again = try BJJRenderPlan(store: store, project: store.save(p))
        XCTAssertTrue(NSArray(array: plan.json["assets"] as! [BJJJSON]).isEqual(to: again.json["assets"] as! [BJJJSON]))
        let source = try store.asset(p.id, p.source.s("asset"))
        let bytes = try Data(contentsOf: source)
        try Data([1]).write(to: source)
        XCTAssertThrowsError(try plan.verify(store))
        XCTAssertThrowsError(try BJJAssets.manifest(store, p))
        try bytes.write(to: source)
        XCTAssertNoThrow(try plan.verify(store))
        let cancel = BJJJobCancellation(); cancel.cancel()
        XCTAssertThrowsError(try plan.verify(store, cancellation: cancel))
        let estimate = BJJAssets.exportEstimate(p)
        XCTAssertGreaterThan(estimate.n("requiredBytes"), estimate.n("outputBytes") + estimate.n("workingBytes"))
        XCTAssertThrowsError(try store.checkSpace(required: Int64.max))
        try store.acquireLease(p.id)
        XCTAssertThrowsError(try store.delete(p.id))
        store.releaseLease(p.id)
        let summary = try BJJAssets.summary(store, p)
        XCTAssertEqual(summary.n("sourceBytes"), 1)
        XCTAssertEqual(summary.n("proxyBytes"), 1)
        XCTAssertEqual(summary["recordingsRetained"] as? Bool, true)
        let unsafe = try store.directory(p.id).appendingPathComponent("exports/inputs")
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: unsafe, withDestinationURL: outside)
        XCTAssertThrowsError(try store.safeURL(p.id, "exports/inputs/test.json"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])

    }
    func testInterruptedRecordingAcknowledgmentReplaysAtomically() throws {
        let initial = try project()
        let take = try clip(initial)
        var failOnce = true
        let failing = try BJJStore(root: root, writeFile: { data, url in
            if failOnce && url.lastPathComponent == "pending.json" {
                failOnce = false
                throw CocoaError(.fileWriteOutOfSpace)
            }
            try data.write(to: url, options: .atomic)
        })
        XCTAssertThrowsError(try failing.loadRecoveringRecordings(initial.id))
        let journal = try store.safeURL(initial.id, "save-transaction.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))
        let restarted = try BJJStore(root: root)
        let recovered = try restarted.load(initial.id)
        XCTAssertEqual(recovered.revision, initial.revision + 1)
        XCTAssertEqual(recovered.voiceovers.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
        var removal = recovered.json; removal["voiceovers"] = [BJJJSON]()
        let removed = try restarted.save(BJJProject(removal))
        XCTAssertEqual(removed.voiceovers.count, 0)
        XCTAssertEqual(try BJJStore(root: root).loadRecoveringRecordings(initial.id).voiceovers.count, 0)
        XCTAssertNoThrow(try restarted.asset(initial.id, take.s("asset")))
    }
    func testInterruptedExportRetryRetainsRevisionAndRecording() async throws {
        let initial = try project()
        let take = try clip(initial)
        let p = try store.loadRecoveringRecordings(initial.id)
        let service = try BJJService(store: store)
        let job = try await service.createExport(p.id)
        _ = try service.cancel(job.jobId)
        let path = try BJJRenderPlan.path(store, job)
        let input = try Data(contentsOf: path)
        var edited = p.json; edited["annotations"] = [BJJJSON](); edited["voiceovers"] = [BJJJSON]()
        let saved = try store.save(BJJProject(edited))
        var interrupted = job; interrupted.status = "running"
        try JSONEncoder().encode(interrupted).write(to: path.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("\(job.jobId).json"), options: .atomic)
        let restarted = try BJJService(store: BJJStore(root: root))
        XCTAssertEqual(try restarted.job(job.jobId).errorCode, "EXPORT_INTERRUPTED")
        let retry = try restarted.retryExport(job.jobId)
        XCTAssertEqual(retry.projectRevision, p.revision)
        XCTAssertEqual(retry.retryOf, job.jobId)
        XCTAssertNotEqual(retry.jobId, job.jobId)
        XCTAssertEqual(try Data(contentsOf: BJJRenderPlan.path(store, retry)), input)
        XCTAssertThrowsError(try restarted.removeExportFile(retry.jobId))
        _ = try restarted.cancel(retry.jobId)
        XCTAssertEqual(try store.load(p.id).revision, saved.revision)
        XCTAssertEqual(try store.load(p.id).annotations.count, 0)
        XCTAssertEqual(try store.load(p.id).voiceovers.count, 0)
        let retained = try BJJRenderPlan.read(store, retry)
        XCTAssertEqual(retained.project.voiceovers.count, 1)
        XCTAssertNoThrow(try retained.verify(store))
        XCTAssertNoThrow(try store.asset(p.id, take.s("asset")))
        // Copying a snapshot under another project cannot substitute its assets.
        var wrong = try store.readJSON(path); wrong["projectId"] = UUID().uuidString.lowercased()
        XCTAssertThrowsError(try BJJRenderPlan(wrong, projectId: p.id, revision: p.revision))
    }
    func testRecordingRecoveryCommitsARevisionBeforeExport() throws {
        let p = try project(); _ = try clip(p)
        XCTAssertEqual(try store.load(p.id).revision, p.revision)
        XCTAssertEqual(try store.load(p.id).voiceovers.count, 0)
        let recovered = try store.loadRecoveringRecordings(p.id)
        XCTAssertEqual(recovered.revision, p.revision + 1)
        XCTAssertEqual(recovered.voiceovers.count, 1)
        XCTAssertEqual(try store.load(p.id).voiceovers.count, 1)
    }
    func testBridgeRegistersMediaHandlerOnFreshConfiguration() throws {
        let controller = BJJViewController()
        controller.loadViewIfNeeded()
        let webView = try XCTUnwrap(controller.webView)
        XCTAssertTrue(webView.configuration.urlSchemeHandler(forURLScheme: "capacitor") is BJJAssetHandler)
        XCTAssertTrue(webView.configuration.allowsInlineMediaPlayback)
        XCTAssertFalse(webView.configuration.userContentController.userScripts.isEmpty)
        XCTAssertNotNil(controller.bridge)
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
    func testCoreAudioAACIdentifierIsCanonicalized() {
        XCTAssertEqual(BJJMedia.fourCC(kAudioFormatMPEG4AAC), "aac ")
        XCTAssertEqual(BJJMedia.audioCodecName(kAudioFormatMPEG4AAC), "aac")
        XCTAssertEqual(BJJMedia.audioCodecName(kAudioFormatLinearPCM), "lpcm")
    }

    func testByteRangeParsing() throws {
        XCTAssertEqual(try BJJByteRange.parse("bytes=20-29", size: 100), BJJByteRange(first: 20, last: 29))
        XCTAssertEqual(try BJJByteRange.parse("bytes=-10", size: 100), BJJByteRange(first: 90, last: 99))
        XCTAssertEqual(try BJJByteRange.parse("bytes=90-", size: 100).count, 10)
        XCTAssertThrowsError(try BJJByteRange.parse("bytes=100-", size: 100))
        XCTAssertThrowsError(try BJJByteRange.parse("bytes=0-9,20-29", size: 100))
    }
    func testTrackedMediaRepairPreservesSourceNarrationAndGeometry() async throws {
        let source = try await sourceVideo(audio: true)
        let hash = try BJJAssets.digest(source)
        let manager = try BJJMediaJobs(store: store)
        let importJob = try manager.create()
        let (destination, worker) = try manager.beginImport(importJob.jobId)
        try await BJJAssets.offMain { [store = store!] in try BJJMediaWork.copy(source, destination, store: store, work: worker) }
        XCTAssertEqual(try manager.get(importJob.jobId).progress, 1)
        let imported = try await manager.finishImport(importJob.jobId, originalName: "Tracked roll.mov")
        XCTAssertEqual(try manager.get(importJob.jobId).stage, "ready")
        XCTAssertEqual(try manager.get(importJob.jobId).projectRevision, imported.revision)
        let take = try clip(imported)
        var json = try store.loadRecoveringRecordings(imported.id).json
        json["annotations"] = [annotation()]
        let oldProxy = try store.asset(imported.id, imported.proxy.s("asset"))
        try FileManager.default.removeItem(at: oldProxy)
        let saved = try store.save(BJJProject(json)) // Save pending edits before repairing a missing preview.
        XCTAssertThrowsError(try store.save(saved, replacingProxy: true))
        let repair = try manager.repair(saved.id, revision: saved.revision)
        let deadline = Date().addingTimeInterval(90)
        while !(try manager.get(repair.jobId).terminal) && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        let result = try manager.get(repair.jobId)
        XCTAssertEqual(result.status, "completed", result.error ?? "")
        let repaired = try store.load(saved.id)
        XCTAssertEqual(repaired.revision, saved.revision + 1)
        XCTAssertNotEqual(repaired.proxy.s("asset"), saved.proxy.s("asset"))
        XCTAssertTrue(NSArray(array: repaired.annotations).isEqual(to: saved.annotations))
        XCTAssertTrue(NSArray(array: repaired.voiceovers).isEqual(to: saved.voiceovers))
        XCTAssertTrue(NSDictionary(dictionary: repaired.source).isEqual(to: saved.source))
        XCTAssertNoThrow(try store.asset(repaired.id, take.s("asset")))
        XCTAssertEqual(try BJJAssets.digest(store.asset(repaired.id, repaired.source.s("asset"))), hash)
        let preview = try store.asset(repaired.id, repaired.proxy.s("asset"))
        let inspected = try await BJJMedia.inspect(preview, reference: repaired.proxy.s("asset"), originalName: "Preview.mp4")
        XCTAssertEqual(inspected.videoRange.duration.seconds, 4, accuracy: 0.1)
        XCTAssertEqual(inspected.orientedSize, CGSize(width: 320, height: 180))
        XCTAssertLessThanOrEqual(inspected.fps, 30.01)
        XCTAssertEqual(inspected.json.s("audioCodec"), "aac")
        let energy = try await audioEnergy(preview, from: 0.2, to: 0.8)
        XCTAssertGreaterThan(energy, 0.05)
        XCTAssertThrowsError(try store.save(saved))
        XCTAssertEqual(try BJJStore(root: root).load(saved.id).proxy.s("asset"), repaired.proxy.s("asset"))
        print("P1.04 native repair: avc1/aac 320x180 duration=4 bytes=\(try preview.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) source_sha256=\(hash)")
        let original = try await BJJMedia.inspect(store.asset(repaired.id, repaired.source.s("asset")), reference: repaired.source.s("asset"), originalName: "Tracked roll.mov")
        let output = root.appendingPathComponent("repaired-review.mp4")
        try await BJJRenderer().render(media: original, project: repaired, store: store, output: output) { _ in }
        let exported = try await BJJMedia.inspect(output, reference: "exports/repaired-review.mp4", originalName: "repaired-review.mp4")
        XCTAssertEqual(exported.videoRange.duration.seconds, 4, accuracy: 0.1)
        XCTAssertEqual(exported.json.s("codec"), "avc1")
        XCTAssertEqual(exported.json.s("audioCodec"), "aac")
        XCTAssertEqual(try redPixels(output, time: 0.5), 0)
        XCTAssertGreaterThan(try redPixels(output, time: 1), 500)
        XCTAssertEqual(try redPixels(output, time: 2), 0)
        let audible = try await audioEnergy(output, from: 1.3, to: 1.8)
        XCTAssertGreaterThan(audible, 0.05)
        XCTAssertEqual(try BJJAssets.digest(store.asset(repaired.id, repaired.source.s("asset"))), hash)
        print("P1.04 native repaired-review export: avc1/aac 320x180 duration=4 bytes=\(try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) source_sha256=\(hash)")
    }
    func testMediaCopyCancelAndRestartCleanOnlyUncommittedImports() async throws {
        let retained = try project()
        let manager = try BJJMediaJobs(store: store)
        let input = root.appendingPathComponent("picked.mov")
        try Data(repeating: 1, count: 1024 * 1024).write(to: input)
        let job = try manager.create()
        let (target, worker) = try manager.beginImport(job.jobId)
        _ = try manager.cancel(job.jobId)
        XCTAssertThrowsError(try BJJMediaWork.copy(input, target, store: store, work: worker))
        manager.failure(job.jobId, BJJError.cancelled)
        XCTAssertEqual(try manager.get(job.jobId).status, "cancelled")
        XCTAssertFalse(FileManager.default.fileExists(atPath: try store.directory(job.projectId).path))
        let interrupted = try manager.create()
        let (partial, _) = try manager.beginImport(interrupted.jobId)
        try Data([1, 2, 3]).write(to: partial)
        let restarted = try BJJMediaJobs(store: store)
        XCTAssertEqual(try restarted.get(interrupted.jobId).errorCode, "MEDIA_INTERRUPTED")
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertEqual(try store.load(retained.id).revision, retained.revision)
        XCTAssertEqual(try Data(contentsOf: input).count, 1024 * 1024)
        XCTAssertThrowsError(try restarted.get("../outside"))
    }
    func testMediaRepairCancellationReleasesLeaseWithoutChangingProject() async throws {
        let retained = try project()
        let manager = try BJJMediaJobs(store: store)
        XCTAssertThrowsError(try manager.repair(retained.id, revision: retained.revision + 1))
        let job = try manager.repair(retained.id, revision: retained.revision)
        _ = try manager.cancel(job.jobId)
        // The queued Task must execute its cleanup before the lease can be released.
        await Task.yield()
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(try manager.get(job.jobId).status, "cancelled")
        XCTAssertNoThrow(try store.requireUnleased(retained.id))
        XCTAssertTrue(NSDictionary(dictionary: try store.load(retained.id).json).isEqual(to: retained.json))
        let temporary = try store.directory(retained.id).appendingPathComponent("temp")
        let outside = root.appendingPathComponent("outside-staging")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let protected = outside.appendingPathComponent("retained.txt")
        try Data("must remain".utf8).write(to: protected)
        try FileManager.default.removeItem(at: temporary)
        try FileManager.default.createSymbolicLink(at: temporary, withDestinationURL: outside)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let unsafe = try manager.repair(retained.id, revision: retained.revision)
        let deadline = Date().addingTimeInterval(5)
        while !(try manager.get(unsafe.jobId)).terminal && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(try manager.get(unsafe.jobId).status, "failed")
        XCTAssertNoThrow(try store.requireUnleased(retained.id))
        XCTAssertEqual(try String(contentsOf: protected, encoding: .utf8), "must remain")
        XCTAssertTrue(NSDictionary(dictionary: try store.load(retained.id).json).isEqual(to: retained.json))
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
        XCTAssertThrowsError(try store.save(p)) // stale edits must never overwrite
        var removal = p.json
        removal["revision"] = try store.load(p.id).revision
        _ = try store.save(BJJProject(removal))
        XCTAssertEqual(try store.load(p.id).voiceovers.count, 0)
        XCTAssertNoThrow(try store.asset(p.id, take.s("asset")))
        var undo = reopened.json
        undo["revision"] = try store.load(p.id).revision
        _ = try store.save(BJJProject(undo))
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
        try dominantPixels(url, time: time, channel: 0)
    }
    private func dominantPixels(_ url: URL, time: Double, channel: Int) throws -> Int {
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
            return stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0 + channel] > 180 && pixels[$0 + (channel + 1) % 3] < 80 && pixels[$0 + (channel + 2) % 3] < 80 }.count
        }
    }
    func testRealNativeMP4ExportBurnsTimedPixelsAndPreservesSourceAudio() async throws {
        // Cold simulator codec/graphics initialization measured 158 seconds in CI.
        executionTimeAllowance = 300
        let source = try await sourceVideo(audio: true)
        let before = SHA256.hash(data: try Data(contentsOf: source))
        let service = try BJJService(store: store)
        let imported = try await service.importFile(source, originalName: "synthetic.mp4")
        let folder = try store.directory(imported.id)
        var legacy = imported.json
        legacy["schemaVersion"] = 1; legacy.removeValue(forKey: "revision"); legacy.removeValue(forKey: "requiredCapabilities")
        let legacyBytes = try JSONSerialization.data(withJSONObject: legacy, options: [.prettyPrinted])
        try legacyBytes.write(to: folder.appendingPathComponent("project.json"))
        let migrated = try store.load(imported.id)
        XCTAssertEqual(migrated.revision, 1)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("project.pre-migration-v1.json")), legacyBytes)
        var json = migrated.json; json["annotations"] = [annotation()]
        let project = try store.save(BJJProject(json))
        XCTAssertEqual(project.revision, 2)
        let job = try await service.createExport(project.id, expectedRevision: project.revision)
        XCTAssertEqual(job.projectRevision, project.revision)
        let deadline = Date().addingTimeInterval(90)
        while ["queued", "running"].contains(try service.job(job.jobId).status) && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        let completedJob = try service.job(job.jobId)
        XCTAssertEqual(completedJob.status, "completed", completedJob.error ?? "")
        let output = try service.exportedFile(job.jobId)
        let result = try await BJJMedia.inspect(output, reference: "exports/result.mp4", originalName: "result.mp4")
        XCTAssertEqual(result.json.s("codec"), "avc1")
        XCTAssertEqual(result.json["audioCodec"] as? String, "aac")
        XCTAssertEqual(result.orientedSize, CGSize(width: 320, height: 180))
        XCTAssertEqual(result.videoRange.duration.seconds, 4, accuracy: 0.1)
        XCTAssertEqual(try redPixels(output, time: 0.5), 0)
        XCTAssertGreaterThan(try redPixels(output, time: 1), 500)
        XCTAssertEqual(try redPixels(output, time: 2), 0)
        XCTAssertEqual(before, SHA256.hash(data: try Data(contentsOf: source)))
        let originalAudioEnergy = try await audioEnergy(output, from: 0.2, to: 0.8)
        XCTAssertGreaterThan(originalAudioEnergy, 0.05)
        XCTAssertEqual(try BJJStore(root: root).load(project.id).annotations.count, 1)
        let versions = BJJProjectVersions(store: store)
        let checkpoint = try versions.checkpoint(project.id, revision: project.revision, label: "Timed cue")
        var later = project.json; later["annotations"] = [BJJJSON]()
        let edited = try store.save(BJJProject(later))
        let restoredCue = try versions.restoreCheckpoint(project.id, checkpoint: checkpoint.s("checkpointId"), revision: edited.revision)
        XCTAssertEqual(restoredCue.annotations.count, 1)
        var cleared = restoredCue.json; cleared["annotations"] = [BJJJSON]()
        let current = try store.save(BJJProject(cleared))
        try service.deleteProject(project.id, expectedRevision: current.revision)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        let deleted = try XCTUnwrap(versions.deleted().first)
        let (restoredProject, copied) = try versions.restoreDeleted(deleted.s("trashId"))
        XCTAssertFalse(copied); XCTAssertEqual(restoredProject.revision, current.revision)
        XCTAssertEqual(try versions.checkpoints(project.id).count, 2)
        // A new service reads the retained export after deletion/restore/restart.
        let restarted = try BJJService(store: store)
        let retry = try restarted.retryExport(job.jobId)
        XCTAssertEqual(retry.projectRevision, project.revision)
        let retryDeadline = Date().addingTimeInterval(90)
        while ["queued", "running"].contains(try restarted.job(retry.jobId).status) && Date() < retryDeadline { try await Task.sleep(nanoseconds: 100_000_000) }
        let completedRetry = try restarted.job(retry.jobId)
        XCTAssertEqual(completedRetry.status, "completed", completedRetry.error ?? "")
        let retryOutput = try restarted.acquireExportFile(retry.jobId)
        XCTAssertGreaterThan(try redPixels(retryOutput, time: 1), 500)
        XCTAssertEqual(try redPixels(retryOutput, time: 2), 0)
        let retryAudio = try await audioEnergy(retryOutput, from: 0.2, to: 0.8)
        XCTAssertGreaterThan(retryAudio, 0.05)
        XCTAssertThrowsError(try restarted.removeExportFile(retry.jobId))
        restarted.releaseExportFile(retry.jobId)
        let bytes = try retryOutput.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        print("P1.06 native retry: avc1/aac 320x180 duration=4 bytes=\(bytes) source_sha256=\(try BJJAssets.digest(store.asset(project.id, project.source.s("asset"))))")
        XCTAssertEqual(try restarted.removeExportFile(retry.jobId).outputAvailable, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: retryOutput.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try BJJRenderPlan.path(store, retry).path))
        XCTAssertEqual(try store.load(project.id).revision, current.revision)
        XCTAssertEqual(before, SHA256.hash(data: try Data(contentsOf: store.asset(project.id, project.source.s("asset")))))

        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("project.pre-migration-v1.json")), legacyBytes)
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
    func testQueuedJobCancellationPersists() async throws {
        let project = try project()
        let service = try BJJService(store: store)
        let job = try await service.createExport(project.id)
        XCTAssertEqual(job.status, "queued")
        XCTAssertEqual(try service.cancel(job.jobId).status, "cancelled")
        XCTAssertEqual(try BJJService(store: store).job(job.jobId).status, "cancelled")
    }
}
