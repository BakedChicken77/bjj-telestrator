import SwiftUI
import UIKit
import AVFoundation
import CoreImage

struct BJJOriginalEditor: UIViewControllerRepresentable {
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
    @State private var showAudio = false
    @State private var showExport = false
    @State private var confirmRecord = false
    @State private var showAnnotations = false
    @State private var showText = false
    @State private var showProperties = false
    @State private var propertiesCollapsed = false
    @State private var listCueID: String?
    @State private var zoomReset = 0
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let landscape = geometry.size.width > geometry.size.height
                if showProperties, let cue = session.selectedCue {
                    let layout = landscape ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
                    layout {
                        videoSurface.frame(height: landscape || propertiesCollapsed ? nil : geometry.size.height * 0.60)
                        VStack(spacing: 0) {
                            Button(propertiesCollapsed ? "Expand properties" : "Collapse properties", systemImage: propertiesCollapsed ? "chevron.up" : "chevron.down") { propertiesCollapsed.toggle() }
                                .frame(minHeight: 44).accessibilityIdentifier("cue.properties.collapse")
                            properties(cue).frame(maxHeight: propertiesCollapsed ? 0 : .infinity)
                                .clipped().opacity(propertiesCollapsed ? 0 : 1).accessibilityHidden(propertiesCollapsed)
                        }.frame(width: landscape ? (propertiesCollapsed ? 160 : min(320, geometry.size.width * 0.38)) : nil)
                    }.frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    VStack(spacing: 0) {
                        videoSurface
                        if !landscape { filmstrip.disabled(session.recording || session.preparingAudio) }
                        if session.drawing && !landscape { cueStrip }
                        transport.disabled(session.recording || session.preparingAudio)
                        controls
                    }.frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle(session.project.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !showProperties {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { session.close(); dismiss() }.disabled(session.exporting || session.recording || session.preparingAudio).accessibilityIdentifier("editor.done")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Cues", systemImage: "list.bullet") { session.pause(); showAnnotations = true }.disabled(showProperties || session.recording || session.preparingAudio).accessibilityIdentifier("editor.cues")
                    Button("Export", systemImage: "square.and.arrow.up") { session.pause(); showExport = true }
                        .accessibilityIdentifier("editor.export")
                        .disabled(showProperties || session.exporting || session.recording || session.preparingAudio)
                }
                }
            }
            .sheet(isPresented: $showAudio) { BJJNativeAudioScreen(session: session) }
            .sheet(isPresented: $showExport) { BJJNativeExportScreen(session: session) }
            .sheet(isPresented: Binding(get: { session.exportURL != nil }, set: { if !$0 { session.releaseExport() } })) {
                if let url = session.exportURL { BJJNativeExportPreview(url: url) }
            }
            .confirmationDialog("Record narration at 1×", isPresented: $confirmRecord, titleVisibility: .visible) {
                Button("Start recording") { Task { await session.startRecording() } }
            } message: { Text("Use headphones to avoid recording the speaker. Bluetooth can switch to its microphone audio quality. Playback begins before capture, and recording stops if the route changes.") }
            .sheet(isPresented: $showAnnotations, onDismiss: {
                if let id = listCueID { listCueID = nil; openProperties(id) }
            }) { annotationList }
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
                        Text("Keep the app open. Your saved review and audio mix are being rendered.").font(.footnote)
                        Button("Cancel export", role: .cancel) { session.cancelExport() }
                    }.padding(24).frame(maxWidth: 320).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                }
            }
            .task { await session.prepareAudio(); await session.prepareThumbnails() }
            .onChange(of: scenePhase) { _, phase in if phase == .background { BJJDiagnostics.shared.record(.background); session.stopRecording(); session.cancelCueGesture(); session.pause() } else if phase != .active && !session.recording { session.cancelCueGesture(); session.pause() } }
            .interactiveDismissDisabled(session.recording || session.exporting || session.preparingAudio)
            .onDisappear { session.close() }
        }
    }
    private var videoSurface: some View {
        BJJNativeVideoSurface(session: session, reset: zoomReset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("editor.video")
            .background(.black)
            .allowsHitTesting(!session.preparingAudio && !session.recording)
            .accessibilityLabel("Video and annotations")
            .accessibilityHint("Choose Draw to add or select cues. Tap a cue label to edit it.")
    }
    private func openProperties(_ id: String) {
        session.select(id, seekToCue: true); session.beginInspector(); propertiesCollapsed = false; showProperties = true
    }
    private func properties(_ cue: BJJJSON) -> some View {
        BJJCueProperties(session: session, cue: cue, onClose: { showProperties = false })
            .id(cue.s("id"))
    }
    private var filmstrip: some View {
        GeometryReader { geometry in
            let count = max(1, session.thumbnails.count)
            let width = max(1, (geometry.size.width - CGFloat(count - 1) * 2) / CGFloat(count))
            HStack(spacing: 2) {
                ForEach(Array(session.thumbnails.enumerated()), id: \.offset) { index, image in
                    Button { session.seek(session.project.duration * Double(index) / 8) } label: {
                        Image(uiImage: image).resizable().scaledToFill().frame(width: width, height: 44).clipped()
                    }.buttonStyle(.plain)
                        .accessibilityLabel("Seek to \(Int(session.project.duration * Double(index) / 8)) seconds")
                }
            }
        }.frame(height: session.thumbnails.isEmpty ? 0 : 44).clipped().padding(.horizontal, 12)
    }
    private var transport: some View {
        HStack(spacing: 12) {
            Button(session.playing ? "Pause" : "Play", systemImage: session.playing ? "pause.fill" : "play.fill") { session.togglePlayback() }
                .labelStyle(.iconOnly).font(.title2).frame(width: 44, height: 44)
            Slider(value: Binding(get: { session.outputTime }, set: { session.seekOutput($0) }), in: 0...session.project.outputDuration)
                .accessibilityLabel("Video position").accessibilityValue("\(Int(session.time)) seconds")
            Text(String(format: "%02d:%02d", Int(session.outputTime) / 60, Int(session.outputTime) % 60))
                .monospacedDigit().font(.caption)
            Button("Fit video", systemImage: "arrow.down.right.and.arrow.up.left") { zoomReset += 1 }
                .labelStyle(.iconOnly).frame(width: 44, height: 44)
        }.padding(.horizontal, 12)
    }
    private var controls: some View {
        VStack(spacing: 8) {
            if session.recording {
                HStack {
                    Label(session.recordingVideoPaused ? "Recording · video paused" : "Recording at 1×", systemImage: "mic.fill").foregroundStyle(.red)
                    ProgressView(value: Double(max(0, min(1, (session.recordingLevel + 60) / 60))))
                    Button(session.recordingVideoPaused ? "Resume video" : "Pause video", systemImage: session.recordingVideoPaused ? "play.fill" : "pause.fill") { Task { await session.toggleRecordingVideo() } }
                        .accessibilityIdentifier("narration.video.pause")
                    Button("Stop", systemImage: "stop.fill") { session.stopRecording() }.buttonStyle(.borderedProminent).tint(.red)
                }
                Text(session.audioRoute).font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    Button("Record", systemImage: "mic.fill") { session.pause(); confirmRecord = true }
                    Spacer()
                    Button("Narration", systemImage: "waveform") { session.pause(); showAudio = true }
                }.frame(minHeight: 44).disabled(session.preparingAudio || session.exporting)
                if session.preparingAudio { ProgressView("Preparing audio preview…") }
                if let notice = session.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            }
            HStack(spacing: 12) {
                Picker("Editor mode", selection: $session.drawing) {
                    Text("Review").tag(false)
                    Text("Draw").tag(true)
                }.pickerStyle(.segmented).frame(maxWidth: 240).disabled(session.recording || session.preparingAudio)
                Spacer(minLength: 0)
                Button("Undo", systemImage: "arrow.uturn.backward") { session.history(redo: false) }
                    .disabled(session.undoCount == 0 || session.recording || session.preparingAudio).labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                Button("Redo", systemImage: "arrow.uturn.forward") { session.history(redo: true) }
                    .disabled(session.redoCount == 0 || session.recording || session.preparingAudio).labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
            }
            if session.drawing {
                HStack {
                    Menu {
                        Button("Select / move", systemImage: "cursorarrow") { session.select(nil) }
                        ForEach(BJJNativeTool.allCases) { tool in
                            Button(tool.title, systemImage: tool.symbol) {
                                session.cancelCueEdit(); session.selecting = false; session.tool = tool
                                if tool == .text { showText = true }
                            }
                        }
                    } label: { Label(session.selecting ? "Select" : session.tool.title, systemImage: session.selecting ? "cursorarrow" : session.tool.symbol).frame(minHeight: 44) }
                    Spacer()
                    if !session.selecting {
                        ForEach(["#FF453A", "#FFD60A", "#0A84FF", "#FFFFFF"], id: \.self) { color in
                            Button { session.color = color } label: {
                                Circle().fill(Color(uiColor: BJJNativeCanvas.color(color))).frame(width: 22, height: 22)
                                    .padding(5).overlay(Circle().stroke(session.color == color ? Color.primary : .clear, lineWidth: 2))
                                    .frame(width: 44, height: 44)
                            }.accessibilityLabel("\(color == "#FF453A" ? "Red" : color == "#FFD60A" ? "Yellow" : color == "#0A84FF" ? "Blue" : "White") cue")
                                .accessibilityAddTraits(session.color == color ? .isSelected : [])
                        }
                    }
                }
            }
            if !session.drawing && !session.recording {
                HStack {
                    Menu {
                        ForEach([Float(0.25), 0.5, 1, 2], id: \.self) { speed in
                            Button("\(String(format: "%g", speed))×") { session.setSpeed(speed) }
                        }
                    } label: { Text("\(String(format: "%g", session.speed))×").monospacedDigit().frame(minWidth: 44, minHeight: 44) }
                        .accessibilityLabel("Playback speed")
                    Spacer()
                    Menu {
                        Button("Start here") { session.markLoop(start: true) }
                        Button("End here") { session.markLoop(start: false) }
                        Button(session.loopEnabled ? "Turn loop off" : "Turn loop on") { session.toggleLoop() }
                        Text(String(format: "%.1f – %.1f seconds", session.loopStart, session.loopEnd))
                    } label: { Label(session.loopEnabled ? "Loop on" : "Loop", systemImage: "repeat").frame(minHeight: 44) }
                }
            }

        }.padding(.horizontal, 12).padding(.bottom, 8).background(.bar).disabled(session.exporting)
    }
    private var cueStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(session.project.annotations.sorted { $0.n("startSec") < $1.n("startSec") }, id: \.selfID) { cue in
                    Button { openProperties(cue.s("id")) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(cue.s("type").capitalized) · \(cue.n("startSec"), specifier: "%.1f")–\(cue.n("endSec"), specifier: "%.1f")s").font(.caption)
                            GeometryReader { geo in
                                Capsule().fill(.secondary.opacity(0.2))
                                Capsule().fill(session.selectedID == cue.s("id") ? Color.accentColor : Color.secondary)
                                    .frame(width: max(2, geo.size.width * (cue.n("endSec") - cue.n("startSec")) / session.project.duration))
                                    .offset(x: geo.size.width * cue.n("startSec") / session.project.duration)
                            }.frame(height: 4)
                        }.padding(.horizontal, 8).frame(width: 150, height: 44)
                    }.buttonStyle(.bordered).accessibilityIdentifier("cue.strip.\(cue.s("id"))").accessibilityAddTraits(session.selectedID == cue.s("id") ? .isSelected : [])
                }
            }.padding(.horizontal, 12)
        }.frame(height: session.project.annotations.isEmpty ? 0 : 52)
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
                            listCueID = cue.s("id"); showAnnotations = false
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(cue.s("type") == "text" ? (cue["geometry"] as! BJJJSON).s("text") : cue.s("type").capitalized)
                                Text(String(format: "%.1f – %.1f seconds", cue.n("startSec"), cue.n("endSec")))
                                    .font(.caption).foregroundStyle(.secondary)
                            }.frame(minHeight: 44)
                        }
                        Spacer()
                        Button { listCueID = cue.s("id"); showAnnotations = false } label: { Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44) }
                            .accessibilityLabel("Edit \(cue.s("type")) properties")
                        Button("Delete cue", systemImage: "trash", role: .destructive) { session.remove(cue.s("id")) }
                            .labelStyle(.iconOnly).frame(width: 44, height: 44)
                    }
                }
            }
            .buttonStyle(.borderless)
            .navigationTitle("Cues").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showAnnotations = false }.accessibilityIdentifier("cues.done") } }
        }.presentationDetents([.medium, .large])
    }
}

