import Foundation

#if canImport(Compression)
import Compression
#else
import CLzma
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
    private static let concatenatedStreams: UInt32 = 0x08

    public static func decompress(_ archive: Data) throws -> Data {
        var stream = lzma_stream()
        guard lzma_stream_decoder(&stream, UInt64.max, concatenatedStreams) == LZMA_OK else {
            throw BareboneAgentError.decompressionFailed(reason: "unsupported archive")
        }
        defer { lzma_end(&stream) }

        let blockSize = 256 * 1024
        let block = UnsafeMutablePointer<UInt8>.allocate(capacity: blockSize)
        defer { block.deallocate() }

        var output = Data()
        var failure: String?
        archive.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            stream.next_in = raw.bindMemory(to: UInt8.self).baseAddress!
            stream.avail_in = raw.count

            while true {
                stream.next_out = block
                stream.avail_out = blockSize

                let status = lzma_code(&stream, LZMA_FINISH)
                output.append(block, count: blockSize - stream.avail_out)

                if status == LZMA_STREAM_END {
                    return
                }
                if status != LZMA_OK {
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
    #endif
}
