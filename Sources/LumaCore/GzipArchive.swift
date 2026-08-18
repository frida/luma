import Foundation

#if canImport(Compression)
import Compression
#endif

public enum GzipArchive {
    public static func decompress(_ archive: URL, to destination: URL) throws {
        try? FileManager.default.removeItem(at: destination)
        try decompress(Data(contentsOf: archive, options: .mappedIfSafe)).write(to: destination)
    }

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
        let gzip = Process()
        gzip.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        gzip.arguments = ["gzip", "--decompress", "--stdout"]

        let input = Pipe()
        let output = Pipe()
        gzip.standardInput = input
        gzip.standardOutput = output
        try gzip.run()

        try input.fileHandleForWriting.write(contentsOf: archive)
        try input.fileHandleForWriting.close()

        let plain = try output.fileHandleForReading.readToEnd() ?? Data()
        gzip.waitUntilExit()
        guard gzip.terminationStatus == 0 else {
            throw GzipError.corrupt(reason: "gzip exited with \(gzip.terminationStatus)")
        }
        return plain
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
