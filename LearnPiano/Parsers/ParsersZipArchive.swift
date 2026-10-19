import Foundation
import Compression

/// Errors raised by `ParsersZipArchive`.
enum ParsersZipError: Error, LocalizedError, Hashable {
    case notAZip
    case truncated(String)
    case unsupportedMethod(UInt16, entry: String)
    case inflateFailed(entry: String)
    case checksumMismatch(entry: String)
    case entryNotFound(String)

    var errorDescription: String? {
        switch self {
        case .notAZip: return "The data is not a ZIP archive."
        case .truncated(let what): return "The ZIP archive is truncated (\(what))."
        case .unsupportedMethod(let m, let e): return "Entry \(e) uses unsupported compression method \(m)."
        case .inflateFailed(let e): return "Entry \(e) could not be decompressed."
        case .checksumMismatch(let e): return "Entry \(e) failed its CRC-32 check."
        case .entryNotFound(let e): return "The archive has no entry named \(e)."
        }
    }
}

/// A minimal read-only ZIP reader: enough for `.mxl` (compressed MusicXML) files.
///
/// It reads the central directory when present (reliable sizes even for entries written with a data descriptor)
/// and falls back to walking the local file headers otherwise. Stored (0) and deflate (8) entries are supported;
/// deflate is inflated with the Compression framework (`COMPRESSION_ZLIB` = raw deflate).
struct ParsersZipArchive {
    /// One file inside the archive.
    struct Entry: Hashable {
        var name: String
        var method: UInt16
        var compressedSize: Int
        var uncompressedSize: Int
        var crc32: UInt32
        /// Offset of the local file header.
        var localHeaderOffset: Int
        /// Whether the sizes above are trustworthy (false for local-header fallback entries written with a data descriptor).
        var sizesKnown: Bool
    }

    private let bytes: [UInt8]
    /// Entries in directory order.
    let entries: [Entry]

    private static let localHeaderSignature: UInt32 = 0x0403_4b50
    private static let centralHeaderSignature: UInt32 = 0x0201_4b50
    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4b50

    /// Parses the archive structure (no entry data is decompressed yet).
    init(data: Data) throws {
        bytes = [UInt8](data)
        guard bytes.count >= 22, ParsersZipArchive.isZip(bytes: bytes) else { throw ParsersZipError.notAZip }
        if let central = try ParsersZipArchive.readCentralDirectory(bytes) {
            entries = central
        } else {
            entries = try ParsersZipArchive.walkLocalHeaders(bytes)
        }
    }

    /// Quick signature test for "PK\u{03}\u{04}" (first local header) or an empty archive.
    static func isZip(data: Data) -> Bool { isZip(bytes: [UInt8](data.prefix(4))) }

    private static func isZip(bytes: [UInt8]) -> Bool {
        guard bytes.count >= 4 else { return false }
        let sig = le32(bytes, 0)
        return sig == localHeaderSignature || sig == endOfCentralDirectorySignature
    }

    /// Finds an entry by exact name (ZIP names use forward slashes).
    func entry(named name: String) -> Entry? {
        entries.first { $0.name == name } ?? entries.first { $0.name.lowercased() == name.lowercased() }
    }

    /// Decompressed contents of an entry.
    func contents(of entry: Entry) throws -> Data {
        let off = entry.localHeaderOffset
        guard off + 30 <= bytes.count, ParsersZipArchive.le32(bytes, off) == ParsersZipArchive.localHeaderSignature else {
            throw ParsersZipError.truncated("local header of \(entry.name)")
        }
        let nameLen = Int(ParsersZipArchive.le16(bytes, off + 26))
        let extraLen = Int(ParsersZipArchive.le16(bytes, off + 28))
        let dataStart = off + 30 + nameLen + extraLen
        guard dataStart <= bytes.count else { throw ParsersZipError.truncated("entry data of \(entry.name)") }
        let available = bytes.count - dataStart
        let compressedLength = entry.sizesKnown ? min(entry.compressedSize, available) : available
        let slice = Array(bytes[dataStart ..< dataStart + compressedLength])
        let out: [UInt8]
        switch entry.method {
        case 0:
            out = entry.sizesKnown ? Array(slice.prefix(entry.uncompressedSize)) : slice
        case 8:
            out = try ParsersZipArchive.inflate(slice, expectedSize: entry.sizesKnown ? entry.uncompressedSize : nil, entryName: entry.name)
        default:
            throw ParsersZipError.unsupportedMethod(entry.method, entry: entry.name)
        }
        if entry.sizesKnown, entry.crc32 != 0, ParsersZipArchive.crc32(out) != entry.crc32 {
            throw ParsersZipError.checksumMismatch(entry: entry.name)
        }
        return Data(out)
    }

