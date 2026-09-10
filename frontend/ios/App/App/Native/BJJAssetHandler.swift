import Foundation
import WebKit

struct BJJByteRange: Equatable {
    let first: Int64
    let last: Int64
    var count: Int64 { last - first + 1 }
    static func parse(_ header: String?, size: Int64) throws -> BJJByteRange {
        guard size > 0 else { throw BJJError.invalid("The media file is empty.") }
        guard let header else { return BJJByteRange(first: 0, last: size - 1) }
        guard header.hasPrefix("bytes="), !header.contains(",") else { throw BJJError.invalid("Unsupported byte range.") }
        let parts = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw BJJError.invalid("Invalid byte range.") }
        if parts[0].isEmpty {
            guard let suffix = Int64(parts[1]), suffix > 0 else { throw BJJError.invalid("Invalid byte range.") }
            return BJJByteRange(first: max(0, size - suffix), last: size - 1)
        }
        guard let first = Int64(parts[0]), first >= 0, first < size else { throw BJJError.invalid("Invalid byte range.") }
        let last: Int64
        if parts[1].isEmpty { last = size - 1 }
        else {
            guard let requested = Int64(parts[1]), requested >= first else { throw BJJError.invalid("Invalid byte range.") }
            last = min(size - 1, requested)
        }
        return BJJByteRange(first: first, last: last)
    }
}

private final class BJJAssetRequest {
    private let lock = NSLock()
    private var stopped = false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
}

/// Same-origin media routes with UUID authorization and bounded 256 KiB disk reads.
/// Capacitor's normal handler still serves bundled HTML, JavaScript, CSS and fonts.
final class BJJAssetHandler: NSObject, WKURLSchemeHandler {
    private let fallback: WKURLSchemeHandler
    private var active: [ObjectIdentifier: BJJAssetRequest] = [:]
    init(fallback: WKURLSchemeHandler) { self.fallback = fallback; super.init() }
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { task.didFailWithError(URLError(.badURL)); return }
        if url.path.hasPrefix("/_capacitor_file_") {
            task.didFailWithError(URLError(.noPermissionsToReadFile)); return
        }
        guard url.path.hasPrefix("/bjj-media/") else { fallback.webView(webView, start: task); return }
        let state = BJJAssetRequest(), key = ObjectIdentifier(task as AnyObject)
        active[key] = state
        let request = task.request
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            func deliver(_ action: @escaping () -> Void) {
                DispatchQueue.main.sync { if !state.cancelled { action() } }
            }
            defer { DispatchQueue.main.async { self?.active.removeValue(forKey: key) } }
            do {
                let store = try BJJStore()
                let parts = url.path.split(separator: "/").map(String.init)
                guard parts.count == 3 || parts.count == 4, parts[0] == "bjj-media" else { throw URLError(.badURL) }
                let id = try BJJValidate.uuid(parts[1])
                let reference: String, mime: String
                if parts.count == 3 && parts[2] == "video.mp4" {
                    reference = try store.load(id).proxy.s("asset"); mime = "video/mp4"
                } else if parts.count == 4 && parts[2] == "voiceover" && parts[3].hasSuffix(".wav") {
                    let clipId = try BJJValidate.uuid(String(parts[3].dropLast(4)))
                    guard let clip = try store.recordings(id)[clipId] as? BJJJSON else { throw URLError(.fileDoesNotExist) }
                    reference = clip.s("asset"); mime = "audio/wav"
                } else { throw URLError(.badURL) }
                let file = try store.asset(id, reference)
                let size = Int64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
                let range: BJJByteRange
                do { range = try BJJByteRange.parse(request.value(forHTTPHeaderField: "Range"), size: size) }
                catch {
                    let response = HTTPURLResponse(url: url, statusCode: 416, httpVersion: "HTTP/1.1", headerFields: ["Content-Range": "bytes */\(size)"])!
                    deliver { task.didReceive(response); task.didFinish() }; return
                }
                var headers = ["Content-Type": mime, "Accept-Ranges": "bytes", "Content-Length": String(range.count), "Cache-Control": "no-store"]
                let partial = request.value(forHTTPHeaderField: "Range") != nil
                if partial { headers["Content-Range"] = "bytes \(range.first)-\(range.last)/\(size)" }
                let response = HTTPURLResponse(url: url, statusCode: partial ? 206 : 200, httpVersion: "HTTP/1.1", headerFields: headers)!
                deliver { task.didReceive(response) }
                if request.httpMethod != "HEAD" {
                    let handle = try FileHandle(forReadingFrom: file)
                    defer { try? handle.close() }
                    try handle.seek(toOffset: UInt64(range.first))
                    var remaining = range.count
                    while remaining > 0 && !state.cancelled {
                        let data = try handle.read(upToCount: Int(min(262144, remaining))) ?? Data()
                        guard !data.isEmpty else { throw URLError(.cannotDecodeContentData) }
                        remaining -= Int64(data.count)
                        deliver { task.didReceive(data) }
                    }
                }
                deliver { task.didFinish() }
            } catch { deliver { task.didFailWithError(error) } }
        }
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        let key = ObjectIdentifier(task as AnyObject)
        if let state = active.removeValue(forKey: key) { state.cancel() }
        else { fallback.webView(webView, stop: task) }
    }
}
