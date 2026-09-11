import Foundation

#if canImport(Compression)
import Compression
#else
import CZlib
#endif

public enum GzipArchive {
    #if canImport(Compression)
    public static func decompress(_ archive: Data) throws -> Data {
        let deflated = archive.subdata(in: try payloadStart(of: archive)..<archive.count)

        let blockSize = 1024 * 1024
        let block = UnsafeMutablePointer<UInt8>.allocate(capacity: blockSize)
        defer { block.deallocate() }

        var stream = compression_stream(dst_ptr: block, dst_size: blockSize, src_ptr: block, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw GzipError.corrupt(reason: "unsupported archive")
        }
        defer { compression_stream_destroy(&stream) }

        var output = Data()
        var failure: String?
        deflated.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            stream.src_ptr = raw.bindMemory(to: UInt8.self).baseAddress!
            stream.src_size = raw.count

            while true {
                stream.dst_ptr = block
                stream.dst_size = blockSize

                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                output.append(block, count: blockSize - stream.dst_size)

                if status == COMPRESSION_STATUS_END {
                    return
                }
                if status == COMPRESSION_STATUS_ERROR {
                    failure = "corrupt archive"
                    return
                }
            }
        }
        if let failure {
            throw GzipError.corrupt(reason: failure)
        }
        return output
    }

    /// The framework inflates a raw deflate stream, so the gzip wrapper around
    /// it -- whichever of its optional fields are present -- is stepped over
    /// first.
    private static func payloadStart(of archive: Data) throws -> Int {
        guard archive.count > 18, archive[0] == 0x1f, archive[1] == 0x8b, archive[2] == 0x08 else {
            throw GzipError.corrupt(reason: "not a gzip archive")
        }

        let flags = archive[3]
        var offset = 10

        if flags & 0x04 != 0 {
            let extraLength = Int(archive[offset]) | (Int(archive[offset + 1]) << 8)
            offset += 2 + extraLength
        }
        for field in [0x08, 0x10] where flags & UInt8(field) != 0 {
            while offset < archive.count, archive[offset] != 0 {
                offset += 1
            }
            offset += 1
        }
        if flags & 0x02 != 0 {
            offset += 2
        }

        guard offset < archive.count else {
            throw GzipError.corrupt(reason: "gzip archive ends in its header")
        }
        return offset
    }
    #else
    public static func decompress(_ archive: Data) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw GzipError.corrupt(reason: "unsupported archive")
        }
        defer { inflateEnd(&stream) }

        let blockSize = 1024 * 1024
        let block = UnsafeMutablePointer<UInt8>.allocate(capacity: blockSize)
        defer { block.deallocate() }

        var output = Data()
        var failure: String?
        archive.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: UInt8.self).baseAddress!)
            stream.avail_in = uInt(raw.count)

            while true {
                stream.next_out = block
                stream.avail_out = uInt(blockSize)

                let status = inflate(&stream, Z_NO_FLUSH)
                output.append(block, count: blockSize - Int(stream.avail_out))

                if status == Z_STREAM_END {
                    return
                }
                if status != Z_OK {
                    failure = "corrupt archive"
                    return
                }
            }
        }
        if let failure {
            throw GzipError.corrupt(reason: failure)
        }
        return output
    }
    #endif
}

public enum GzipError: Swift.Error, LocalizedError {
    case corrupt(reason: String)

    public var errorDescription: String? {
        switch self {
        case .corrupt(let reason):
            return "Unable to unpack the archive: \(reason)"
        }
    }
}
