import SwiftUI
import UIKit
import AVFoundation
import CoreImage

struct BJJNativeHome: View {
    @State private var reviews: [BJJNativeReview] = []
    @State private var session: BJJNativeEditorSession?
    @State private var originalEditor = false
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("A new way to review", systemImage: "hand.draw")
                            .font(.title2.bold())
                        Text("Try native playback and drawing on a separate copy of a saved review. Your original stays unchanged.")
                        Text("This first preview focuses on the feel of the editor. Import, narration playback/recording, and advanced editing remain in the original editor.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("Open original editor", systemImage: "square.stack") { originalEditor = true }
                            .buttonStyle(.bordered).frame(minHeight: 44)
                    }.padding(.vertical, 8)
                }
                if reviews.isEmpty && !busy {
                    ContentUnavailableView("No saved reviews", systemImage: "film", description: Text("Import a video in the original editor, then come back to try a native copy."))
                }
                ForEach([true, false], id: \.self) { preview in
                    let items = reviews.filter { $0.preview == preview }
                    if !items.isEmpty {
                        Section(preview ? "Continue a preview copy" : "Create a preview copy") {
                            ForEach(items) { review in
                                Button { open(review) } label: {
                                    HStack(spacing: 14) {
                                        Image(systemName: preview ? "play.rectangle.fill" : "film.stack")
                                            .font(.title2).frame(width: 40).foregroundStyle(.tint)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(review.name).font(.headline).foregroundStyle(.primary).lineLimit(2)
                                            Text("\(Int(review.duration / 60))m \(Int(review.duration) % 60)s · \(preview ? "Saved copy" : "Original preserved")")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                                    }.padding(.vertical, 8).frame(minHeight: 60)
                                }.disabled(busy)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Your reviews")
            .overlay { if busy { ProgressView("Preparing safe copy…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18)) } }
            .task { await refresh() }
            .refreshable { await refresh() }
            .fullScreenCover(isPresented: $originalEditor, onDismiss: { Task { await refresh() } }) {
                BJJOriginalEditor()
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("BJJReturnToNative"))) { _ in originalEditor = false }
            .fullScreenCover(item: $session, onDismiss: { Task { await refresh() } }) { editor in
                BJJNativeEditorScreen(session: editor)
            }
            .alert("Unable to open review", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
        }
    }
    @MainActor private func refresh() async {
        do {
            reviews = try await BJJAssets.offMain {
                try BJJNativePilot.reviews(BJJStore(root: BJJNativePilot.previewRoot()), preview: true)
                + BJJNativePilot.reviews(BJJStore(), preview: false)
            }
        } catch { self.error = error.localizedDescription }
    }
    private func open(_ review: BJJNativeReview) {
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                let previewStore = try BJJStore(root: BJJNativePilot.previewRoot())
                let project = try await BJJAssets.offMain {
                    if review.preview { return try previewStore.loadRecoveringRecordings(review.id) }
                    return try BJJNativePilot.copy(review.id, from: BJJStore(), to: previewStore)
                }
                session = try BJJNativeEditorSession(project: project, store: previewStore)
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct BJJOriginalEditor: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UINavigationController {
        let editor = BJJViewController()
        editor.navigationItem.title = "Original editor"
        editor.navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak editor] _ in
            editor?.webView?.evaluateJavaScript("window.dispatchEvent(new Event('bjj-return-to-native'))", completionHandler: nil)
        })
        return UINavigationController(rootViewController: editor)
    }
    func updateUIViewController(_ controller: UINavigationController, context: Context) { }
}

struct BJJNativeEditorScreen: View {
    @ObservedObject var session: BJJNativeEditorSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var showAnnotations = false
    @State private var showText = false
    @State private var zoomReset = 0
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let landscape = geometry.size.width > geometry.size.height
                VStack(spacing: 0) {
                    BJJNativeVideoSurface(session: session, reset: zoomReset)
                        .background(.black)
                        .accessibilityLabel("Video and annotations")
                        .accessibilityHint("Choose Draw to add a cue. Use the Cues button to navigate or delete annotations.")
                    if !landscape { filmstrip }
                    transport
                    controls
                }
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle("Preview copy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { session.close(); dismiss() }.disabled(session.exporting)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Cues", systemImage: "list.bullet") { session.pause(); showAnnotations = true }
                    Button("Export", systemImage: "square.and.arrow.up") { Task { await session.export() } }
                        .disabled(session.exporting)
                }
            }
            .sheet(isPresented: $showAnnotations) { annotationList }
            .sheet(isPresented: $showText) {
                NavigationStack {
                    Form {
                        TextField("Your cue", text: $session.text, axis: .vertical)
                            .lineLimit(3...6)
                        Text("Close this sheet, then tap or drag on the video to place the text.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .navigationTitle("Text cue").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showText = false } } }
                }.presentationDetents([.medium, .large])
            }
            .sheet(isPresented: Binding(get: { session.shareURL != nil }, set: { if !$0 { session.shareURL = nil } })) {
                if let url = session.shareURL { BJJNativeShare(url: url) }
            }
            .alert("Review needs attention", isPresented: Binding(get: { session.error != nil }, set: { if !$0 { session.error = nil } })) {
                Button("OK") { session.error = nil }
            } message: { Text(session.error ?? "") }
            .overlay {
                if session.exporting {
                    VStack(spacing: 16) {
                        Text("Exporting MP4").font(.headline)
                        ProgressView(value: session.exportProgress)
                        Text("Keep the app open. Your saved copy is being rendered with its existing audio.").font(.footnote)
                        Button("Cancel export", role: .cancel) { session.cancelExport() }
                    }.padding(24).frame(maxWidth: 320).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                }
            }
            .task { await session.prepareThumbnails() }
            .onChange(of: scenePhase) { _, phase in if phase != .active { session.pause() } }
            .onDisappear { session.close() }
        }
    }
    private var filmstrip: some View {
        HStack(spacing: 2) {
            ForEach(Array(session.thumbnails.enumerated()), id: \.offset) { index, image in
                Button { session.seek(session.project.duration * Double(index) / 8) } label: {
                    Image(uiImage: image).resizable().scaledToFill().frame(maxWidth: .infinity).frame(height: 44).clipped()
                }.accessibilityLabel("Seek to \(Int(session.project.duration * Double(index) / 8)) seconds")
            }
        }.frame(height: session.thumbnails.isEmpty ? 0 : 44).clipped().padding(.horizontal, 12)
    }
    private var transport: some View {
        HStack(spacing: 12) {
            Button(session.playing ? "Pause" : "Play", systemImage: session.playing ? "pause.fill" : "play.fill") { session.togglePlayback() }
                .labelStyle(.iconOnly).font(.title2).frame(width: 44, height: 44)
            Slider(value: Binding(get: { session.time }, set: { session.seek($0) }), in: 0...session.project.duration)
                .accessibilityLabel("Video position").accessibilityValue("\(Int(session.time)) seconds")
            Text(String(format: "%02d:%02d", Int(session.time) / 60, Int(session.time) % 60))
                .monospacedDigit().font(.caption)
            Button("Fit video", systemImage: "arrow.down.right.and.arrow.up.left") { zoomReset += 1 }
                .labelStyle(.iconOnly).frame(width: 44, height: 44)
        }.padding(.horizontal, 12)
    }
    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Picker("Editor mode", selection: $session.drawing) {
                    Text("Review").tag(false)
                    Text("Draw").tag(true)
                }.pickerStyle(.segmented).frame(maxWidth: 240)
                Spacer(minLength: 0)
                Button("Undo", systemImage: "arrow.uturn.backward") { session.history(redo: false) }
                    .disabled(session.undoCount == 0).labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                Button("Redo", systemImage: "arrow.uturn.forward") { session.history(redo: true) }
                    .disabled(session.redoCount == 0).labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
            }
            if session.drawing {
                HStack {
                    Menu {
                        ForEach(BJJNativeTool.allCases) { tool in
                            Button(tool.title, systemImage: tool.symbol) {
                                session.tool = tool
                                if tool == .text { showText = true }
                            }
                        }
                    } label: { Label(session.tool.title, systemImage: session.tool.symbol).frame(minHeight: 44) }
                    Spacer()
                    ForEach(["#FF453A", "#FFD60A", "#0A84FF", "#FFFFFF"], id: \.self) { color in
                        Button {
                            session.color = color
                        } label: {
                            Circle().fill(Color(uiColor: BJJNativeCanvas.color(color)))
                                .frame(width: 22, height: 22)
                                .padding(5).overlay(Circle().stroke(session.color == color ? Color.primary : .clear, lineWidth: 2))
                                .frame(width: 44, height: 44)
                        }.accessibilityLabel("\(color == "#FF453A" ? "Red" : color == "#FFD60A" ? "Yellow" : color == "#0A84FF" ? "Blue" : "White") cue")
                            .accessibilityAddTraits(session.color == color ? .isSelected : [])
                    }
                }
            }
            if !session.project.voiceovers.isEmpty {
                Text("Preview plays source audio. Existing narration is preserved in exports; native narration playback is the next milestone.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.horizontal, 12).padding(.bottom, 8).background(.bar)
    }
    private var annotationList: some View {
        NavigationStack {
            List {
                if session.project.annotations.isEmpty {
                    Text("Choose Draw and add a cue to the video.").foregroundStyle(.secondary)
                }
                ForEach(session.project.annotations, id: \.selfID) { cue in
                    HStack {
                        Button {
                            session.seek(cue.n("startSec")); showAnnotations = false
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(cue.s("type").capitalized)
                                Text(String(format: "%.1f – %.1f seconds", cue.n("startSec"), cue.n("endSec")))
                                    .font(.caption).foregroundStyle(.secondary)
                            }.frame(minHeight: 44)
                        }
                        Spacer()
                        Button("Delete cue", systemImage: "trash", role: .destructive) { session.remove(cue.s("id")) }
                            .labelStyle(.iconOnly).frame(width: 44, height: 44)
                    }
                }
            }
            .navigationTitle("Cues").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showAnnotations = false } } }
        }.presentationDetents([.medium, .large])
    }
}

