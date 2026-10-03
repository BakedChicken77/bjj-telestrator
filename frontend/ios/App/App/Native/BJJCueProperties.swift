import SwiftUI

/// Edits are staged until Save. Dismissal, cancellation and invalid input never
/// write a partially edited cue, and revision checking rejects stale sheets.
struct BJJCueProperties: View {
    @ObservedObject var session: BJJNativeEditorSession
    @Environment(\.dismiss) private var dismiss
    private var cue: BJJJSON {
        get { session.cueDraft ?? session.selectedCue ?? initialCue }
        nonmutating set { session.stageCue(newValue) }
    }
    @State private var problem: String?
    private let initialCue: BJJJSON
    private let onClose: (() -> Void)?
    init(session: BJJNativeEditorSession, cue: BJJJSON, onClose: (() -> Void)? = nil) {
        self.onClose = onClose; self.session = session; initialCue = cue
    }
    private var geometry: BJJJSON { cue["geometry"] as! BJJJSON }
    var body: some View {
        NavigationStack {
            Form {
                Section("Timing · seconds") {
                    BJJCueRangeBar(start: cue.n("startSec"), end: cue.n("endSec"),
                                   duration: session.project.duration, fps: session.project.exportSettings.n("fps"),
                                   change: changeBoundary)
                    Text("Drag either handle to set when the cue appears. The video follows the handle.").font(.caption)
                    Slider(value: Binding(get: { session.time }, set: { session.seek($0) }), in: 0...session.project.duration)
                        .accessibilityLabel("Preview video position")
                    DisclosureGroup("Precise timing") {
                        number("Start", "startSec", range: 0...session.project.duration)
                        number("End", "endSec", range: 0...session.project.duration)
                        Button("Start here") { changeBoundary(true, session.time) }
                        Button("End here") { changeBoundary(false, session.time) }
                    }
                    Text("The cue appears at Start and disappears at End. Times are video seconds.").font(.footnote)
                }
                Section("Appearance") {
                    color("Stroke color", "strokeColor")
                    number("Stroke width (%)", "strokeWidth", range: 0.000001...0.1, factor: 100)
                    number("Opacity (%)", "strokeOpacity", range: 0...1, factor: 100)
                    if ["rectangle", "ellipse"].contains(cue.s("type")) {
                        color("Fill color", "fillColor")
                        number("Fill opacity (%)", "fillOpacity", range: 0...1, factor: 100)
                    }
                    if cue.s("type") == "arrow" { number("Arrowhead size (%)", "arrowheadSize", range: 0.000001...0.5, factor: 100, nested: true) }
                }
                if cue.s("type") == "text" {
                    Section("Text") {
                        TextField("Cue text", text: string("text", nested: true), axis: .vertical).lineLimit(2...8)
                        number("Text size (%)", "fontSize", range: 0.000001...0.5, factor: 100, nested: true)
                        Picker("Alignment", selection: string("alignment", nested: true)) {
                            Text("Left").tag("left"); Text("Center").tag("center"); Text("Right").tag("right")
                        }
                        color("Background color", "backgroundColor", nested: true)
                        number("Background opacity (%)", "backgroundOpacity", range: 0...1, factor: 100, nested: true)
                    }
                }
                Section("Position · percent of video") {
                    if ["line", "arrow"].contains(cue.s("type")) {
                        number("Start X", "x1", factor: 100, nested: true); number("Start Y", "y1", factor: 100, nested: true)
                        number("End X", "x2", factor: 100, nested: true); number("End Y", "y2", factor: 100, nested: true)
                    } else if cue.s("type") == "ellipse" {
                        number("Center X", "centerX", factor: 100, nested: true); number("Center Y", "centerY", factor: 100, nested: true)
                        number("Horizontal radius", "radiusX", range: 0.0001...1, factor: 100, nested: true)
                        number("Vertical radius", "radiusY", range: 0.0001...1, factor: 100, nested: true)
                    } else if cue.s("type") != "freehand" {
                        number("X", "x", factor: 100, nested: true); number("Y", "y", factor: 100, nested: true)
                        if cue.s("type") == "rectangle" {
                            number("Width", "width", range: 0.0001...1, factor: 100, nested: true)
                            number("Height", "height", range: 0.0001...1, factor: 100, nested: true)
                        }
                    }
                    Button("Move left 1%") { move(-0.01, 0) }; Button("Move right 1%") { move(0.01, 0) }
                    Button("Move up 1%") { move(0, -0.01) }; Button("Move down 1%") { move(0, 0.01) }
                    if cue.s("type") == "freehand" {
                        Button("Make 10% larger") { resize(1.1) }; Button("Make 10% smaller") { resize(0.9) }
                    }
                }
                Section("Cue actions") {
                    Button("Forward one layer") { session.layer(cue.s("id"), forward: true) }
                    Button("Backward one layer") { session.layer(cue.s("id"), forward: false) }
                    Button("Delete cue", role: .destructive) {
                        do { try session.deleteInspector(); close() }
                        catch { problem = error.localizedDescription }
                    }.accessibilityIdentifier("cue.properties.delete")
                }
                if let problem { Section { Text(problem).foregroundStyle(.red).accessibilityLabel("Cannot save: \(problem)") } }
            }
            .navigationTitle("\(cue.s("type").capitalized) properties").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { close() }.accessibilityIdentifier("cue.properties.cancel") }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do { try session.saveInspector(); close() }
                        catch { problem = error.localizedDescription }
                    }.accessibilityIdentifier("cue.properties.save")
                }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) } }
            }
        }

    }
    private func close() { session.cancelCueEdit(); if let onClose { onClose() } else { dismiss() } }
    private func changeBoundary(_ start: Bool, _ seconds: Double) {
        cue = BJJCueTiming.adjust(cue, start: start, seconds: seconds, duration: session.project.duration, fps: session.project.exportSettings.n("fps"))
        let position = start ? cue.n("startSec") : max(cue.n("startSec"), cue.n("endSec") - 1 / session.project.exportSettings.n("fps"))
        session.seek(position)
    }
    private func move(_ x: CGFloat, _ y: CGFloat) { cue = BJJCueGeometry.move(cue, delta: CGPoint(x: x, y: y), size: session.pictureSize) }
    private func resize(_ factor: CGFloat) {
        let b = BJJCueGeometry.bounds(cue, size: session.pictureSize)
        cue = BJJCueGeometry.resize(cue, corner: 3, to: CGPoint(x: b.minX + b.width * factor, y: b.minY + b.height * factor), size: session.pictureSize)
    }
    private func set(_ key: String, _ value: Any, nested: Bool) {
        if nested { var g = geometry; g[key] = value; cue["geometry"] = g } else { cue[key] = value }
        // Invalid numeric drafts stay in the form until corrected, never in the renderer.
        var document = session.project.json; document["annotations"] = [cue]
        if (try? BJJProject(document)) != nil { session.previewCue = cue }
    }
    private func string(_ key: String, nested: Bool = false) -> Binding<String> {
        Binding(get: { (nested ? geometry : cue).s(key) }, set: { set(key, $0, nested: nested) })
    }
    private func number(_ title: String, _ key: String, range: ClosedRange<Double> = 0...1, factor: Double = 1, nested: Bool = false) -> some View {
        let value = Binding<Double>(get: { (nested ? geometry : cue).n(key) * factor }, set: { set(key, $0 / factor, nested: nested) })
        return VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline)
            HStack {
                TextField(title, value: value, format: .number.precision(.fractionLength(0...3)))
                    .keyboardType(.decimalPad).accessibilityLabel(title)
                Stepper(title, value: value, in: (range.lowerBound * factor)...(range.upperBound * factor), step: factor == 1 ? 0.1 : 1)
                    .labelsHidden().accessibilityLabel("Adjust \(title)")
            }.frame(minHeight: 44)
        }
    }
    private func color(_ title: String, _ key: String, nested: Bool = false) -> some View {
        ColorPicker(title, selection: Binding(get: { Color(uiColor: BJJNativeCanvas.color((nested ? geometry : cue).s(key))) }, set: { color in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
            set(key, String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255)), nested: nested)
        }), supportsOpacity: false)
    }
}

