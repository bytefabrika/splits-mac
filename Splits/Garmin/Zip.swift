import Compression
import Foundation

/// Just enough ZIP to unpack Garmin's activity download (one FIT file, stored or deflated).
/// Uses the central directory, so sizes are right even when the local headers leave them out.
enum Zip {
    struct Entry { let name: String; let data: Data }

    enum Failure: Error { case notZip, unsupported(Int), corrupt }

    static func entries(_ zip: Data) throws -> [Entry] {
        let bytes = [UInt8](zip)
        func u16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }

        // End of central directory record: the last "PK\u{5}\u{6}" in the file.
        guard bytes.count >= 22 else { throw Failure.notZip }
        var end = -1
        var i = bytes.count - 22
        while i >= max(0, bytes.count - 65_557) {
            if bytes[i] == 0x50, bytes[i + 1] == 0x4B, bytes[i + 2] == 0x05, bytes[i + 3] == 0x06 { end = i; break }
            i -= 1
        }
        guard end >= 0 else { throw Failure.notZip }

        var entries: [Entry] = []
        var p = u32(end + 16)
        for _ in 0..<u16(end + 10) {
            guard p + 46 <= bytes.count, u32(p) == 0x0201_4B50 else { throw Failure.corrupt }
            let method = u16(p + 10)
            let compressed = u32(p + 20), size = u32(p + 24)
            let nameLength = u16(p + 28), extra = u16(p + 30), comment = u16(p + 32)
            let local = u32(p + 42)
            let name = String(decoding: bytes[(p + 46)..<(p + 46 + nameLength)], as: UTF8.self)
            p += 46 + nameLength + extra + comment

            guard local + 30 <= bytes.count, u32(local) == 0x0403_4B50 else { throw Failure.corrupt }
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            guard start + compressed <= bytes.count else { throw Failure.corrupt }
            let raw = Data(bytes[start..<(start + compressed)])
            switch method {
            case 0: entries.append(Entry(name: name, data: raw))
            case 8: entries.append(Entry(name: name, data: try inflate(raw, size: size)))
            default: throw Failure.unsupported(method)
            }
        }
        return entries
    }

    /// Raw DEFLATE, which is what Apple's COMPRESSION_ZLIB decodes.
    private static func inflate(_ data: Data, size: Int) throws -> Data {
        guard size > 0, !data.isEmpty else { return Data() }
        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                compression_decode_buffer(out.bindMemory(to: UInt8.self).baseAddress!, size,
                                          input.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw Failure.corrupt }
        return output
    }
}
