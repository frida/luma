import CZstd
import Foundation

/// Virtualization.framework boots a bare arm64 kernel and nothing else, while
/// distributions ship theirs wrapped: gzipped, packed into an EFI image that
/// unpacks itself, or bundled with its device trees into a unified image. This
/// unwraps whichever arrived.
public enum LinuxKernelImage {
    public static func raw(from packed: Data) throws -> Data {
        if isRaw(packed) {
            return packed
        }
        if packed.starts(with: [0x1f, 0x8b]) {
            return try unwrap(GzipArchive.decompress(packed))
        }
        if packed.starts(with: Array("MZ".utf8)) {
            return try unwrap(try fromPortableExecutable(packed))
        }
        throw LinuxKernelError.unrecognised
    }

    /// A kernel carries its own version, and a distribution names the map of
    /// its symbols after it.
    public static func version(of image: Data) -> String? {
        if let version = versionMarker(in: image) {
            return version
        }

        for start in gzipStreams(in: image) {
            guard let payload = try? GzipArchive.decompress(Data(image[start...])) else {
                continue
            }
            if let version = versionMarker(in: payload) {
                return version
            }
        }

        return nil
    }

    public static func names(_ symbol: String, in packed: Data) -> Bool {
        let needle = Data(symbol.utf8)
        let image = (try? raw(from: packed)) ?? packed
        if image.range(of: needle) != nil {
            return true
        }
        for start in gzipStreams(in: image) {
            guard let payload = try? GzipArchive.decompress(Data(image[start...])) else {
                continue
            }
            if payload.range(of: needle) != nil {
                return true
            }
        }
        for start in streams(of: lz4LegacyMagic, in: image) {
            guard let payload = lz4Legacy(from: image[start...]) else { continue }
            if payload.range(of: needle) != nil {
                return true
            }
        }
        return false
    }

    private static let lz4LegacyMagic = Data([0x02, 0x21, 0x4c, 0x18])
    private static let payloadLimit = 256 * 1024 * 1024

    private static func lz4Legacy(from stream: Data) -> Data? {
        var payload = Data()
        var cursor = stream.index(stream.startIndex, offsetBy: lz4LegacyMagic.count)

        while stream.index(cursor, offsetBy: 4, limitedBy: stream.endIndex) != nil {
            let size = Int(read32(stream, at: stream.distance(from: stream.startIndex, to: cursor)))
            cursor = stream.index(cursor, offsetBy: 4)
            guard size > 0, size <= payloadLimit,
                let end = stream.index(cursor, offsetBy: size, limitedBy: stream.endIndex),
                let block = lz4Block(stream[cursor..<end])
            else { break }
            payload.append(block)
            cursor = end
            if payload.count >= payloadLimit { break }
        }
        return payload.isEmpty ? nil : payload
    }

    private static func lz4Block(_ source: Data) -> Data? {
        var output = [UInt8]()
        output.reserveCapacity(source.count * 4)
        let input = [UInt8](source)
        var cursor = 0

        func extend(_ initial: Int) -> Int? {
            var total = initial
            guard initial == 15 else { return total }
            while cursor < input.count {
                let byte = Int(input[cursor])
                cursor += 1
                total += byte
                if byte != 255 { return total }
            }
            return nil
        }

        while cursor < input.count {
            let token = Int(input[cursor])
            cursor += 1

            guard let literals = extend(token >> 4) else { return nil }
            guard cursor + literals <= input.count else { return nil }
            output.append(contentsOf: input[cursor..<cursor + literals])
            cursor += literals

            guard cursor + 2 <= input.count else { break }
            let offset = Int(input[cursor]) | Int(input[cursor + 1]) << 8
            cursor += 2
            guard offset > 0, offset <= output.count else { return nil }

            guard let matched = extend(token & 15) else { return nil }
            var remaining = matched + 4
            var from = output.count - offset
            while remaining > 0 {
                output.append(output[from])
                from += 1
                remaining -= 1
            }
        }
        return Data(output)
    }

    private static func streams(of magic: Data, in image: Data) -> [Data.Index] {
        var offsets: [Data.Index] = []
        var from = image.startIndex
        while let found = image[from...].firstRange(of: magic) {
            offsets.append(found.lowerBound)
            from = image.index(after: found.lowerBound)
        }
        return offsets
    }

    private static func versionMarker(in image: Data) -> String? {
        if let marker = image.firstRange(of: Data("Linux version ".utf8)) {
            return word(in: image[marker.upperBound...].prefix(128))
        }
        return setupHeaderVersion(of: image)
    }

    /// A self-extracting kernel keeps its banner inside a compressed payload the
    /// outer image never spells out, so each embedded gzip stream is inflated
    /// and searched in turn.
    private static func gzipStreams(in image: Data) -> [Data.Index] {
        let magic = Data([0x1f, 0x8b, 0x08])
        var offsets: [Data.Index] = []
        var from = image.startIndex
        while let found = image[from...].firstRange(of: magic) {
            offsets.append(found.lowerBound)
            from = image.index(after: found.lowerBound)
        }
        return offsets
    }

    private static func setupHeaderVersion(of image: Data) -> String? {
        let base = image.startIndex
        guard image.count > 0x210 else { return nil }
        guard image[base.advanced(by: 0x202)..<base.advanced(by: 0x206)] == Data("HdrS".utf8) else { return nil }

        let start = base.advanced(by: 0x200 + Int(read16(image, at: 0x20e)))
        guard start < image.endIndex else { return nil }
        return word(in: image[start...].prefix(128))
    }

