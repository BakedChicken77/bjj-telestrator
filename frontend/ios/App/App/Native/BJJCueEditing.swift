import UIKit

/// Geometry stays in source coordinates. UIKit converts touches through the fitted,
/// zoomed picture; these operations are also used by the accessible property sheet.
enum BJJCueGeometry {
    static func clamp(_ x: CGFloat) -> CGFloat { min(1, max(0, x)) }
    static func bounds(_ cue: BJJJSON, size: CGSize) -> CGRect {
        let g = cue["geometry"] as! BJJJSON
        switch cue.s("type") {
        case "line", "arrow":
            return CGRect(x: min(g.n("x1"), g.n("x2")), y: min(g.n("y1"), g.n("y2")),
                          width: abs(g.n("x2") - g.n("x1")), height: abs(g.n("y2") - g.n("y1")))
        case "rectangle": return CGRect(x: g.n("x"), y: g.n("y"), width: g.n("width"), height: g.n("height"))
        case "ellipse": return CGRect(x: g.n("centerX") - g.n("radiusX"), y: g.n("centerY") - g.n("radiusY"), width: 2 * g.n("radiusX"), height: 2 * g.n("radiusY"))
        case "freehand":
            let p = g["points"] as! [BJJJSON], xs = p.map { $0.n("x") }, ys = p.map { $0.n("y") }
            return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        default:
            let fontSize = g.n("fontSize") * min(size.width, size.height)
            let font = UIFont(name: "DejaVuSans", size: fontSize) ?? UIFont.systemFont(ofSize: fontSize)
            let lines = g.s("text").components(separatedBy: "\n")
            let width = max(1, lines.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 1) / size.width
            let factor: CGFloat = g.s("alignment") == "center" ? 0.5 : g.s("alignment") == "right" ? 1 : 0
            return CGRect(x: g.n("x") - width * factor, y: g.n("y"), width: width, height: CGFloat(lines.count) * fontSize * 1.2 / size.height)
        }
    }
    static func map(_ cue: BJJJSON, _ transform: (CGPoint) -> CGPoint) -> BJJJSON {
        var result = cue, g = cue["geometry"] as! BJJJSON
        func point(_ x: String, _ y: String) -> CGPoint { transform(CGPoint(x: g.n(x), y: g.n(y))) }
        switch cue.s("type") {
        case "line", "arrow":
            let a = point("x1", "y1"), b = point("x2", "y2")
            g["x1"] = a.x; g["y1"] = a.y; g["x2"] = b.x; g["y2"] = b.y
        case "rectangle", "ellipse":
            let b = bounds(cue, size: CGSize(width: 1, height: 1))
            let a = transform(b.origin), z = transform(CGPoint(x: b.maxX, y: b.maxY))
            if cue.s("type") == "rectangle" {
                g["x"] = min(a.x, z.x); g["y"] = min(a.y, z.y); g["width"] = abs(z.x - a.x); g["height"] = abs(z.y - a.y)
            } else {
                g["centerX"] = (a.x + z.x) / 2; g["centerY"] = (a.y + z.y) / 2
                g["radiusX"] = abs(z.x - a.x) / 2; g["radiusY"] = abs(z.y - a.y) / 2
            }
        case "freehand":
            g["points"] = (g["points"] as! [BJJJSON]).map { p -> BJJJSON in
                var p = p; let q = transform(CGPoint(x: p.n("x"), y: p.n("y"))); p["x"] = q.x; p["y"] = q.y; return p
            }
        default: let p = point("x", "y"); g["x"] = p.x; g["y"] = p.y
        }
        result["geometry"] = g; return result
    }
    static func move(_ cue: BJJJSON, delta: CGPoint, size: CGSize) -> BJJJSON {
        let b = bounds(cue, size: size)
        let dx = min(max(-b.minX, 1 - b.maxX), max(-b.minX, delta.x))
        let dy = min(max(-b.minY, 1 - b.maxY), max(-b.minY, delta.y))
        return map(cue) { CGPoint(x: clamp($0.x + dx), y: clamp($0.y + dy)) }
    }
    static func resize(_ cue: BJJJSON, corner: Int, to p: CGPoint, size: CGSize) -> BJJJSON {
        let b = bounds(cue, size: size), minimum: CGFloat = 0.001
        let opposite = CGPoint(x: corner % 2 == 0 ? b.maxX : b.minX, y: corner < 2 ? b.maxY : b.minY)
        let x = clamp(corner % 2 == 0 ? min(p.x, opposite.x - minimum) : max(p.x, opposite.x + minimum))
        let y = clamp(corner < 2 ? min(p.y, opposite.y - minimum) : max(p.y, opposite.y + minimum))
        let next = CGRect(x: min(x, opposite.x), y: min(y, opposite.y), width: abs(x - opposite.x), height: abs(y - opposite.y))
        let sx = next.width / max(minimum, b.width), sy = next.height / max(minimum, b.height)
        var result = map(cue) { CGPoint(x: clamp(next.minX + ($0.x - b.minX) * sx), y: clamp(next.minY + ($0.y - b.minY) * sy)) }
        if cue.s("type") == "text" {
            var g = result["geometry"] as! BJJJSON
            g["fontSize"] = min(0.5, max(0.005, g.n("fontSize") * min(sx, sy))); result["geometry"] = g
        }
        return result
    }
    static func endpoint(_ cue: BJJJSON, index: Int, to p: CGPoint) -> BJJJSON {
        var result = cue, g = cue["geometry"] as! BJJJSON
        g[index == 0 ? "x1" : "x2"] = clamp(p.x); g[index == 0 ? "y1" : "y2"] = clamp(p.y)
        result["geometry"] = g; return result
    }
    static func handles(_ cue: BJJJSON, size: CGSize) -> [CGPoint] {
        let g = cue["geometry"] as! BJJJSON
        if ["line", "arrow"].contains(cue.s("type")) {
            return [CGPoint(x: g.n("x1"), y: g.n("y1")), CGPoint(x: g.n("x2"), y: g.n("y2"))]
        }
        let b = bounds(cue, size: size)
        return [b.origin, CGPoint(x: b.maxX, y: b.minY), CGPoint(x: b.minX, y: b.maxY), CGPoint(x: b.maxX, y: b.maxY)]
    }
    static func hit(_ cue: BJJJSON, point: CGPoint, size: CGSize, tolerance: CGFloat) -> Bool {
        func pixels(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * size.width, y: p.y * size.height) }
        let p = pixels(point), g = cue["geometry"] as! BJJJSON
        func segment(_ a: CGPoint, _ b: CGPoint) -> Bool {
            let a = pixels(a), b = pixels(b), dx = b.x - a.x, dy = b.y - a.y
            let t = min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / max(0.00001, dx * dx + dy * dy)))
            return hypot(p.x - a.x - t * dx, p.y - a.y - t * dy) <= tolerance + cue.n("strokeWidth") * min(size.width, size.height) / 2
        }
        if ["line", "arrow"].contains(cue.s("type")) {
            return segment(CGPoint(x: g.n("x1"), y: g.n("y1")), CGPoint(x: g.n("x2"), y: g.n("y2")))
        }
        if cue.s("type") == "freehand" {
            let points = g["points"] as! [BJJJSON]
            return zip(points, points.dropFirst()).contains { a, b in segment(CGPoint(x: a.n("x"), y: a.n("y")), CGPoint(x: b.n("x"), y: b.n("y"))) }
        }
        let b = bounds(cue, size: size)
        return CGRect(x: b.minX * size.width, y: b.minY * size.height, width: b.width * size.width, height: b.height * size.height).insetBy(dx: -tolerance, dy: -tolerance).contains(p)
    }
    static func sample(_ points: [CGPoint], _ point: CGPoint, size: CGSize, force: Bool = false) -> [CGPoint] {
        guard force || (points.last.map({ hypot((point.x - $0.x) * size.width, (point.y - $0.y) * size.height) >= 2 }) ?? true) else { return points }
        let retained = points.count >= 4000 ? points.enumerated().filter { $0.offset % 2 == 0 }.map { $0.element } : points
        return retained + [point]
    }
}

