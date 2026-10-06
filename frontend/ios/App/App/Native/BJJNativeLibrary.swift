import Foundation
import SwiftUI
import AVFoundation
import PhotosUI
import UniformTypeIdentifiers

struct BJJNativeDeletedReview: Identifiable {
    let id: String
    let name: String
    init(_ json: BJJJSON) { id = json.s("trashId"); name = json.s("projectName") }
}

/// The native workspace owns one service and one active operation. Legacy reviews
/// are only read and copied until native editing parity is accepted.
@MainActor final class BJJNativeLibrary: ObservableObject {
    @Published var reviews: [BJJNativeReview] = []
    @Published var deleted: [BJJNativeDeletedReview] = []
    @Published var busy = false
    @Published var activity = ""
    @Published var activityDetail = "Keep the app open while your video is prepared."
    @Published var progress: Double?
    @Published var error: String? { didSet { if error != nil { BJJDiagnostics.shared.record(.libraryError) } } }
    @Published var session: BJJNativeEditorSession?
    @Published var shareURL: URL?
    @Published var canCancel = false
    let root: URL
    let originalRoot: URL?
    private var service: BJJService?
    private var mediaID: String?
    private var packageID: String?
    private var photoLoad: Progress?
    private var photoProgressSampling = BJJPhotoProgressSampling.configured
    private func sampledPhotoProgress() -> Double? {
        photoProgressSampling.sample { BJJPhotoImportStatus.progress(photoLoad) }
    }
    private var awaitingPhoto = false
    private var isBackground = false
    private(set) var sceneState: BJJImportSceneState = .unknown
    private(set) var sceneSource = "unknown"
    private var importStarted: Double?
    private var importPreparedAt: Double?
    private var pendingImported: (BJJProject, String?)?
    private var refreshGeneration = 0
    private let images = NSCache<NSString, UIImage>()
    init(root: URL = BJJNativePilot.previewRoot(), originalRoot: URL? = nil) {
        self.root = root
        self.originalRoot = originalRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BJJTelestrator/projects", isDirectory: true)
        images.countLimit = 100; images.totalCostLimit = 20 * 1024 * 1024
        BJJDiagnostics.shared.record(.launch)
    }
    func services() throws -> BJJService {
        if let service { return service }
        let created = try BJJService(store: BJJStore(root: root)); service = created
        created.mediaJobs.observeLifecycle(sceneState.rawValue, source: sceneSource)
        if let interruption = created.mediaJobs.recoveredInterruption { error = interruption }
        return created
    }
    func refresh() async {
        guard !busy else { return }
        refreshGeneration += 1; let generation = refreshGeneration
        do {
            let store = try services().store
            let originalRoot = originalRoot
            let result = try await BJJAssets.offMain {
                let native = try BJJNativePilot.reviews(store, preview: true)
                let original = try originalRoot.map { try BJJNativePilot.reviews(BJJStore(root: $0), preview: false) } ?? []
                return (native + original, try BJJProjectVersions(store: store).deleted().map(BJJNativeDeletedReview.init))
            }
            guard generation == refreshGeneration else { return }
            reviews = result.0; deleted = result.1
        } catch { self.error = error.localizedDescription }
    }
    private func begin(_ title: String, cancellable: Bool = false) -> Bool {
        guard !busy, session == nil else { return false }
        refreshGeneration += 1
        busy = true; activity = title; progress = nil; canCancel = cancellable
        BJJDiagnostics.shared.record(.libraryStart)
        activityDetail = "Keep the app open while your video is prepared."
        return true
    }
    private func finish() async {
        BJJDiagnostics.shared.record(.libraryFinish)
        mediaID = nil; packageID = nil; photoLoad = nil; canCancel = false; busy = false
        await refresh()
    }
    func cancel() {
        BJJDiagnostics.shared.record(.cancel, operation: mediaID ?? packageID)
        if let mediaID { _ = try? service?.mediaJobs.cancel(mediaID) }
        photoLoad?.cancel()
        if let packageID { _ = try? service?.packageJobs.cancel(packageID) }
        canCancel = false; activity = "Cancelling…"
    }
    func observeScene(_ state: BJJImportSceneState, source: String) {
        guard state != sceneState || sceneSource == "unknown" else { return }
        sceneState = state; sceneSource = source
        service?.mediaJobs.observeLifecycle(state.rawValue, source: source)
        BJJDiagnostics.shared.record(.sceneState, operation: mediaID ?? packageID, phase: state.rawValue)
        if state == .background { suspend() }
        else if state == .active { resume() }
        else { isBackground = true } // Inactive is not background, but cannot present an editor.
    }
    func suspend() {
        isBackground = true
        BJJDiagnostics.shared.record(.background, operation: mediaID ?? packageID)
        if let mediaID { service?.mediaJobs.enterBackground(mediaID) }
        else if canCancel { cancel() } // Keep backup/restore's existing policy.
        BJJDiagnostics.shared.flush()
    }
    func resume() {
        isBackground = false
        BJJDiagnostics.shared.record(.foreground, operation: mediaID ?? packageID)
        if let mediaID { service?.mediaJobs.checkpoint(mediaID, providerProgress: sampledPhotoProgress()) }
        if let pending = pendingImported { pendingImported = nil; openImported(pending.0, jobID: pending.1) }
    }
    func open(_ review: BJJNativeReview) async {
        if let problem = review.problem { error = problem; return }
        guard begin(review.preview ? "Opening review…" : "Preparing protected copy…") else { return }
        do {
            let service = try services(), originalRoot = originalRoot
            let store = service.store
            let project = try await BJJAssets.offMain {
                if review.preview {
                    do { return try store.loadRecoveringRecordings(review.id) }
                    catch let error as BJJError where error.code == "PROJECT_CONFLICT" { return try store.recoverConflictingReviewReceipt(review.id) }
                }
                guard let originalRoot else { throw BJJError.invalid("The original library is unavailable.") }
                return try BJJNativePilot.copy(review.id, from: BJJStore(root: originalRoot), to: store)
            }
            session = try BJJNativeEditorSession(project: project, store: service.store, service: service)
        } catch { self.error = error.localizedDescription }
        await finish()
    }
    func thumbnail(_ review: BJJNativeReview) async -> UIImage? {
        guard review.problem == nil else { return nil }
        let key = "\(review.key)-\(review.updatedAt)" as NSString
        if let image = images.object(forKey: key) { return image }
        do {
            let folder = review.preview ? root : originalRoot ?? root
            let url = try await BJJAssets.offMain {
                let store = try BJJStore(root: folder)
                let json = try store.readJSON(store.directory(review.id).appendingPathComponent("project.json"))
                return try BJJAssets.file(store, review.id, BJJProject(json).proxy.s("asset"))
            }
            guard !Task.isCancelled else { return nil }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 192, height: 112)
            let frame = try await generator.image(at: CMTime(seconds: min(1, review.duration / 2), preferredTimescale: 600))
            guard !Task.isCancelled else { return nil }
            let image = UIImage(cgImage: frame.image)
            images.setObject(image, forKey: key, cost: frame.image.bytesPerRow * frame.image.height)
            return image
        } catch { return nil }
    }
    private func pollMedia(_ id: String) -> Task<Void, Never> {
        Task { [weak self] in
            var lastCheckpoint = -Double.infinity
            while !Task.isCancelled {
                guard let self, self.mediaID == id, let job = try? self.service?.mediaJobs.get(id) else { return }
                // Cancellation is terminal UI intent; polling must not overwrite it.
                if !self.canCancel { return }
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastCheckpoint >= 5 {
                    self.service?.mediaJobs.checkpoint(id, providerProgress: self.sampledPhotoProgress())
                    lastCheckpoint = now
                }
                if self.awaitingPhoto && job.totalBytes == nil {
                    self.progress = self.sampledPhotoProgress()
                    self.activity = BJJPhotoImportStatus.title
                    self.activityDetail = BJJPhotoImportStatus.detail
                    if let importStarted = self.importStarted, now - importStarted >= 15 {
                        self.activityDetail += " Waiting \(Int(now - importStarted)) seconds. Keep Fresh Frame open, or cancel and try again."
                    }
                    try? await Task.sleep(nanoseconds: 200_000_000); continue
                }
                self.progress = job.progress
                self.activityDetail = "Keep the app open while your video is prepared."
                self.activity = job.stage == "copying" ? "Copying video…" : job.stage == "preparing_preview" ? "Preparing video…" : "Checking video…"
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }
    func importFile(_ url: URL, backup: Bool = false, openWhenReady: Bool = true) async {
        var imported: BJJProject?
        var importedJobID: String?
        guard begin(backup ? "Restoring backup…" : "Copying video…", cancellable: true) else { return }
        importStarted = ProcessInfo.processInfo.systemUptime
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let service = try services()
            if backup {
                let id = UUID().uuidString.lowercased(); packageID = id
                _ = try service.packageJobs.create(operation: "restore", requestId: id)
                _ = try await service.packageJobs.importFile(id, source: url)
                _ = try await waitPackage(id)
            } else {
                let job = try service.mediaJobs.create(); mediaID = job.jobId; importedJobID = job.jobId
                let polling = pollMedia(job.jobId); defer { polling.cancel() }
                do {
                    let (target, worker) = try service.mediaJobs.beginImport(job.jobId)
                    let store = service.store
                    try await BJJAssets.offMain {
                        // Coordinates provider/iCloud reads while the security scope remains open.
                        var failure: Error?, coordination: NSError?
                        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordination) { input in
                            do { try BJJMediaWork.copy(input, target, store: store, work: worker) }
                            catch { failure = error }
                        }
                        if let failure { throw failure }; if let coordination { throw coordination }
                    }
                    imported = try await service.mediaJobs.finishImport(job.jobId, originalName: url.lastPathComponent)
                } catch { service.mediaJobs.failure(job.jobId, error); throw error }
            }
        } catch { report(error) }
        if imported != nil { importPreparedAt = ProcessInfo.processInfo.systemUptime }
        await finish()
        if openWhenReady, let imported { openImported(imported, jobID: importedJobID) }
    }
    private func openImported(_ project: BJJProject, jobID: String?) {
        if isBackground { pendingImported = (project, jobID); return }
        let began = ProcessInfo.processInfo.systemUptime
        do {
            session = try BJJNativeEditorSession(project: project, store: services().store, service: services())
            session?.importJobID = jobID
            session?.importStartedAt = importStarted
            session?.importPreparedAt = importPreparedAt
            if let jobID { try services().mediaJobs.recordMetric(jobID, "editor_open", seconds: ProcessInfo.processInfo.systemUptime - began) }
        }
        catch { self.error = error.localizedDescription }
    }
    func importPhoto(_ item: NSItemProvider, policy: BJJPhotoImportPolicy = .configured,
                     progressSampling: BJJPhotoProgressSampling = .configured) async {
        var imported: BJJProject?
        var importedJobID: String?
        guard begin(BJJPhotoImportStatus.title, cancellable: true) else { return }
        photoProgressSampling = progressSampling
        activityDetail = BJJPhotoImportStatus.detail
        do {
            let service = try services(), job = try service.mediaJobs.create(); mediaID = job.jobId; importedJobID = job.jobId
            service.mediaJobs.configurePhoto(job.jobId, policy: policy, progressSampling: progressSampling)
            awaitingPhoto = true
            BJJDiagnostics.shared.record(.photosRequest, operation: job.jobId)
            let downloadStart = ProcessInfo.processInfo.systemUptime
            importStarted = downloadStart
            let polling = pollMedia(job.jobId); defer { polling.cancel(); awaitingPhoto = false }
            do {
                let (target, worker) = try service.mediaJobs.beginImport(job.jobId, waitingForPhotos: true)
                let store = service.store
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let completion = BJJPhotoImportCompletion(continuation)
                    Task {
                        while !completion.finished {
                            do { try worker.cancellation.check() }
                            catch { completion.cancel(error); return }
                            try? await Task.sleep(nanoseconds: 200_000_000)
                        }
                    }
                    photoLoad = item.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, providerError in
                        // Claim callback ownership before touching a temporary URL. A cancel
                        // settles immediately only while no callback owns disk work.
                        guard completion.claimCallback() else {
                            BJJDiagnostics.shared.record(.photosCallbackIgnored, operation: job.jobId); return
                        }
                        do {
                            try worker.cancellation.check()
                            if let providerError { throw providerError }
                            guard let url, url.isFileURL else { throw BJJError.domain("PHOTOS_PROVIDER_FAILED", "Photos did not supply a video. Select it again and keep Fresh Frame open.") }
                            guard worker.acceptProviderURL(operation: job.jobId) else { throw BJJError.cancelled }
                            // Must finish the owned copy before returning from this callback.
                            try BJJMediaWork.copy(url, target, store: store, work: worker)
                            completion.finish(.success(()))
                        } catch {
                            let cancelled = (try? worker.cancellation.check()) == nil
                            if worker.diagnosticState().0 == .waitingForPhotos {
                                worker.providerFinished(cancelled ? "cancelled" : "failed")
                                BJJDiagnostics.shared.record(cancelled ? .photosCancelled : .photosFailed, operation: job.jobId, phase: "waiting_for_photos", error: cancelled ? nil : error)
                            }
                            completion.finish(.failure(error))
                        }
                    }
                }
                awaitingPhoto = false
                service.mediaJobs.recordMetric(job.jobId, "provider_and_copy", seconds: ProcessInfo.processInfo.systemUptime - downloadStart)
                imported = try await service.mediaJobs.finishImport(job.jobId, originalName: item.suggestedName ?? "New review.mov")
            } catch {
                photoLoad?.cancel(); service.mediaJobs.failure(job.jobId, error)
                if let stopped = try? service.mediaJobs.get(job.jobId), ["cancelled", "interrupted"].contains(stopped.providerOutcome ?? "") {
                    BJJDiagnostics.shared.record(.photosCancelled, operation: job.jobId, phase: stopped.phaseAtStop)
                }
                throw error
            }
        } catch { report(error) }
        if imported != nil { importPreparedAt = ProcessInfo.processInfo.systemUptime }
        await finish()
        if let imported { openImported(imported, jobID: importedJobID) }
    }
    private func report(_ error: Error) {
        let finalJob = mediaID.flatMap { try? service?.mediaJobs.get($0) }
        let canonical: Error
        if let code = finalJob?.errorCode { canonical = BJJError.domain(code, "") } else { canonical = error }
        BJJDiagnostics.shared.record(.libraryError, operation: mediaID ?? packageID, phase: finalJob?.phaseAtStop, error: canonical)
        if let finalJob, finalJob.terminal {
            if finalJob.status != "cancelled" { self.error = finalJob.error }
            return
        }
        if (error as? BJJError)?.code != "JOB_CANCELLED" { self.error = error.localizedDescription }
    }
    func change(_ review: BJJNativeReview, action: String, name: String = "") async {
        guard review.preview, review.problem == nil, begin("\(action)…", cancellable: action == "Back up") else { return }
        do {
            let service = try services(), store = service.store
            let project = try await BJJAssets.offMain { try store.loadRecoveringRecordings(review.id) }
            if action == "Back up" {
                let id = UUID().uuidString.lowercased(); packageID = id
                _ = try service.packageJobs.create(operation: "backup", requestId: id, projectId: project.id,
                                                   revision: project.revision, includeProxy: true)
                if try await waitPackage(id) { shareURL = try service.packageJobs.acquireOutput(id) }
                // Keep this output retained until the share sheet closes.
                if shareURL != nil { sharedPackage = id }
            } else {
                try await BJJAssets.offMain {
                    let versions = BJJProjectVersions(store: store)
                    switch action {
                    case "Rename":
                        var json = project.json; json["projectName"] = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        _ = try store.save(BJJProject(json))
                    case "Duplicate": _ = try versions.duplicate(project.id, revision: project.revision)
                    case "Move to Recently Deleted": try versions.trash(project.id, revision: project.revision)
                    default: throw BJJError.invalid("Unknown library action.")
                    }
                }
            }
        } catch { report(error) }
        await finish()
    }
    private var diagnosticURL: URL?
    func shareImportDiagnostics() async {
        guard begin("Preparing timing report…") else { return }
        do {
            let store = try services().store
            let report = try await BJJAssets.offMain { () throws -> BJJJSON in
                let folder = store.root.appendingPathComponent("media-jobs")
                let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
                let records = files.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }.prefix(256).compactMap { file -> BJJJSON? in
                    guard let job = (try? store.readJSON(file))?["job"] as? BJJJSON else { return nil }
                    return job.filter { ["operation", "status", "stage", "copiedBytes", "totalBytes", "timings", "mediaProfile", "createdAt", "errorCode", "appVersion", "appBuild", "importPhase", "lastCheckpointAt", "providerProgress", "providerProgressSampling", "stopReason", "phaseAtStop", "sessionId", "operationId", "attemptId", "retryOf", "requestedRepresentation", "importPolicyVersion", "providerOutcome", "lifecycleState", "lifecycleSource", "backgroundTaskGranted", "backgroundTimeRemainingSec"].contains($0.key) }
                }
                return ["version": 3, "createdAt": BJJProject.now(), "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown", "appBuild": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown", "osVersion": ProcessInfo.processInfo.operatingSystemVersionString, "imports": records, "diagnostics": BJJDiagnostics.shared.snapshot()]
            }
            BJJDiagnostics.shared.record(.share)
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("FreshFrame-diagnostics-\(UUID().uuidString).json")
            try store.writeJSON(report, to: path); diagnosticURL = path; shareURL = path
        } catch { self.error = error.localizedDescription }
        await finish()
    }
    private var sharedPackage: String?
    func endShare() {
        if let sharedPackage { service?.packageJobs.releaseOutput(sharedPackage) }
        if let diagnosticURL { try? FileManager.default.removeItem(at: diagnosticURL) }
        diagnosticURL = nil; sharedPackage = nil; shareURL = nil
    }
    private func waitPackage(_ id: String) async throws -> Bool {
        let service = try services()
        while !Task.isCancelled {
            let job = try service.packageJobs.get(id)
            progress = job["progress"] as? Double
            activity = job.s("operation") == "backup" ? "Preparing backup…" : "Restoring backup…"
            if job.s("status") == "completed" { return true }
            if job.s("status") == "cancelled" { return false }
            if job.s("status") == "failed" { throw BJJError.invalid(job.s("error")) }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        _ = try service.packageJobs.cancel(id); return false
    }
    func restore(_ id: String) async {
        guard begin("Restoring review…") else { return }
        do {
            let store = try services().store
            _ = try await BJJAssets.offMain { try BJJProjectVersions(store: store).restoreDeleted(id) }
        } catch { self.error = error.localizedDescription }
        await finish()
    }
}