    /// Decompressed contents of the entry with this name.
    func contents(named name: String) throws -> Data {
        guard let e = entry(named: name) else { throw ParsersZipError.entryNotFound(name) }
        return try contents(of: e)
    }

    // MARK: Structure parsing

    private static func readCentralDirectory(_ b: [UInt8]) throws -> [Entry]? {
        // The EOCD record is at least 22 bytes and may be followed by a comment of up to 65535 bytes.
        let minPos = max(0, b.count - 22 - 65535)
        var pos = b.count - 22
        var eocd: Int? = nil
        while pos >= minPos {
            if le32(b, pos) == endOfCentralDirectorySignature { eocd = pos; break }
            pos -= 1
        }
        guard let e = eocd else { return nil }
        let count = Int(le16(b, e + 10))
        let cdSize = Int(le32(b, e + 12))
        let cdOffset = Int(le32(b, e + 16))
        guard cdOffset + cdSize <= b.count, cdOffset >= 0 else { throw ParsersZipError.truncated("central directory") }
        var entries: [Entry] = []
        var p = cdOffset
        for _ in 0..<count {
            guard p + 46 <= b.count, le32(b, p) == centralHeaderSignature else { throw ParsersZipError.truncated("central directory entry") }
            let method = le16(b, p + 10)
            let crc = le32(b, p + 16)
            let csize = Int(le32(b, p + 20))
            let usize = Int(le32(b, p + 24))
            let nameLen = Int(le16(b, p + 28))
            let extraLen = Int(le16(b, p + 30))
            let commentLen = Int(le16(b, p + 32))
            let localOffset = Int(le32(b, p + 42))
            guard p + 46 + nameLen <= b.count else { throw ParsersZipError.truncated("central directory name") }
            let name = String(decoding: b[(p + 46) ..< (p + 46 + nameLen)], as: UTF8.self)
            entries.append(Entry(name: name, method: method, compressedSize: csize, uncompressedSize: usize, crc32: crc, localHeaderOffset: localOffset, sizesKnown: true))
            p += 46 + nameLen + extraLen + commentLen
        }
        return entries
    }

    private static func walkLocalHeaders(_ b: [UInt8]) throws -> [Entry] {
        var entries: [Entry] = []
        var p = 0
        while p + 30 <= b.count, le32(b, p) == localHeaderSignature {
            let flags = le16(b, p + 6)
            let method = le16(b, p + 8)
            let crc = le32(b, p + 14)
            let csize = Int(le32(b, p + 18))
            let usize = Int(le32(b, p + 22))
            let nameLen = Int(le16(b, p + 26))
            let extraLen = Int(le16(b, p + 28))
            guard p + 30 + nameLen <= b.count else { throw ParsersZipError.truncated("local header name") }
            let name = String(decoding: b[(p + 30) ..< (p + 30 + nameLen)], as: UTF8.self)
            let hasDescriptor = flags & 0x0008 != 0
            entries.append(Entry(name: name, method: method, compressedSize: csize, uncompressedSize: usize, crc32: crc, localHeaderOffset: p, sizesKnown: !hasDescriptor))
            if hasDescriptor {
                // Without the central directory we cannot know where this entry ends; stop walking here.
                break
            }
            p += 30 + nameLen + extraLen + csize
        }
        guard !entries.isEmpty else { throw ParsersZipError.truncated("no entries") }
        return entries
    }

    // MARK: Inflate

    /// Inflates raw deflate data with the Compression framework's streaming API (so that the output size need not be known).
    static func inflate(_ input: [UInt8], expectedSize: Int?, entryName: String) throws -> [UInt8] {
        guard !input.isEmpty else { return [] }
        let streamPointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPointer.deallocate() }
        guard compression_stream_init(streamPointer, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw ParsersZipError.inflateFailed(entry: entryName)
        }
        defer { compression_stream_destroy(streamPointer) }

