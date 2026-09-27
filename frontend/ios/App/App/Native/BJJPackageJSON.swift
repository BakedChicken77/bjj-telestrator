import Foundation

/// JSONSerialization discards duplicate keys. Check structure/keys first so an
/// untrusted package has the same meaning in Swift and Python.
enum BJJPackageJSON {
    static func read(_ data: Data) throws -> BJJJSON {
        let bytes = [UInt8](data)
        var index = 0
        func space() { while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
        func string() throws -> String {
            guard index < bytes.count, bytes[index] == 34 else { throw BJJPackageArchive.invalid("Invalid package JSON.") }
            let start = index; index += 1
            while index < bytes.count {
                let byte = bytes[index]; index += 1
                if byte == 92 {
                    guard index < bytes.count else { throw BJJPackageArchive.invalid() }
                    index += 1
                } else if byte == 34 {
                    guard let result = try JSONSerialization.jsonObject(with: Data(bytes[start..<index]), options: .fragmentsAllowed) as? String else { throw BJJPackageArchive.invalid() }
                    return result
                }
            }
            throw BJJPackageArchive.invalid("The package JSON is incomplete.")
        }
        func value(_ depth: Int) throws {
            space()
            guard depth <= 64, index < bytes.count else { throw BJJPackageArchive.invalid("The package JSON is incomplete or too deeply nested.") }
            let byte = bytes[index]
            if byte == 34 { _ = try string(); return }
            if byte == 123 || byte == 91 {
                index += 1; space()
                let close: UInt8 = byte == 123 ? 125 : 93
                var keys = Set<String>()
                if index < bytes.count && bytes[index] == close { index += 1; return }
                while index < bytes.count {
                    space()
                    if byte == 123 {
                        let key = try string()
                        guard keys.insert(key).inserted else { throw BJJPackageArchive.invalid("Duplicate JSON fields are not allowed in project packages.") }
                        space()
                        guard index < bytes.count, bytes[index] == 58 else { throw BJJPackageArchive.invalid() }
                        index += 1
                    }
                    try value(depth + 1); space()
                    guard index < bytes.count else { throw BJJPackageArchive.invalid() }
                    if bytes[index] == close { index += 1; return }
                    guard bytes[index] == 44 else { throw BJJPackageArchive.invalid() }
                    index += 1
                }
                throw BJJPackageArchive.invalid()
            }
            let start = index
            while index < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
            guard index > start else { throw BJJPackageArchive.invalid() }
        }
        try value(0); space()
        guard index == bytes.count, let object = try JSONSerialization.jsonObject(with: data) as? BJJJSON else { throw BJJPackageArchive.invalid("Invalid package JSON.") }
        return object
    }
    static func data(_ object: BJJJSON) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}