extension BJJNativeEditorSession {
    var selectedCue: BJJJSON? { project.annotations.first { $0.s("id") == selectedID } }
    var displayCues: [BJJJSON] {
        (draftOrder ?? project.annotations).map { cue in
            guard let previewCue, previewCue.s("id") == cue.s("id") else { return cue }
            var preview = previewCue; preview["zIndex"] = cue["zIndex"]; return preview
        }
    }
    var pictureSize: CGSize { CGSize(width: project.source.n("displayWidth"), height: project.source.n("displayHeight")) }
    func select(_ id: String?, seekToCue: Bool = false) {
        cancelCueEdit(); pause(); selectedID = id; selecting = true; drawing = true
        if seekToCue, let cue = selectedCue { seek(cue.n("startSec")) }
    }
    func updateCue(_ cue: BJJJSON, expectedRevision: Int? = nil) throws {
        guard !exporting, expectedRevision == nil || expectedRevision == project.revision,
              let index = project.annotations.firstIndex(where: { $0.s("id") == cue.s("id") }) else {
            throw BJJError.invalid("This cue changed while you were editing. Reopen its properties and try again.")
        }
        var annotations = project.annotations, updated = cue
        updated["updatedAt"] = BJJProject.now(); annotations[index] = updated
        try commit(annotations)
    }
    func beginInspector() {
        guard let cue = selectedCue else { return }
        cancelCueEdit(); pause(); inspectingCue = true
        editRevision = project.revision; cueDraft = cue; previewCue = cue
    }
    func stageCue(_ cue: BJJJSON) {
        cueDraft = cue
        var document = project.json; document["annotations"] = [cue]
        if (try? BJJProject(document)) != nil { previewCue = cue }
    }
    func saveInspector() throws {
        guard let cue = cueDraft, let revision = editRevision, revision == project.revision else {
            throw BJJError.invalid("This review changed. Cancel and reopen the cue before saving.")
        }
        guard cueEditDirty else { cancelCueEdit(); return }
        var annotations = draftOrder ?? project.annotations
        guard let index = annotations.firstIndex(where: { $0.s("id") == cue.s("id") }) else {
            throw BJJError.invalid("This cue no longer exists.")
        }
        var updated = cue; updated["updatedAt"] = BJJProject.now()
        if let draftOrder, let ordered = draftOrder.first(where: { $0.s("id") == cue.s("id") }) { updated["zIndex"] = ordered["zIndex"] }
        annotations[index] = updated
        try commit(annotations) // Failed saves retain the draft and its revision.
    }
    func deleteInspector() throws {
        guard let revision = editRevision, revision == project.revision, let id = selectedID else {
            throw BJJError.invalid("This review changed. Cancel and reopen the cue before deleting.")
        }
        try commit(project.annotations.filter { $0.s("id") != id })
    }
    func beginCueEdit() {
        pause()
        if inspectingCue { gestureSnapshot = previewCue; return }
        cancelCueEdit(); editRevision = project.revision; previewCue = selectedCue
    }
    func finishCueEdit() {
        if inspectingCue {
            if let previewCue { var staged = cueDraft ?? previewCue; staged["geometry"] = previewCue["geometry"]; stageCue(staged) }
            gestureSnapshot = nil; return
        }
        let cue = previewCue, revision = editRevision
        guard let cue, let revision else { return }
        do { try updateCue(cue, expectedRevision: revision) }
        catch { self.error = error.localizedDescription; cancelCueEdit() }
    }
    func cancelCueGesture() {
        if inspectingCue { if let gestureSnapshot { previewCue = gestureSnapshot }; gestureSnapshot = nil }
        else { cancelCueEdit() }
    }
    func cancelCueEdit() {
        previewCue = nil; cueDraft = nil; editRevision = nil
        inspectingCue = false; draftOrder = nil; gestureSnapshot = nil
    }
    func layer(_ id: String, forward: Bool) {
        var ordered = (draftOrder ?? project.annotations).enumerated().sorted {
            $0.element.n("zIndex") == $1.element.n("zIndex") ? $0.offset < $1.offset : $0.element.n("zIndex") < $1.element.n("zIndex")
        }.map { $0.element }
        guard let index = ordered.firstIndex(where: { $0.s("id") == id }) else { return }
        let next = forward ? index + 1 : index - 1
        guard ordered.indices.contains(next) else { return }
        ordered.swapAt(index, next)
        for i in ordered.indices { ordered[i]["zIndex"] = i; ordered[i]["updatedAt"] = BJJProject.now() }
        if inspectingCue { draftOrder = ordered; return }
        do { try commit(ordered) } catch { self.error = error.localizedDescription }
    }
}

/// Range handles snap to output frames and cannot cross or leave the video.
enum BJJCueTiming {
    static func adjust(_ cue: BJJJSON, start: Bool, seconds: Double, duration: Double, fps: Double) -> BJJJSON {
        guard seconds.isFinite, duration > 0, fps > 0 else { return cue }
        let gap = min(1 / fps, duration)
        let snapped = min(duration, max(0, (seconds * fps).rounded() / fps))
        var result = cue
        if start { result["startSec"] = max(0, min(cue.n("endSec") - gap, snapped)) }
        else { result["endSec"] = min(duration, max(cue.n("startSec") + gap, snapped)) }
        return result
    }
}
