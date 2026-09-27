import SwiftUI

/// Edits are staged until Save. Dismissal, cancellation and invalid input never
/// write a partially edited cue, and revision checking rejects stale sheets.
struct BJJCueProperties: View {
    @ObservedObject var session: BJJNativeEditorSession
    @Environment(\.dismiss) private var dismiss
    @State private var cue: BJJJSON
    @State private var problem: String?
    private let revision: Int
    init(session: BJJNativeEditorSession, cue: BJJJSON) {
        self.session = session; _cue = State(initialValue: cue); revision = session.project.revision
    }
    private var geometry: BJJJSON { cue["geometry"] as! BJJJSON }
    var body: some View {
        NavigationStack {
            Form {
                Section("Timing · seconds") {
                    number("Start", "startSec", range: 0...session.project.duration)
                    number("End", "endSec", range: 0...session.project.duration)
                    Button("Start here") { cue["startSec"] = session.time }
                    Button("End here") { cue["endSec"] = session.time }
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
                if let problem { Section { Text(problem).foregroundStyle(.red).accessibilityLabel("Cannot save: \(problem)") } }
            }
            .navigationTitle("\(cue.s("type").capitalized) properties").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do { try session.updateCue(cue, expectedRevision: revision); dismiss() }
                        catch { problem = error.localizedDescription }
                    }
                }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) } }
            }
        }
    }
    private func move(_ x: CGFloat, _ y: CGFloat) { cue = BJJCueGeometry.move(cue, delta: CGPoint(x: x, y: y), size: session.pictureSize) }
    private func resize(_ factor: CGFloat) {
        let b = BJJCueGeometry.bounds(cue, size: session.pictureSize)
        cue = BJJCueGeometry.resize(cue, corner: 3, to: CGPoint(x: b.minX + b.width * factor, y: b.minY + b.height * factor), size: session.pictureSize)
    }
    private func set(_ key: String, _ value: Any, nested: Bool) {
        if nested { var g = geometry; g[key] = value; cue["geometry"] = g } else { cue[key] = value }
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