/// Internal experiment only. Disabling observations never disables Progress.cancel()
/// or the independent cancellation-token monitor. The reader is intentionally lazy.
enum BJJPhotoProgressSampling: String {
    case sampled, disabled
    static var configured: Self {
        Self(rawValue: Bundle.main.object(forInfoDictionaryKey: "BJJPhotoProgressSampling") as? String ?? "") ?? .sampled
    }
    func sample(_ read: () -> Double?) -> Double? { self == .sampled ? read() : nil }
}

enum BJJPhotoImportPolicy: String {
    case automatic, compatible
    static var configured: Self {
        // Embedded in the signed app, not a DEBUG-only switch or a home preference.
        Self(rawValue: Bundle.main.object(forInfoDictionaryKey: "BJJPhotoImportPolicy") as? String ?? "") ?? .compatible
    }
    var representation: PHPickerConfiguration.AssetRepresentationMode { self == .automatic ? .automatic : .compatible }
}

struct BJJNativePhotoPicker: UIViewControllerRepresentable {
    var policy: BJJPhotoImportPolicy = .configured
    let selected: (NSItemProvider?) -> Void
    static func configuration(policy: BJJPhotoImportPolicy = .configured) -> PHPickerConfiguration {
        var configuration = PHPickerConfiguration()
        configuration.filter = .videos; configuration.selectionLimit = 1
        // Configure before creating the picker. Compatible remains the default;
        // automatic is a signed, separately labeled experiment with identical guards.
        configuration.preferredAssetRepresentationMode = policy.representation
        return configuration
    }
    func makeCoordinator() -> Coordinator { Coordinator(selected: selected) }
    func makeUIViewController(context: Context) -> PHPickerViewController {
        let picker = PHPickerViewController(configuration: Self.configuration(policy: policy)); picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: PHPickerViewController, context: Context) { }
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let selected: (NSItemProvider?) -> Void
        init(selected: @escaping (NSItemProvider?) -> Void) { self.selected = selected }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) { selected(results.first?.itemProvider) }
    }
}

