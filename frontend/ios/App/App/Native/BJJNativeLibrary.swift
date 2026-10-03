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
    @Published var progress: Double?
    @Published var error: String?
    @Published var session: BJJNativeEditorSession?
    @Published var shareURL: URL?
    @Published var canCancel = false
    let root: URL
    let originalRoot: URL?
    private var service: BJJService?
    private var mediaID: String?
    private var packageID: String?
    private var photoLoad: Progress?
    private var awaitingPhoto = false
    private var refreshGeneration = 0
    private let images = NSCache<NSString, UIImage>()
    init(root: URL = BJJNativePilot.previewRoot(), originalRoot: URL? = nil) {
        self.root = root
        self.originalRoot = originalRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BJJTelestrator/projects", isDirectory: true)
        images.countLimit = 100; images.totalCostLimit = 20 * 1024 * 1024
    }
    func services() throws -> BJJService {
        if let service { return service }
        let created = try BJJService(store: BJJStore(root: root)); service = created; return created
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
        return true
    }
    private func finish() async {
        mediaID = nil; packageID = nil; photoLoad = nil; canCancel = false; busy = false
        await refresh()
    }
    func cancel() {
        photoLoad?.cancel()
        if let mediaID { _ = try? service?.mediaJobs.cancel(mediaID) }
        if let packageID { _ = try? service?.packageJobs.cancel(packageID) }
        canCancel = false; activity = "Cancelling…"
    }
    func suspend() { if canCancel { cancel() } }
    func open(_ review: BJJNativeReview) async {
        if let problem = review.problem { error = problem; return }
        guard begin(review.preview ? "Opening review…" : "Preparing protected copy…") else { return }
        do {
            let service = try services(), originalRoot = originalRoot
            let store = service.store
            let project = try await BJJAssets.offMain {
                if review.preview { return try store.loadRecoveringRecordings(review.id) }
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
            while !Task.isCancelled {
                guard let self, self.mediaID == id, let job = try? self.service?.mediaJobs.get(id) else { return }
                if self.awaitingPhoto {
                    self.progress = self.photoLoad?.fractionCompleted; self.activity = "Downloading selected video…"
                    try? await Task.sleep(nanoseconds: 200_000_000); continue
                }
                self.progress = job.progress
                self.activity = job.stage == "copying" ? "Copying video…" : job.stage == "preparing_preview" ? "Preparing video…" : "Checking video…"
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }
    func importFile(_ url: URL, backup: Bool = false, openWhenReady: Bool = true) async {
        var imported: BJJProject?
        guard begin(backup ? "Restoring backup…" : "Copying video…", cancellable: true) else { return }
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
                let job = try service.mediaJobs.create(); mediaID = job.jobId
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
        await finish()
        if openWhenReady, let imported { openImported(imported) }
    }
    private func openImported(_ project: BJJProject) {
        do { session = try BJJNativeEditorSession(project: project, store: services().store, service: services()) }
        catch { self.error = error.localizedDescription }
    }
    func importPhoto(_ item: NSItemProvider) async {
        var imported: BJJProject?
        guard begin("Downloading selected video…", cancellable: true) else { return }
        do {
            let service = try services(), job = try service.mediaJobs.create(); mediaID = job.jobId
            awaitingPhoto = true
            let downloadStart = ProcessInfo.processInfo.systemUptime
            let polling = pollMedia(job.jobId); defer { polling.cancel(); awaitingPhoto = false }
            do {
                let (target, worker) = try service.mediaJobs.beginImport(job.jobId)
                let store = service.store
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    photoLoad = item.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, providerError in
                        // Provider URLs expire on return from this callback. Stream into our
                        // owned source here; never load a whole video into memory.
                        do {
                            try worker.cancellation.check()
                            guard let url else { throw providerError ?? BJJError.invalid("The video could not download from Photos. Download it there and try again.") }
                            try BJJMediaWork.copy(url, target, store: store, work: worker)
                            continuation.resume()
                        } catch { continuation.resume(throwing: error) }
                    }
                }
                awaitingPhoto = false
                service.mediaJobs.recordMetric(job.jobId, "provider_and_copy", seconds: ProcessInfo.processInfo.systemUptime - downloadStart)
                imported = try await service.mediaJobs.finishImport(job.jobId, originalName: item.suggestedName ?? "New review.mov")
            } catch { service.mediaJobs.failure(job.jobId, error); throw error }
        } catch { report(error) }
        await finish()
        if let imported { openImported(imported) }
    }
    private func report(_ error: Error) {
        if let mediaID, (try? service?.mediaJobs.get(mediaID).status) == "cancelled" { return }
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
    private var sharedPackage: String?
    func endShare() {
        if let sharedPackage { service?.packageJobs.releaseOutput(sharedPackage) }
        sharedPackage = nil; shareURL = nil
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

struct BJJNativePhotoPicker: UIViewControllerRepresentable {
    let selected: (NSItemProvider?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(selected: selected) }
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(); configuration.filter = .videos; configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration); picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: PHPickerViewController, context: Context) { }
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let selected: (NSItemProvider?) -> Void
        init(selected: @escaping (NSItemProvider?) -> Void) { self.selected = selected }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) { selected(results.first?.itemProvider) }
    }
}
