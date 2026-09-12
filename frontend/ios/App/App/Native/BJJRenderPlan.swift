import Foundation

/// Local job input version 1. Its full project, asset identities and output intent
/// are immutable. No old annotation clock or project schema meaning changes.
struct BJJRenderPlan {
    let json: BJJJSON
    let project: BJJProject
    static func output(_ project: BJJProject) -> BJJJSON {
        let size = BJJRenderer.outputSize(CGSize(width: project.source.n("displayWidth"), height: project.source.n("displayHeight")))
        return ["startSec": 0, "endSec": project.duration, "width": Int(size.width), "height": Int(size.height),
                "fps": project.exportSettings.n("fps"), "quality": project.exportSettings,
                "container": "mp4", "videoCodec": "h264", "audioCodec": "aac", "pixelFormat": "yuv420p",
                "colorPolicy": "supported-sdr-v1", "audioPolicy": "linear-mix-v1"]
    }
    init(store: BJJStore, project: BJJProject) throws {
        let json: BJJJSON = ["version": 1, "projectId": project.id, "revision": project.revision,
                            "requiredCapabilities": project.json["requiredCapabilities"]!, "output": Self.output(project),
                            "project": project.json, "assets": try BJJAssets.manifest(store, project)]
        try self.init(json, projectId: project.id, revision: project.revision)
    }
    init(_ json: BJJJSON, projectId: String, revision: Int?) throws {
        let document = try BJJValidate.object(json["project"], "export project")
        let project = try BJJProject(document)
        try BJJValidate.number(json["version"], "render plan version", 1...1, integer: true)
        try BJJValidate.number(json["revision"], "render plan revision", 1...9007199254740991, integer: true)
        guard json["version"] as? Int == 1, json["projectId"] as? String == projectId,
              project.id == projectId, json["revision"] as? Int == revision, project.revision == revision,
              document["schemaVersion"] as? Int == project.json["schemaVersion"] as? Int,
              (json["requiredCapabilities"] as? [String]) == (project.json["requiredCapabilities"] as? [String]),
              let output = json["output"] as? BJJJSON, NSDictionary(dictionary: output).isEqual(to: Self.output(project)) else {
            throw BJJError.domain("EXPORT_INPUT_INVALID", "This export input is damaged or unsupported. Its media was preserved.")
        }
        let expected = BJJAssets.required(project)
        let assets = try BJJValidate.objects(json["assets"], "export assets", maximum: 100_000)
        var references = Set<String>(), identifiers = Set<String>()
        guard assets.count == expected.count else { throw BJJError.invalid("Invalid export asset count.") }
        for entry in assets {
            let reference = try BJJValidate.string(entry["reference"], "asset reference", max: 1024)
            let identifier = try BJJValidate.uuid(entry["assetId"] as? String)
            guard let (kind, metadata) = expected[reference], entry["kind"] as? String == kind,
                  references.insert(reference).inserted, identifiers.insert(identifier).inserted,
                  let actual = entry["metadata"] as? BJJJSON, NSDictionary(dictionary: actual).isEqual(to: metadata),
                  let digest = entry["sha256"] as? String, digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
                throw BJJError.domain("EXPORT_INPUT_INVALID", "An export asset identity is damaged or unsupported.")
            }
            try BJJValidate.number(entry["byteSize"], "asset byte size", 1...9007199254740991, integer: true)
        }
        self.json = json; self.project = project
    }
    static func path(_ store: BJJStore, _ job: BJJExportJob) throws -> URL {
        try BJJValidate.uuid(job.jobId)
        return try store.safeURL(job.projectId, "exports/inputs/\(job.jobId).json")
    }
    static func read(_ store: BJJStore, _ job: BJJExportJob) throws -> BJJRenderPlan {
        let path = try path(store, job)
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw BJJError.domain("EXPORT_INPUT_MISSING", "This older export has no saved retry input. Render the current review instead.")
        }
        return try BJJRenderPlan(store.readJSON(path), projectId: job.projectId, revision: job.projectRevision)
    }
    func verify(_ store: BJJStore, cancellation: BJJJobCancellation? = nil) throws {
        for entry in json["assets"] as! [BJJJSON] {
            let path = try BJJAssets.file(store, project.id, entry["reference"] as! String)
            let size = try path.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size == (entry["byteSize"] as! NSNumber).intValue,
                  try BJJAssets.digest(path, cancellation: cancellation) == entry["sha256"] as? String else {
                throw BJJError.domain("ASSET_CHANGED", "An asset differs from this export's original input. Restore the matching media before retrying.")
            }
        }
    }
}