private extension Dictionary where Key == String, Value == Any {
    var selfID: String { self["id"] as! String }
}

struct BJJNativeShare: UIViewControllerRepresentable {
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
    private let selection = CAShapeLayer()
    private var gestureCue: BJJJSON?
    private var gestureStart = CGPoint.zero
    private var handleIndex: Int?
    private var previewSignature = ""
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
        picture.layer.addSublayer(selection)
        selection.strokeColor = UIColor.systemCyan.cgColor; selection.fillColor = UIColor.clear.cgColor
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
        video.frame = picture.bounds; overlay.frame = picture.bounds; draft.frame = picture.bounds; selection.frame = picture.bounds
        applyTransform(); refresh(reset: resetValue)
    }
    func detach() { video.player = nil; cancelStroke() }
    func refresh(reset: Int) {
        if reset != resetValue { resetValue = reset; scale = 1; offset = .zero; cancelStroke(); applyTransform() }
        if !session.drawing || session.exporting { cancelStroke() }
        let size = picture.bounds.size
        guard size.width > 1, size.height > 1 else { return }
        do {
            let previewKey = session.previewCue.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]).base64EncodedString() } ?? ""
            let orderKey = session.displayCues.map { "\($0.s("id")):\($0.n("zIndex"))" }.joined(separator: ",")
            if renderRevision != session.project.revision || renderSize != size || previewSignature != previewKey + orderKey {
                previewSignature = previewKey + orderKey
                let cues = session.displayCues
                renderer = try BJJOverlay(annotations: cues, size: size, fps: session.project.exportSettings.n("fps"))
                renderRevision = session.project.revision; renderSize = size; signature = "invalid"
            }
            let visible = session.displayCues.filter { BJJProject.visible($0, time: session.time, fps: session.project.exportSettings.n("fps")) }.map { $0.s("id") }.joined(separator: ",")
            if signature != visible {
                signature = visible
                if let image = renderer?.image(at: session.time), let cg = imageContext.createCGImage(image, from: image.extent) {
                    overlay.image = UIImage(cgImage: cg)
                } else { overlay.image = nil }
            }
        } catch { session.error = error.localizedDescription }
        drawSelection()
    }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if let pan = gestureRecognizer as? UIPanGestureRecognizer, pan.minimumNumberOfTouches == 1 {
            return session.drawing && !session.exporting && picture.bounds.contains(pan.location(in: picture))
        }
        return true
    }
    private func candidates(at point: CGPoint) -> [BJJJSON] {
        session.project.annotations.enumerated().filter {
            BJJProject.visible($0.element, time: session.time, fps: session.project.exportSettings.n("fps")) &&
            BJJCueGeometry.hit($0.element, point: point, size: picture.bounds.size, tolerance: 22 / scale)
        }.sorted {
            $0.element.n("zIndex") == $1.element.n("zIndex") ? $0.offset > $1.offset : $0.element.n("zIndex") > $1.element.n("zIndex")
        }.map { $0.element }
    }
    @objc private func drawGesture(_ gesture: UIPanGestureRecognizer) {
        guard session.drawing, !session.exporting else { cancelStroke(); return }
        let point = BJJNativeGeometry.point(gesture.location(in: picture), in: picture.bounds)
        if session.selecting {
            switch gesture.state {
            case .began:
                session.pause(); gestureStart = point; handleIndex = nil
                if let cue = session.previewCue ?? session.selectedCue, BJJProject.visible(cue, time: session.time, fps: session.project.exportSettings.n("fps")) {
                    let handles = BJJCueGeometry.handles(cue, size: picture.bounds.size)
                    handleIndex = handles.indices.min(by: { distance(handles[$0], point) < distance(handles[$1], point) })
                    if let i = handleIndex, distance(handles[i], point) > 22 / scale { handleIndex = nil }
                    if session.inspectingCue { handleIndex = nil }
                    if handleIndex != nil || BJJCueGeometry.hit(cue, point: point, size: picture.bounds.size, tolerance: 22 / scale) { gestureCue = cue }
                }
                if gestureCue == nil && !session.inspectingCue { session.select(candidates(at: point).first?.s("id")); gestureCue = session.selectedCue }
                session.beginCueEdit()
            case .changed, .ended:
                guard let cue = gestureCue else { return }
                if let i = handleIndex {
                    session.previewCue = ["line", "arrow"].contains(cue.s("type")) ? BJJCueGeometry.endpoint(cue, index: i, to: point) : BJJCueGeometry.resize(cue, corner: i, to: point, size: picture.bounds.size)
                } else {
                    session.previewCue = BJJCueGeometry.move(cue, delta: CGPoint(x: point.x - gestureStart.x, y: point.y - gestureStart.y), size: picture.bounds.size)
                }
                refresh(reset: resetValue)
                if gesture.state == .ended { gestureCue = nil; session.finishCueEdit(); drawSelection() }
            default: cancelStroke()
            }
            return
        }
        switch gesture.state {
        case .began: session.pause(); points = [point]; drawDraft()
        case .changed: points = BJJCueGeometry.sample(points, point, size: picture.bounds.size); drawDraft()
        case .ended:
            points = BJJCueGeometry.sample(points, point, size: picture.bounds.size, force: true)
            let completed = points; cancelStroke(); session.add(completed)
        default: cancelStroke()
        }
    }
    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot((a.x - b.x) * picture.bounds.width, (a.y - b.y) * picture.bounds.height)
    }
    @objc private func tapGesture(_ gesture: UITapGestureRecognizer) {
        guard session.drawing, !session.exporting, picture.bounds.contains(gesture.location(in: picture)) else { return }
        let point = BJJNativeGeometry.point(gesture.location(in: picture), in: picture.bounds)
        if session.selecting {
            guard !session.inspectingCue else { return }
            let cues = candidates(at: point)
            let current = cues.firstIndex { $0.s("id") == session.selectedID }
            session.select(cues.isEmpty ? nil : cues[(current.map { ($0 + 1) % cues.count }) ?? 0].s("id"))
            drawSelection()
        } else if session.tool == .text { session.add([point]) }
    }
    private func drawSelection() {
        guard session.drawing, session.selecting, let cue = session.previewCue ?? session.selectedCue,
              BJJProject.visible(cue, time: session.time, fps: session.project.exportSettings.n("fps")) else { selection.path = nil; return }
        let b = BJJCueGeometry.bounds(cue, size: picture.bounds.size)
        let rect = CGRect(x: b.minX * picture.bounds.width, y: b.minY * picture.bounds.height, width: b.width * picture.bounds.width, height: b.height * picture.bounds.height)
        let path = UIBezierPath(rect: rect)
        for p in BJJCueGeometry.handles(cue, size: picture.bounds.size) {
            path.append(UIBezierPath(ovalIn: CGRect(x: p.x * picture.bounds.width - 5 / scale, y: p.y * picture.bounds.height - 5 / scale, width: 10 / scale, height: 10 / scale)))
        }
        selection.lineWidth = 2 / scale; selection.path = path.cgPath
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
        drawSelection()
    }
    private func cancelStroke() { points.removeAll(); draft.path = nil; gestureCue = nil; handleIndex = nil; session.cancelCueGesture() }
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