/// Both handles share the full-video scale. Separate touch lanes keep short
/// cues editable even when their start and end positions are almost identical.
struct BJJCueRangeBar: View {
    let start: Double
    let end: Double
    let duration: Double
    let fps: Double
    let change: (Bool, Double) -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(String(format: "Start %.2fs", start))
                Spacer()
                Text(String(format: "End %.2fs", end))
            }.font(.caption).monospacedDigit()
            GeometryReader { geometry in
                let width = max(1, geometry.size.width - 44)
                let left = 22 + width * start / duration
                let right = 22 + width * end / duration
                ZStack(alignment: .topLeading) {
                    Capsule().fill(.secondary.opacity(0.2)).frame(width: width, height: 8).offset(x: 22, y: 44)
                    Capsule().fill(Color.accentColor).frame(width: max(2, right - left), height: 8).offset(x: left, y: 44)
                    handle(true, x: left, y: 22, width: width)
                    handle(false, x: right, y: 74, width: width)
                }.coordinateSpace(name: "cue.range")
            }.frame(height: 96)
            HStack { Text("0:00"); Spacer(); Text(String(format: "%02d:%02d", Int(duration) / 60, Int(duration) % 60)) }
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
    private func handle(_ isStart: Bool, x: CGFloat, y: CGFloat, width: CGFloat) -> some View {
        Image(systemName: isStart ? "arrow.right.to.line" : "arrow.left.to.line")
            .font(.headline).foregroundStyle(.white)
            .frame(width: 44, height: 44).background(Color.accentColor, in: Circle())
            .contentShape(Rectangle()).position(x: x, y: y)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("cue.range"))
                .onChanged { value in change(isStart, Double((value.location.x - 22) / width) * duration) })
            .accessibilityElement()
            .accessibilityLabel(isStart ? "Cue start" : "Cue end")
            .accessibilityValue(String(format: "%.2f seconds", isStart ? start : end))
            .accessibilityIdentifier(isStart ? "cue.range.start" : "cue.range.end")
            .accessibilityAdjustableAction { direction in
                let delta = direction == .increment ? 1 / fps : -1 / fps
                change(isStart, (isStart ? start : end) + delta)
            }
    }
}