private extension Dictionary where Key == String, Value == Any {
    var selfID: String { self["id"] as! String }
}

private struct BJJNativeShare: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}

struct BJJNativeVideoSurface: UIViewRepresentable {
    @ObservedObject var session: BJJNativeEditorSession
    var reset: Int
    func makeUIView(context: Context) -> BJJNativeCanvas { BJJNativeCanvas(session: session) }
    func updateUIView(_ view: BJJNativeCanvas, context: Context) { view.refresh(reset: reset) }
    static func dismantleUIView(_ view: BJJNativeCanvas, coordinator: ()) { view.detach() }
}

final class BJJNativeCanvas: UIView, UIGestureRecognizerDelegate {
    private let session: BJJNativeEditorSession
    private let picture = UIView()
    private let video = AVPlayerLayer()
    private let overlay = UIImageView()
    private let draft = CAShapeLayer()
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private var renderer: BJJOverlay?
    private var renderRevision = -1
    private var renderSize = CGSize.zero
    private var signature = ""
    private var points: [CGPoint] = []
    private var resetValue = 0
    private var scale: CGFloat = 1
    private var offset = CGPoint.zero
    private var pinchStart: CGFloat = 1
    private var panStart = CGPoint.zero
    init(session: BJJNativeEditorSession) {
        self.session = session
        super.init(frame: .zero)
        clipsToBounds = true
        picture.clipsToBounds = true
        addSubview(picture)
        picture.layer.addSublayer(video)
        picture.addSubview(overlay)
        picture.layer.addSublayer(draft)
        video.player = session.player; video.videoGravity = .resizeAspect
        draft.fillColor = UIColor.clear.cgColor; draft.lineCap = .round; draft.lineJoin = .round
        let draw = UIPanGestureRecognizer(target: self, action: #selector(drawGesture(_:)))
        draw.maximumNumberOfTouches = 1; draw.delegate = self; addGestureRecognizer(draw)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinchGesture(_:)))
        pinch.delegate = self; addGestureRecognizer(pinch)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panGesture(_:)))
        pan.minimumNumberOfTouches = 2; pan.delegate = self; addGestureRecognizer(pan)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapGesture(_:)))
        tap.delegate = self; addGestureRecognizer(tap)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        let source = session.project.source
        let ratio = source.n("displayWidth") / source.n("displayHeight")
        let size = CGSize(width: min(bounds.width, bounds.height * ratio), height: min(bounds.height, bounds.width / ratio))
        if renderSize != size { cancelStroke(); scale = 1; offset = .zero }
        picture.transform = .identity
        picture.bounds = CGRect(origin: .zero, size: size)
        picture.center = CGPoint(x: bounds.midX, y: bounds.midY)
        video.frame = picture.bounds; overlay.frame = picture.bounds; draft.frame = picture.bounds
        applyTransform(); refresh(reset: resetValue)
    }
    func detach() { video.player = nil; cancelStroke() }
    func refresh(reset: Int) {
        if reset != resetValue { resetValue = reset; scale = 1; offset = .zero; cancelStroke(); applyTransform() }
        if !session.drawing { cancelStroke() }
        let size = picture.bounds.size
        guard size.width > 1, size.height > 1 else { return }
        do {
            if renderRevision != session.project.revision || renderSize != size {
                renderer = try BJJOverlay(annotations: session.project.annotations, size: size, fps: session.project.exportSettings.n("fps"))
                renderRevision = session.project.revision; renderSize = size; signature = "invalid"
            }
            let visible = session.project.annotations.filter { BJJProject.visible($0, time: session.time, fps: session.project.exportSettings.n("fps")) }.map { $0.s("id") }.joined(separator: ",")
            if signature != visible {
                signature = visible
                if let image = renderer?.image(at: session.time), let cg = imageContext.createCGImage(image, from: image.extent) {
                    overlay.image = UIImage(cgImage: cg)
                } else { overlay.image = nil }
            }
        } catch { session.error = error.localizedDescription }
    }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if let pan = gestureRecognizer as? UIPanGestureRecognizer, pan.minimumNumberOfTouches == 1 {
            return session.drawing && picture.bounds.contains(pan.location(in: picture))
        }
        return true
    }
    @objc private func drawGesture(_ gesture: UIPanGestureRecognizer) {
        guard session.drawing else { cancelStroke(); return }
        let point = BJJNativeGeometry.point(gesture.location(in: picture), in: picture.bounds)
        switch gesture.state {
        case .began: session.pause(); points = [point]; drawDraft()
        case .changed:
            if points.count < 4000 { points.append(point) }; drawDraft()
        case .ended:
            if points.count < 4000 { points.append(point) }
            let completed = points; cancelStroke(); session.add(completed)
        default: cancelStroke()
        }
    }
    @objc private func tapGesture(_ gesture: UITapGestureRecognizer) {
        guard session.drawing, session.tool == .text, picture.bounds.contains(gesture.location(in: picture)) else { return }
        session.add([BJJNativeGeometry.point(gesture.location(in: picture), in: picture.bounds)])
    }
    @objc private func pinchGesture(_ gesture: UIPinchGestureRecognizer) {
        cancelStroke()
        if gesture.state == .began { pinchStart = scale }
        scale = min(4, max(1, pinchStart * gesture.scale)); applyTransform()
    }
    @objc private func panGesture(_ gesture: UIPanGestureRecognizer) {
        cancelStroke()
        if gesture.state == .began { panStart = offset }
        let delta = gesture.translation(in: self)
        offset = CGPoint(x: panStart.x + delta.x, y: panStart.y + delta.y); applyTransform()
    }
    private func applyTransform() {
        let maxX = max(0, (picture.bounds.width * scale - bounds.width) / 2)
        let maxY = max(0, (picture.bounds.height * scale - bounds.height) / 2)
        offset.x = min(maxX, max(-maxX, offset.x)); offset.y = min(maxY, max(-maxY, offset.y))
        picture.transform = CGAffineTransform(translationX: offset.x, y: offset.y).scaledBy(x: scale, y: scale)
    }
    private func cancelStroke() { points.removeAll(); draft.path = nil }
    private func drawDraft() {
        guard let first = points.first, let last = points.last else { return }
        func screen(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * picture.bounds.width, y: p.y * picture.bounds.height) }
        let a = screen(first), b = screen(last)
        let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        let path: UIBezierPath
        if session.tool == .rectangle { path = UIBezierPath(rect: rect) }
        else if session.tool == .ellipse { path = UIBezierPath(ovalIn: rect) }
        else {
            path = UIBezierPath(); path.move(to: a)
            if session.tool == .freehand { for p in points.dropFirst() { path.addLine(to: screen(p)) } }
            else { path.addLine(to: b) }
        }
        draft.path = path.cgPath; draft.strokeColor = Self.color(session.color).cgColor
        draft.lineWidth = max(2, min(picture.bounds.width, picture.bounds.height) * 0.006)
    }
    static func color(_ hex: String) -> UIColor {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return UIColor(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
                       blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}