enum BJJPhotoImportStatus {
    static let title = "Getting video from Photos…"
    static let detail = "Photos may download from iCloud or prepare this video. Copying has not started."
    static func progress(_ value: Progress?) -> Double? {
        // NSItemProvider reports aggregate loading, not a cloud-only download.
        // Unknown/zero totals must not appear as a stuck 0% progress bar.
        guard let value, value.totalUnitCount > 0, !value.isIndeterminate,
              value.fractionCompleted.isFinite else { return nil }
        return min(1, max(0, value.fractionCompleted))
    }
}

/// Providers may finish after Cancel, or never invoke their callback after their
/// Progress is cancelled. Settle once; the worker token fences every late copy.
final class BJJPhotoImportCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var callbackClaimed = false
    func claimCallback() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard continuation != nil, !callbackClaimed else { return false }
        callbackClaimed = true; return true
    }
    func cancel(_ error: Error) {
        lock.lock()
        // The callback's cooperative copy will settle after closing its handles.
        guard !callbackClaimed else { lock.unlock(); return }
        let pending = continuation; continuation = nil; lock.unlock()
        pending?.resume(throwing: error)
    }
    init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
    var finished: Bool { lock.lock(); defer { lock.unlock() }; return continuation == nil }
    func finish(_ result: Result<Void, Error>) {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        pending?.resume(with: result)
    }
}