    private static func word(in text: Data) -> String? {
        let word = String(decoding: text.prefix { $0 > 0x20 }, as: UTF8.self)
        return word.isEmpty ? nil : word
    }

    private static func unwrap(_ image: Data) throws -> Data {
        guard !isRaw(image) else { return image }
        return try raw(from: image)
    }

    /// A unified image carries the kernel in a section of its own, alongside
    /// the device trees and the rest; a self-extracting one carries a
    /// compressed kernel and the code to unpack it.
    private static func fromPortableExecutable(_ image: Data) throws -> Data {
        if let kernel = section(named: ".linux", of: image) {
            return kernel
        }
        return try fromSelfExtractingImage(image)
    }

    private static func fromSelfExtractingImage(_ image: Data) throws -> Data {
        guard let header = image.firstRange(of: Data("zimg".utf8)), header.lowerBound < 64 else {
            throw LinuxKernelError.unrecognised
        }

        let offset = Int(read32(image, at: header.upperBound))
        let size = Int(read32(image, at: header.upperBound + 4))

        guard offset > 0, size > 0, offset + size <= image.count else {
            throw LinuxKernelError.unrecognised
        }
        let payload = image.subdata(in: offset..<(offset + size))

        // The header names the compression, but not every kernel fills that in,
        // whereas the payload always says what it is.
        if payload.starts(with: [0x28, 0xb5, 0x2f, 0xfd]) {
            return try ZstdArchive.decompress(payload)
        }
        if payload.starts(with: [0x1f, 0x8b]) {
            return try GzipArchive.decompress(payload)
        }
        throw LinuxKernelError.unsupportedCompression(text(in: image, at: header.upperBound + 16, length: 32))
    }

    private static func section(named name: String, of image: Data) -> Data? {
        let peOffset = Int(read32(image, at: 0x3c))
        guard peOffset + 24 < image.count, text(in: image, at: peOffset, length: 2) == "PE" else { return nil }

        let sectionCount = Int(read16(image, at: peOffset + 6))
        let optionalHeaderSize = Int(read16(image, at: peOffset + 20))
        let table = peOffset + 24 + optionalHeaderSize

        for index in 0..<sectionCount {
            let entry = table + index * 40
            guard entry + 40 <= image.count else { return nil }
            guard text(in: image, at: entry, length: 8) == name else { continue }

            let size = Int(read32(image, at: entry + 16))
            let offset = Int(read32(image, at: entry + 20))
            guard offset + size <= image.count else { return nil }
            return image.subdata(in: offset..<(offset + size))
        }
        return nil
    }

    /// An arm64 kernel says what it is 56 bytes in.
    private static func isRaw(_ image: Data) -> Bool {
        guard image.count > 0x3c else { return false }
        return image[image.startIndex.advanced(by: 0x38)..<image.startIndex.advanced(by: 0x3c)] == Data("ARM\u{64}".utf8)
    }

    private static func read32(_ data: Data, at offset: Int) -> UInt32 {
        let start = data.startIndex.advanced(by: offset)
        guard start + 4 <= data.endIndex else { return 0 }
        return data[start..<start + 4].reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func read16(_ data: Data, at offset: Int) -> UInt16 {
        let start = data.startIndex.advanced(by: offset)
        guard start + 2 <= data.endIndex else { return 0 }
        return UInt16(data[start]) | (UInt16(data[start + 1]) << 8)
    }

    private static func text(in data: Data, at offset: Int, length: Int) -> String {
        let start = data.startIndex.advanced(by: offset)
        guard start + length <= data.endIndex else { return "" }
        let bytes = data[start..<start + length].prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }
}

enum ZstdArchive {
    static func decompress(_ archive: Data) throws -> Data {
        guard let stream = ZSTD_createDStream() else { throw LinuxKernelError.corruptPayload }
        defer { ZSTD_freeDStream(stream) }
        ZSTD_initDStream(stream)

        let blockSize = ZSTD_DStreamOutSize()
        var block = [UInt8](repeating: 0, count: blockSize)
        var plain = Data()

        try archive.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            var input = ZSTD_inBuffer(src: source.baseAddress, size: source.count, pos: 0)

            while input.pos < input.size {
                let status: size_t = block.withUnsafeMutableBytes { destination in
                    var output = ZSTD_outBuffer(dst: destination.baseAddress, size: destination.count, pos: 0)
                    let status = ZSTD_decompressStream(stream, &output, &input)
                    plain.append(contentsOf: destination.prefix(output.pos))
                    return status
                }
                guard ZSTD_isError(status) == 0 else {
                    throw LinuxKernelError.corruptPayload
                }
            }
        }
        return plain
    }
}

public enum LinuxKernelError: Swift.Error, LocalizedError {
    case unrecognised
    case unsupportedCompression(String)
    case corruptPayload

    public var errorDescription: String? {
        switch self {
        case .unrecognised:
            return "This does not look like an arm64 Linux kernel"
        case .unsupportedCompression(let kind):
            return "The kernel is packed with \(kind), which cannot be unpacked here"
        case .corruptPayload:
            return "The kernel's compressed payload is unreadable"
        }
    }
}
