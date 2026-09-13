import Foundation
import CryptoKit
import ZIPFoundation
import Compression

struct BJJPackageLimits {
    var compressed: UInt64 = 16 * 1024 * 1024 * 1024
    var expanded: UInt64 = 16 * 1024 * 1024 * 1024
    var perFile: UInt64 = 4 * 1024 * 1024 * 1024
    var files = 512
    var metadata: UInt64 = 32 * 1024 * 1024
    var directory: UInt64 = 1024 * 1024
}

/// Preflight the raw directory before ZIPFoundation allocates or extracts entries.
/// A narrow generated ASCII grammar rejects Windows/Unicode path ambiguity.
final class BJJPackageArchive {
    struct Item {
        let name: String
        let bytes: UInt64
        let compressed: UInt64
        let crc: UInt32
        let offset: UInt64
        let method: UInt64
    }
    let url: URL
    let limits: BJJPackageLimits
    let items: [String: Item]
    private let archive: Archive
    private var expanded: UInt64 = 0
    static func invalid(_ message: String = "The project package is damaged or contains unsafe entries.") -> BJJError {
        .domain("PACKAGE_INVALID", message)
    }
    private static func number(_ data: Data, _ offset: Int, _ count: Int) throws -> UInt64 {
        guard offset >= 0, count > 0, count <= 8, offset <= data.count - count else { throw invalid() }
        return (0..<count).reduce(UInt64(0)) { $0 | UInt64(data[data.startIndex + offset + $1]) << ($1 * 8) }
    }
    private static func read(_ handle: FileHandle, _ offset: UInt64, _ count: Int) throws -> Data {
        try handle.seek(toOffset: offset)
        let result = try handle.read(upToCount: count) ?? Data()
        guard result.count == count else { throw invalid("The package transfer is incomplete.") }
        return result
    }
    static func allowedName(_ name: String) -> Bool {
        if name == "manifest.json" || name == "project.json" { return true }
        guard name.hasPrefix("assets/") else { return false }
        let id = String(name.dropFirst(7))
        return id.count == 36 && UUID(uuidString: id)?.uuidString.lowercased() == id
    }
    init(_ url: URL, limits: BJJPackageLimits = BJJPackageLimits()) throws {
        self.url = url; self.limits = limits
        let info = try url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey, .isRegularFileKey])
        let size = UInt64(max(0, info.fileSize ?? 0))
        guard info.isSymbolicLink != true, info.isRegularFile == true, size >= 22, size <= limits.compressed else { throw Self.invalid("The package exceeds supported transfer limits or is incomplete.") }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let tailSize = Int(min(size, 65557))
        let tail = try Self.read(handle, size - UInt64(tailSize), tailSize)
        guard let range = tail.range(of: Data([0x50, 0x4b, 5, 6]), options: .backwards) else { throw Self.invalid() }
        let e = range.lowerBound
        guard tail.count - e >= 22 else { throw Self.invalid() }
        let num = Self.number
        guard try num(tail, e + 4, 2) == 0, try num(tail, e + 6, 2) == 0,
              try num(tail, e + 8, 2) == num(tail, e + 10, 2),
              try UInt64(e + 22) + num(tail, e + 20, 2) == UInt64(tail.count) else { throw Self.invalid("Split or incomplete ZIP archives are unsupported.") }
        var count = try num(tail, e + 10, 2), length = try num(tail, e + 12, 4), offset = try num(tail, e + 16, 4)
        var end = size - UInt64(tailSize) + UInt64(e)
        if count == 0xffff || length == 0xffffffff || offset == 0xffffffff {
            guard end >= 20 else { throw Self.invalid() }
            let locator = try Self.read(handle, end - 20, 20)
            guard try num(locator, 0, 4) == 0x07064b50, try num(locator, 4, 4) == 0, try num(locator, 16, 4) == 1 else { throw Self.invalid() }
            let largeOffset = try num(locator, 8, 8)
            guard largeOffset <= end - 20, end - 20 - largeOffset == 56 else { throw Self.invalid() }
            let large = try Self.read(handle, largeOffset, 56)
            guard try num(large, 0, 4) == 0x06064b50, try num(large, 4, 8) == 44,
                  try num(large, 16, 4) == 0, try num(large, 20, 4) == 0,
                  try num(large, 24, 8) == num(large, 32, 8) else { throw Self.invalid("Unsupported ZIP64 directory.") }
            count = try num(large, 32, 8); length = try num(large, 40, 8); offset = try num(large, 48, 8); end = largeOffset
        }
        guard count >= 2, count <= UInt64(limits.files), length <= limits.directory, offset <= end, length == end - offset else { throw Self.invalid("The package directory exceeds supported limits or is inconsistent.") }
        let central = try Self.read(handle, offset, Int(length))
        var position = 0, entries = [String: Item](), intervals = [(UInt64, UInt64)](), total: UInt64 = 0
        for _ in 0..<count {
            guard central.count - position >= 46, try num(central, position, 4) == 0x02014b50 else { throw Self.invalid() }
            let flags = try num(central, position + 8, 2), method = try num(central, position + 10, 2)
            var compressed = try num(central, position + 20, 4), bytes = try num(central, position + 24, 4)
            let nameCount = Int(try num(central, position + 28, 2)), extraCount = Int(try num(central, position + 30, 2))
            let comment = Int(try num(central, position + 32, 2)), mode = try num(central, position + 38, 4) >> 16 & 0xf000
            var local = try num(central, position + 42, 4)
            guard central.count - position >= 46 + nameCount + extraCount + comment,
                  flags & ~UInt64(0x080e) == 0, [UInt64(0), 8].contains(method), [UInt64(0), 0x8000].contains(mode),
                  try num(central, position + 34, 2) == 0 else { throw Self.invalid("Encrypted, linked or unsupported entries are not allowed.") }
            let nameData = central.subdata(in: position + 46..<position + 46 + nameCount)
            guard let name = String(data: nameData, encoding: .ascii), Self.allowedName(name), entries[name] == nil else { throw Self.invalid("The package contains duplicate or nonportable entry names.") }
            let extra = central.subdata(in: position + 46 + nameCount..<position + 46 + nameCount + extraCount)
            if bytes == 0xffffffff || compressed == 0xffffffff || local == 0xffffffff {
                var cursor = 0, found = false
                while cursor + 4 <= extra.count {
                    let kind = try num(extra, cursor, 2), amount = Int(try num(extra, cursor + 2, 2))
                    guard cursor + 4 + amount <= extra.count else { throw Self.invalid() }
                    if kind == 1 {
                        var value = cursor + 4
                        let stop = value + amount
                        func next() throws -> UInt64 {
                            guard value + 8 <= stop else { throw Self.invalid() }
                            defer { value += 8 }
                            return try num(extra, value, 8)
                        }
                        if bytes == 0xffffffff { bytes = try next() }
                        if compressed == 0xffffffff { compressed = try next() }
                        if local == 0xffffffff { local = try next() }
                        found = true; break
                    }
                    cursor += 4 + amount
                }
                guard found else { throw Self.invalid("ZIP64 sizes are missing.") }
            }
            let limit = name.hasSuffix(".json") ? limits.metadata : limits.perFile
            guard method != 0 || compressed == bytes else { throw Self.invalid("Stored ZIP sizes disagree.") }
            guard bytes > 0, bytes <= limit, compressed > 0, compressed <= limits.compressed,
                  total <= limits.expanded, bytes <= limits.expanded - total,
                  local <= offset, offset - local >= 30 else { throw Self.invalid("A package entry exceeds supported limits.") }
            total += bytes
            let header = try Self.read(handle, local, 30)
            let crc = UInt32(try num(central, position + 16, 4))
            guard try num(header, 0, 4) == 0x04034b50, try num(header, 6, 2) == flags, try num(header, 8, 2) == method else { throw Self.invalid("ZIP headers disagree.") }
            let localNameCount = Int(try num(header, 26, 2)), localExtraCount = Int(try num(header, 28, 2))
            let dataOffset = local + 30 + UInt64(localNameCount + localExtraCount)
            guard dataOffset <= offset, compressed <= offset - dataOffset,
                  try Self.read(handle, local + 30, localNameCount) == nameData else { throw Self.invalid("ZIP entry names or data boundaries disagree.") }
            if flags & 8 == 0 {
                guard try num(header, 14, 4) == UInt64(crc),
                      try [compressed, 0xffffffff].contains(num(header, 18, 4)),
                      try [bytes, 0xffffffff].contains(num(header, 22, 4)) else { throw Self.invalid("ZIP entry sizes disagree.") }
            }
            intervals.append((local, dataOffset + compressed))
            entries[name] = Item(name: name, bytes: bytes, compressed: compressed, crc: crc, offset: dataOffset, method: method)
            position += 46 + nameCount + extraCount + comment
        }
        guard position == central.count, entries["project.json"] != nil, entries["manifest.json"] != nil else { throw Self.invalid("Package metadata is missing.") }
        intervals.sort { $0.0 < $1.0 }
        for index in 1..<intervals.count { guard intervals[index - 1].1 <= intervals[index].0 else { throw Self.invalid("ZIP entries overlap.") } }
        self.items = entries
        self.archive = try Archive(url: url, accessMode: .read)
        // ZIPFoundation intentionally omits encrypted entries from iteration.
        // The checked raw count ensures omission can never look like success.
        let decoded = Array(archive)
        guard decoded.count == entries.count, decoded.allSatisfy({ entry in
            guard let item = entries[entry.path] else { return false }
            return entry.type == .file && entry.uncompressedSize == item.bytes && entry.compressedSize == item.compressed && entry.checksum == item.crc
        }) else { throw Self.invalid("The ZIP decoder and directory disagree.") }
    }
    func stream(_ name: String, cancellation: BJJJobCancellation, consume: (Data) throws -> Void) throws -> String {
        guard let item = items[name] else { throw Self.invalid("A required package entry is missing.") }
        var actual: UInt64 = 0, hash = SHA256()
        var crc: UInt32 = 0
        func accept(_ data: Data) throws {
            try cancellation.check()
            guard UInt64(data.count) <= item.bytes - actual, UInt64(data.count) <= limits.expanded - expanded else { throw Self.invalid("Actual ZIP expansion exceeded its declared or configured limit.") }
            actual += UInt64(data.count); expanded += UInt64(data.count)
            hash.update(data: data)
            crc = data.crc32(checksum: crc)
            try consume(data)
        }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        try handle.seek(toOffset: item.offset)
        let capacity = 1024 * 1024
        var read: UInt64 = 0
        if item.method == 0 {
            while read < item.compressed {
                try cancellation.check()
                let data = try handle.read(upToCount: Int(min(UInt64(capacity), item.compressed - read))) ?? Data()
                guard !data.isEmpty else { throw Self.invalid("The package transfer is incomplete.") }
                read += UInt64(data.count); try accept(data)
            }
        } else {
            // ZIPFoundation writes portable archives; Apple's streaming decoder
            // additionally exposes unconsumed input so trailing deflate bytes
            // cannot be accepted differently from the desktop reader.
            let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            defer { destination.deallocate() }
            var stream = compression_stream(dst_ptr: destination, dst_size: capacity,
                                            src_ptr: UnsafePointer(destination), src_size: 0, state: nil)
            guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) != COMPRESSION_STATUS_ERROR else { throw Self.invalid() }
            defer { compression_stream_destroy(&stream) }
            var input = Data(), finished = false
            stream.src_size = 0
            while !finished {
                try cancellation.check()
                if stream.src_size == 0, read < item.compressed {
                    input = try handle.read(upToCount: Int(min(UInt64(capacity), item.compressed - read))) ?? Data()
                    guard !input.isEmpty else { throw Self.invalid("The package transfer is incomplete.") }
                    read += UInt64(input.count); stream.src_size = input.count
                }
                let before = stream.src_size
                stream.dst_ptr = destination; stream.dst_size = capacity
                let status = input.withUnsafeBytes { bytes -> compression_status in
                    guard let pointer = bytes.bindMemory(to: UInt8.self).baseAddress else { return COMPRESSION_STATUS_ERROR }
                    stream.src_ptr = pointer.advanced(by: input.count - stream.src_size)
                    return compression_stream_process(&stream, read == item.compressed ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
                }
                guard status != COMPRESSION_STATUS_ERROR else { throw Self.invalid("The compressed package data is damaged.") }
                let produced = capacity - stream.dst_size
                try accept(Data(bytes: destination, count: produced))
                if status == COMPRESSION_STATUS_END {
                    guard read == item.compressed, stream.src_size == 0 else { throw Self.invalid("The package contains trailing compressed data.") }
                    finished = true
                } else if before == stream.src_size && produced == 0 {
                    throw Self.invalid("The compressed package data is incomplete.")
                }
            }
        }
        guard actual == item.bytes, crc == item.crc else { throw Self.invalid("A package entry failed its size or checksum check.") }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    func metadata(_ name: String, cancellation: BJJJobCancellation) throws -> (Data, String) {
        guard name == "manifest.json" || name == "project.json" else { throw Self.invalid() }
        var data = Data()
        let digest = try stream(name, cancellation: cancellation) { data.append($0) }
        return (data, digest)
    }
}
