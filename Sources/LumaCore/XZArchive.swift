import Foundation

#if canImport(Compression)
import Compression
#endif

public enum XZArchive {
    public static func decompress(_ archive: Data, to destination: URL) throws {
        try decompress(archive).write(to: destination)
    }

    #if canImport(Compression)
    public static func decompress(_ archive: Data) throws -> Data {
        let blockSize = 256 * 1024
        let block = UnsafeMutablePointer<UInt8>.allocate(capacity: blockSize)
        defer { block.deallocate() }

        var stream = compression_stream(dst_ptr: block, dst_size: blockSize, src_ptr: block, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZMA) == COMPRESSION_STATUS_OK else {
            throw BareboneAgentError.decompressionFailed(reason: "unsupported archive")
        }
        defer { compression_stream_destroy(&stream) }

        var output = Data()
        var failure: String?
        archive.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
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
            throw BareboneAgentError.decompressionFailed(reason: failure)
        }
        return output
    }
    #else
    public static func decompress(_ archive: Data) throws -> Data {
        let xz = Process()
        xz.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        xz.arguments = ["xz", "--decompress", "--stdout"]

        let input = Pipe()
        let output = Pipe()
        xz.standardInput = input
        xz.standardOutput = output
        try xz.run()

        try input.fileHandleForWriting.write(contentsOf: archive)
        try input.fileHandleForWriting.close()

        let plain = try output.fileHandleForReading.readToEnd() ?? Data()
        xz.waitUntilExit()
        guard xz.terminationStatus == 0 else {
            throw BareboneAgentError.decompressionFailed(reason: "xz exited with \(xz.terminationStatus)")
        }
        return plain
    }
    #endif
}
