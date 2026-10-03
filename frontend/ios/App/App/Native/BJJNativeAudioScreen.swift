import SwiftUI
import AVKit
import Photos

struct BJJNativeAudioScreen: View {
    @ObservedObject var session: BJJNativeEditorSession
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("Mix") {
                    Toggle("Mute original", isOn: Binding(get: { session.project.settings["originalAudioMuted"] as? Bool ?? false }, set: { value in
                        var settings = session.project.settings; settings["originalAudioMuted"] = value; session.updateAudio(settings: settings)
                    }))
                    gain("Original volume", key: "originalAudioGain")
                    gain("Narration volume", key: "voiceoverMasterGain")
                }
                Section("Saved takes") {
                    if session.project.allTakes.isEmpty { Text("Position the video, then tap Record to narrate at 1×.").foregroundStyle(.secondary) }
                    ForEach(Array(session.project.allTakes.enumerated()), id: \.offset) { index, clip in
                        NavigationLink {
                            BJJNativeTakeScreen(session: session, clip: clip, number: index + 1)
                        } label: {
                            VStack(alignment: .leading) {
                                Text("Take \(index + 1)\((clip["muted"] as? Bool) == true ? " · Muted" : "")")
                                Text(String(format: "%.2f – %.2f seconds", takeStart(clip), takeEnd(clip))).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if !session.project.reviewTimeline.holds.isEmpty {
                    Section("Narration pauses") {
                        ForEach(session.project.reviewTimeline.holds, id: \.holdID) { hold in
                            HStack {
                                Text("Video \(hold.n("sourceTicks") / 48000, specifier: "%.2f")s · pause \(hold.n("durationTicks") / 48000, specifier: "%.2f")s")
                                Spacer()
                                Button("Remove pause", role: .destructive) { session.removeNarrationPause(hold.s("id")) }
                            }
                        }
                        Text("Deleting or muting a take keeps its video pauses. Removing a pause also removes audio placed inside it. Undo restores both.").font(.footnote)
                    }
                }
                Section { Text("Use headphones to keep playback out of the microphone. Bluetooth may switch to a lower-bandwidth microphone route while recording; the active route is shown with the take controls.").font(.footnote) }
            }
            .disabled(session.preparingAudio)
            .overlay { if session.preparingAudio { ProgressView("Preparing audio preview…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
            .navigationTitle("Narration").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("narration.done") } }
        }
    }
    private func takeStart(_ take: BJJJSON) -> Double { BJJTakeDisplay.start(take, project: session.project) }
    private func takeEnd(_ take: BJJJSON) -> Double { BJJTakeDisplay.end(take, project: session.project) }
    private func gain(_ title: String, key: String) -> some View {
        Stepper("\(title): \(session.project.settings.n(key), specifier: "%.1f")×", value: Binding(get: { session.project.settings.n(key) }, set: { value in
            var settings = session.project.settings; settings[key] = value; session.updateAudio(settings: settings)
        }), in: 0...2, step: 0.1)
    }
}

struct BJJNativeTakeScreen: View {
    @ObservedObject var session: BJJNativeEditorSession
    let clip: BJJJSON
    let number: Int
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    private var current: BJJJSON { session.project.allTakes.first { $0.s("id") == clip.s("id") } ?? clip }
    var body: some View {
        Form {
            Section {
                Button(session.playing ? "Pause preview" : "Preview in video", systemImage: session.playing ? "pause.fill" : "play.fill") {
                    if session.playing { session.pause() }
                    else { session.seekOutput(BJJTakeDisplay.start(current, project: session.project), resume: true) }
                }
                Toggle("Muted", isOn: Binding(get: { current["muted"] as? Bool ?? false }, set: { update("muted", $0) }))
                Stepper("Volume: \(current.n("gain"), specifier: "%.1f")×", value: Binding(get: { current.n("gain") }, set: { update("gain", $0) }), in: 0...2, step: 0.1)
            }
            Section("Timing") {
                Text(String(format: "Starts at %.2f seconds", BJJTakeDisplay.start(current, project: session.project)))
                HStack {
                    Button("Earlier 0.05s") { nudge(-0.05) }
                    Spacer()
                    Button("Later 0.05s") { nudge(0.05) }
                }.buttonStyle(.borderless)
                Text("Adjustments are saved immediately. Undo in the editor restores the previous mix or deleted take.").font(.footnote).foregroundStyle(.secondary)
            }
            Section { Button("Delete take", role: .destructive) { confirmDelete = true } }
        }
        .disabled(session.preparingAudio)
        .navigationTitle("Take \(number)")
        .confirmationDialog("Delete this take?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete take", role: .destructive) { session.updateAudio(removing: clip.s("id")); dismiss() }
        }
        .onDisappear { session.pause() }
    }
    private func nudge(_ delta: Double) {
        if current["placements"] != nil { session.nudgeReviewTake(current.s("id"), delta: delta) }
        else { update("timingOffsetMs", current.n("timingOffsetMs") + delta * 1000) }
    }
    private func update(_ key: String, _ value: Any) { var changed = current; changed[key] = value; session.updateAudio(clip: changed) }
}

struct BJJNativeExportScreen: View {
    @ObservedObject var session: BJJNativeEditorSession
    @Environment(\.dismiss) private var dismiss
    @State private var selectedRange = false
    @State private var start = 0.0
    @State private var end = 0.0
    @State private var maximum = 1920.0
    @State private var crf = 23.0
    var body: some View {
        NavigationStack {
            Form {
                Section("Range") {
                    Toggle("Selected range", isOn: $selectedRange)
                    if selectedRange {
                        LabeledContent("Start (seconds)") { TextField("Start", value: $start, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing).accessibilityLabel("Range start in seconds") }
                        LabeledContent("End (seconds)") { TextField("End", value: $end, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing).accessibilityLabel("Range end in seconds") }
                        Button("Use loop range") { start = session.project.reviewTimeline.output(before: session.loopStart); end = session.project.reviewTimeline.output(before: session.loopEnd) }
                    } else { Text("Full video · \(session.project.outputDuration, specifier: "%.1f") seconds") }
                }
                Section("Quality") {
                    Picker("Longest edge", selection: $maximum) {
                        Text("720 pixels").tag(720.0); Text("1280 pixels").tag(1280.0)
                        Text("1920 pixels").tag(1920.0); Text("3840 pixels").tag(3840.0)
                    }
                    Picker("Quality", selection: $crf) {
                        Text("Smaller file").tag(28.0); Text("Standard").tag(23.0); Text("High").tag(18.0)
                    }
                    Text("Keeps the video’s shape and never enlarges it. Includes the saved cues and audio mix.").font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Button("Export MP4", systemImage: "square.and.arrow.up") {
                        let options = BJJExportOptions(start: selectedRange ? start : 0, end: selectedRange ? end : session.project.outputDuration, maximum: maximum, crf: crf)
                        do { try options.validate(session.project); dismiss(); Task { await session.export(options: options) } }
                        catch { session.error = error.localizedDescription }
                    }.accessibilityIdentifier("export.start")
                    if let retry = session.retryExportID {
                        Button("Retry previous export") { dismiss(); Task { await session.export(retry: retry) } }
                        Text("Retries the same saved revision, range, and quality.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }.navigationTitle("Export video").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
                .onAppear { end = session.project.outputDuration }
        }
    }
}

struct BJJNativeExportPreview: View {
    let url: URL
    @State private var player: AVPlayer
    @State private var sharing = false
    @State private var saving = false
    @State private var message: String?
    @Environment(\.dismiss) private var dismiss
    init(url: URL) { self.url = url; _player = State(initialValue: AVPlayer(url: url)) }
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                VideoPlayer(player: player)
                HStack {
                    Button("Share / Save to Files", systemImage: "square.and.arrow.up") { player.pause(); sharing = true }
                    Spacer()
                    Button("Save to Photos", systemImage: "photo.badge.arrow.down") { Task { await savePhotos() } }.disabled(saving)
                }.padding()
            }.navigationTitle("Export ready").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { player.pause(); dismiss() }.disabled(saving).accessibilityIdentifier("export.done") } }
                .sheet(isPresented: $sharing) { BJJNativeShare(url: url) }
                .alert("Export", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("OK") { message = nil } } message: { Text(message ?? "") }
                .onDisappear { player.pause() }
                .interactiveDismissDisabled(saving)
        }
    }
    private func savePhotos() async {
        saving = true; defer { saving = false }
        let permission = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard permission == .authorized || permission == .limited else { message = "Allow Photos access in Settings, or use Save to Files."; return }
        do {
            try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url) }
            message = "Video saved to Photos."
        } catch { message = "Photos could not save the video. \(error.localizedDescription)" }
    }
}

private extension Dictionary where Key == String, Value == Any {
    var holdID: String { self["id"] as! String }
}

enum BJJTakeDisplay {
    static func start(_ take: BJJJSON, project: BJJProject) -> Double {
        if let placements = take["placements"] as? [BJJJSON] { return placements.compactMap { project.reviewTimeline.position($0) }.min() ?? 0 }
        return project.reviewTimeline.output(after: take.n("startSec") + take.n("timingOffsetMs") / 1000)
    }
    static func end(_ take: BJJJSON, project: BJJProject) -> Double {
        if let placements = take["placements"] as? [BJJJSON] { return placements.compactMap { p in project.reviewTimeline.position(p).map { $0 + p.n("durationTicks") / 48000 } }.max() ?? 0 }
        return project.reviewTimeline.output(before: take.n("endSec") + take.n("timingOffsetMs") / 1000)
    }
}
