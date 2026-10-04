import SwiftUI
import UniformTypeIdentifiers

struct BJJNativeHome: View {
    @StateObject private var library: BJJNativeLibrary
    init(library: BJJNativeLibrary? = nil) {
        #if DEBUG
        _library = StateObject(wrappedValue: library ?? BJJUITestFixture.library() ?? BJJNativeLibrary())
        #else
        _library = StateObject(wrappedValue: library ?? BJJNativeLibrary())
        #endif
    }
    @Environment(\.scenePhase) private var scenePhase
    @State private var search = ""
    @State private var previousReviews = false
    @State private var afterLibrary: (() -> Void)?
    @State private var photos = false
    @State private var files = false
    @State private var backupImport = false
    @State private var recentlyDeleted = false
    @State private var support = false
    @State private var renaming: BJJNativeReview?
    @State private var name = ""
    @State private var trash: BJJNativeReview?
    private var filtered: [BJJNativeReview] {
        library.reviews.filter { search.isEmpty || $0.name.localizedStandardContains(search) }
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack {
                    Color.black
                    GeometryReader { geometry in
                    ScrollView {
                    VStack(spacing: 24) {
                        Image("FreshFrameLogo").resizable().scaledToFit()
                            .frame(width: min(geometry.size.width * 0.82, max(48, geometry.size.height - 180)),
                                   height: min(geometry.size.width * 0.82, max(48, geometry.size.height - 180)))
                            .accessibilityHidden(true)
                        Text("Your next perspective starts here.").font(.headline).foregroundStyle(.white)
                        Menu {
                            Button("Choose from Photos", systemImage: "photo.on.rectangle") { photos = true }
                            Button("Choose from Files", systemImage: "folder") { backupImport = false; files = true }
                            Button("Previous reviews", systemImage: "clock") { previousReviews = true }
                        } label: { Label("Select a video", systemImage: "plus.circle.fill").frame(minHeight: 44) }
                            .buttonStyle(.borderedProminent).accessibilityIdentifier("home.selectVideo")
                    }.padding().frame(maxWidth: .infinity)
                        .frame(minHeight: geometry.size.height)
                    }
                    }
                }
                HStack {
                    Button("Previous reviews", systemImage: "clock") { previousReviews = true }.accessibilityIdentifier("home.reviews")
                    Spacer()
                    Button("Support Fresh Frame", systemImage: "heart") { support = true }.accessibilityIdentifier("tips.open")
                }.frame(minHeight: 44).padding().background(.bar)
            }
            .disabled(library.busy)
            .navigationTitle("Fresh Frame")
            .sheet(isPresented: $previousReviews, onDismiss: {
                if let action = afterLibrary { afterLibrary = nil; action() }
            }) {
                NavigationStack {
                    reviewList.searchable(text: $search, prompt: "Find a review")
                        .navigationTitle("Previous reviews")
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { previousReviews = false } } }
                }
            }
            .refreshable { await library.refresh() }
            .task {
                #if DEBUG
                await BJJUITestFixture.prepare(library)
                #endif
                await library.refresh()
            }
            .overlay {
                if library.busy {
                    VStack(spacing: 16) {
                        Text(library.activity).font(.headline)
                        if let progress = library.progress { ProgressView(value: progress) } else { ProgressView() }
                        Text(library.activityDetail).font(.footnote)
                        if library.canCancel { Button("Cancel", role: .cancel) { library.cancel() }.frame(minHeight: 44) }
                    }.padding(24).frame(maxWidth: 300).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                }
            }
            .sheet(isPresented: $photos) {
                BJJNativePhotoPicker { item in
                    photos = false
                    if let item { Task { await library.importPhoto(item) } }
                }.ignoresSafeArea()
            }
            .fileImporter(isPresented: $files,
                          allowedContentTypes: backupImport ? [UTType(filenameExtension: "bjjproj") ?? .data, .zip] : [.movie, .video]) { result in
                switch result {
                case .success(let url): Task { await library.importFile(url, backup: backupImport) }
                case .failure(let error): library.error = error.localizedDescription
                }
            }
            .fullScreenCover(item: $library.session, onDismiss: { Task { await library.refresh() } }) { session in
                BJJNativeEditorScreen(session: session)
            }
            .sheet(isPresented: $support) { BJJTipSheet(store: BJJTipStore.shared) }
            .sheet(isPresented: $recentlyDeleted) { deletedList }
            .sheet(isPresented: Binding(get: { library.shareURL != nil }, set: { if !$0 { library.endShare() } }), onDismiss: { library.endShare() }) {
                if let url = library.shareURL { BJJNativeShare(url: url) }
            }
            .alert("Rename review", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Review name", text: $name)
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Save") {
                    if let review = renaming { previousReviews = false; Task { await library.change(review, action: "Rename", name: name) } }
                    renaming = nil
                }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 160)
            }
            .confirmationDialog("Move review to Recently Deleted?", isPresented: Binding(get: { trash != nil }, set: { if !$0 { trash = nil } }), titleVisibility: .visible) {
                Button("Move to Recently Deleted", role: .destructive) {
                    if let review = trash { previousReviews = false; Task { await library.change(review, action: "Move to Recently Deleted") } }
                    trash = nil
                }
            } message: { Text("You can restore this review later. Original reviews remain unchanged.") }
            .alert("Review needs attention", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
                Button("Share diagnostics") { library.error = nil; Task { await library.shareImportDiagnostics() } }
                Button("OK") { library.error = nil }
            } message: { Text(library.error ?? "") }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { library.suspend() }
                else if phase == .active { library.resume() }
            }
        }
    }
    private func closeLibrary(_ action: @escaping () -> Void) { afterLibrary = action; previousReviews = false }
    private var reviewList: some View {
        List {
                Section {
                    Menu {
                        Button("Choose from Photos", systemImage: "photo.on.rectangle") { closeLibrary { photos = true } }
                        Button("Choose from Files", systemImage: "folder") { closeLibrary { backupImport = false; files = true } }
                        Button("Restore project backup", systemImage: "arrow.down.doc") { closeLibrary { backupImport = true; files = true } }
                    } label: { Label("New review", systemImage: "plus.circle.fill").font(.headline).frame(minHeight: 44) }
                    Text("Draw on your videos, record commentary, and share your perspective.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach([true, false], id: \.self) { native in
                    let items = filtered.filter { $0.preview == native }
                    if !items.isEmpty {
                        Section(native ? "Your reviews" : "Earlier reviews · open a protected copy") {
                            ForEach(items, id: \.key) { review in
                                Button { closeLibrary { Task { await library.open(review) } } } label: {
                                    BJJNativeLibraryRow(library: library, review: review)
                                }
                                .accessibilityIdentifier("review.\(review.id)")
                                .contextMenu {
                                    if native && review.problem == nil {
                                        Button("Rename", systemImage: "pencil") { closeLibrary { name = review.name; renaming = review } }
                                        Button("Duplicate", systemImage: "plus.square.on.square") { closeLibrary { Task { await library.change(review, action: "Duplicate") } } }
                                        Button("Back up", systemImage: "square.and.arrow.up") { closeLibrary { Task { await library.change(review, action: "Back up") } } }
                                        Button("Move to Recently Deleted", systemImage: "trash", role: .destructive) { closeLibrary { trash = review } }
                                    }
                                }
                            }
                        }
                    }
                }
                if filtered.isEmpty && !library.busy {
                    ContentUnavailableView(search.isEmpty ? "Start a review" : "No matching reviews", systemImage: "film",
                                           description: Text(search.isEmpty ? "Choose a video from Photos or Files." : "Try a different name."))
                }
                Section {
                    Button("Recently Deleted", systemImage: "trash") { closeLibrary { recentlyDeleted = true } }.frame(minHeight: 44)
                    Button("Support Fresh Frame", systemImage: "heart") { closeLibrary { support = true } }
                        .frame(minHeight: 44).accessibilityIdentifier("tips.open")
                    Button("Share import timing report", systemImage: "clock.arrow.circlepath") { closeLibrary { Task { await library.shareImportDiagnostics() } } }
                    Button("Share diagnostic report", systemImage: "square.and.arrow.up") { closeLibrary { Task { await library.shareImportDiagnostics() } } }
                    Button("Clear diagnostic logs", systemImage: "trash") { BJJDiagnostics.shared.clear() }
                    Text("Diagnostic logs stay on this iPhone for up to 7 days (500 events). Reports include import timings, app events and error codes, but no video, audio, filenames or annotation text. Nothing is uploaded automatically.").font(.footnote)
                    Link("Help & support", destination: URL(string: "https://github.com/BakedChicken77/bjj-telestrator/blob/main/docs/SUPPORT.md")!)
                    Link("Privacy policy", destination: URL(string: "https://github.com/BakedChicken77/bjj-telestrator/blob/main/docs/PRIVACY.md")!)
                }
            }

    }
    private var deletedList: some View {
        NavigationStack {
            List {
                if library.deleted.isEmpty { Text("No deleted reviews.").foregroundStyle(.secondary) }
                ForEach(library.deleted) { item in
                    VStack(alignment: .leading) {
                        Text(item.name).font(.headline)
                        Button("Restore", systemImage: "arrow.uturn.backward") { Task { await library.restore(item.id) } }.frame(minHeight: 44)
                    }
                }
            }.disabled(library.busy)
            .navigationTitle("Recently Deleted").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { recentlyDeleted = false } } }
            .overlay { if library.busy { ProgressView("Restoring…") } }
        }
    }
}

private struct BJJNativeLibraryRow: View {
    @ObservedObject var library: BJJNativeLibrary
    let review: BJJNativeReview
    @State private var thumbnail: UIImage?
    private var editedDate: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: review.updatedAt) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: review.updatedAt)
    }
    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let thumbnail { Image(uiImage: thumbnail).resizable().scaledToFit() }
                else { Image(systemName: review.problem == nil ? "film" : "exclamationmark.triangle").font(.title2) }
            }.frame(width: 80, height: 56).background(Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(review.name).font(.headline).foregroundStyle(.primary).lineLimit(2)
                if review.problem != nil { Text("Tap for details · original retained").font(.caption).foregroundStyle(.secondary) }
                else {
                    Text("\(Int(review.duration / 60))m \(Int(review.duration) % 60)s").font(.caption).foregroundStyle(.secondary)
                    if let date = editedDate {
                        Text(date, style: .date).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
        }.padding(.vertical, 6).frame(minHeight: 64)
            .task(id: "\(review.key)-\(review.updatedAt)") { thumbnail = await library.thumbnail(review) }
    }
}
