import Foundation

enum BJJProjectMigrations {
    static let currentVersion = 2
    static let supported = ["project.revisions.v1"]
    static let registry: [Int: (BJJJSON) -> BJJJSON] = [
        1: { document in
            var result = document
            result["schemaVersion"] = 2
            result["revision"] = 1
            var capabilities = document["requiredCapabilities"] as? [String] ?? []
            if !capabilities.contains("project.revisions.v1") { capabilities.append("project.revisions.v1") }
            result["requiredCapabilities"] = capabilities
            return result
        }
    ]
    static func migrate(_ document: BJJJSON) throws -> BJJJSON {
        let version = try BJJValidate.number(document["schemaVersion"], "schema version", 1...9007199254740991, integer: true)
        guard version <= Double(currentVersion) else {
            throw BJJError.domain("SCHEMA_UNSUPPORTED", "Upgrade required: this project uses a newer format.")
        }
        let capabilities = document["requiredCapabilities"] ?? [String]()
        guard let list = capabilities as? [String], list.count <= 128,
              list.allSatisfy({ !$0.isEmpty && $0.count <= 100 }), Set(list).count == list.count else {
            throw BJJError.domain("PROJECT_CORRUPT", "The project capability list is invalid.")
        }
        guard list.allSatisfy({ supported.contains($0) }) else {
            throw BJJError.domain("CAPABILITY_UNSUPPORTED", "Upgrade required: this project needs unsupported capabilities.")
        }
        var result = document
        var current = Int(version)
        while current < currentVersion {
            guard let migrate = registry[current] else { throw BJJError.invalid("Missing project migration.") }
            result = migrate(result)
            current += 1
        }
        guard (result["requiredCapabilities"] as? [String])?.contains("project.revisions.v1") == true else {
            throw BJJError.domain("PROJECT_CORRUPT", "The project revision capability is missing.")
        }
        return result
    }
    static var capabilities: BJJJSON {
        ["schemaVersion": currentVersion, "requiredCapabilities": supported,
         "conditionalSave": true, "conditionalExport": true, "recoveryCopy": true,
         "exportRetry": true, "storageBreakdown": true, "exportFileCleanup": true, "projectCheckpoints": true, "projectDuplicate": true, "projectTrash": true]
    }
}