        var output: [UInt8] = []
        output.reserveCapacity(expectedSize ?? input.count * 4)
        let chunkSize = max(64 * 1024, expectedSize ?? 0)
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        var finished = false
        var lastRemaining = -1
        try input.withUnsafeBufferPointer { src in
            guard let srcBase = src.baseAddress else { return }
            streamPointer.pointee.src_ptr = srcBase
            streamPointer.pointee.src_size = src.count
            while !finished {
                let status: compression_status = chunk.withUnsafeMutableBufferPointer { dst in
                    guard let dstBase = dst.baseAddress else { return COMPRESSION_STATUS_ERROR }
                    streamPointer.pointee.dst_ptr = dstBase
                    streamPointer.pointee.dst_size = dst.count
                    return compression_stream_process(streamPointer, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                }
                let produced = chunkSize - streamPointer.pointee.dst_size
                if produced > 0 { output.append(contentsOf: chunk[0..<produced]) }
                switch status {
                case COMPRESSION_STATUS_OK:
                    // No progress at all means the stream is truncated or corrupt; stop instead of spinning.
                    if produced == 0 {
                        let remaining = streamPointer.pointee.src_size
                        if remaining == 0 { finished = true } else if remaining == lastRemaining { throw ParsersZipError.inflateFailed(entry: entryName) }
                        lastRemaining = remaining
                    }
                case COMPRESSION_STATUS_END:
                    finished = true
                default:
                    throw ParsersZipError.inflateFailed(entry: entryName)
                }
            }
        }
        if let expected = expectedSize, output.count != expected {
            throw ParsersZipError.inflateFailed(entry: entryName)
        }
        return output
    }

    // MARK: Little-endian readers and CRC

    private static func le16(_ b: [UInt8], _ i: Int) -> UInt16 {
        guard i + 1 < b.count else { return 0 }
        return UInt16(b[i]) | UInt16(b[i + 1]) << 8
    }

    private static func le32(_ b: [UInt8], _ i: Int) -> UInt32 {
        guard i + 3 < b.count else { return 0 }
        return UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    /// Standard CRC-32 (IEEE) as used by ZIP.
    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in bytes { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    // MARK: Writing (used by tests and the harness to build archives in memory)

    /// Builds a ZIP archive in memory. Each entry is stored or deflated according to `deflate`.
    /// Deflate uses the Compression framework's raw-deflate encoder.
    static func build(entries: [(name: String, data: Data)], deflate: Bool) -> Data {
        var out: [UInt8] = []
        var central: [UInt8] = []
        func put16(_ v: Int, into a: inout [UInt8]) { a.append(UInt8(v & 0xFF)); a.append(UInt8((v >> 8) & 0xFF)) }
        func put32(_ v: UInt32, into a: inout [UInt8]) { for s in stride(from: 0, to: 32, by: 8) { a.append(UInt8((v >> UInt32(s)) & 0xFF)) } }
        for (name, data) in entries {
            let raw = [UInt8](data)
            var payload = raw
            var method = 0
            if deflate, !raw.isEmpty {
                let cap = raw.count + 1024
                var dst = [UInt8](repeating: 0, count: cap)
                let n = raw.withUnsafeBufferPointer { src -> Int in
                    dst.withUnsafeMutableBufferPointer { d -> Int in
                        guard let s = src.baseAddress, let dd = d.baseAddress else { return 0 }
                        return compression_encode_buffer(dd, cap, s, src.count, nil, COMPRESSION_ZLIB)
                    }
                }
                if n > 0 { payload = Array(dst.prefix(n)); method = 8 }
            }
            let crc = crc32(raw)
            let nameBytes = Array(name.utf8)
            let localOffset = out.count
            put32(localHeaderSignature, into: &out); put16(20, into: &out); put16(0, into: &out); put16(method, into: &out)
            put16(0, into: &out); put16(0, into: &out) // time, date
            put32(crc, into: &out); put32(UInt32(payload.count), into: &out); put32(UInt32(raw.count), into: &out)
            put16(nameBytes.count, into: &out); put16(0, into: &out)
            out += nameBytes
            out += payload
            put32(centralHeaderSignature, into: &central); put16(20, into: &central); put16(20, into: &central); put16(0, into: &central); put16(method, into: &central)
            put16(0, into: &central); put16(0, into: &central)
            put32(crc, into: &central); put32(UInt32(payload.count), into: &central); put32(UInt32(raw.count), into: &central)
            put16(nameBytes.count, into: &central); put16(0, into: &central); put16(0, into: &central)
            put16(0, into: &central); put16(0, into: &central); put32(0, into: &central)
            put32(UInt32(localOffset), into: &central)
            central += nameBytes
        }
        let cdOffset = out.count
        out += central
        put32(endOfCentralDirectorySignature, into: &out); put16(0, into: &out); put16(0, into: &out)
        put16(entries.count, into: &out); put16(entries.count, into: &out)
        put32(UInt32(central.count), into: &out); put32(UInt32(cdOffset), into: &out); put16(0, into: &out)
        return Data(out)
    }
}
