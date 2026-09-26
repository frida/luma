import Foundation
import NIOCore
import NIOHPACK
import NIOHTTP2
import NIOPosix
import SwiftProtobuf

public struct GRPCCallError: Error, CustomStringConvertible, Sendable {
    public let code: Int
    public let message: String
    public let path: String

    public var description: String {
        message.isEmpty ? "\(path) failed with gRPC status \(code)" : "\(path) failed: \(message) (\(code))"
    }
}

final class GRPCConnection: Sendable {
    typealias CallStream = NIOAsyncChannel<HTTP2Frame.FramePayload, HTTP2Frame.FramePayload>

    private static let windowSize = 8 * 1024 * 1024

    private let group: MultiThreadedEventLoopGroup
    private let multiplexer: NIOHTTP2Handler.AsyncStreamMultiplexer<CallStream>
    private let authority: String
    private let callHeaders: [(name: String, value: String)]

    init(host: String, port: Int, headers: [(name: String, value: String)] = []) async throws {
        authority = "\(host):\(port)"
        callHeaders = headers
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        let configuration = Self.makeHTTP2Configuration()

        do {
            multiplexer = try await ClientBootstrap(group: group)
                .channelOption(.socketOption(.tcp_nodelay), value: 1)
                .connect(host: host, port: port) { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.configureAsyncHTTP2Pipeline(
                            mode: .client,
                            configuration: configuration
                        ) { stream in
                            stream.eventLoop.makeCompletedFuture {
                                try CallStream(wrappingChannelSynchronously: stream)
                            }
                        }
                    }
                }
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    func close() async {
        try? await group.shutdownGracefully()
    }

    func unary<Request: Message, Response: Message>(_ path: String, _ request: Request) async throws -> Response {
        var received: Response?
        try await call(path, request) { (message: Response) in
            if received == nil { received = message }
        }
        guard let received else {
            throw GRPCCallError(code: -1, message: "the peer closed the call without a response", path: path)
        }
        return received
    }

    func serverStream<Request: Message, Response: Message>(
        _ path: String,
        _ request: Request,
        of: Response.Type = Response.self
    ) -> AsyncThrowingStream<Response, any Error> {
        AsyncThrowingStream { continuation in
            let pump = Task {
                do {
                    try await call(path, request) { (message: Response) in
                        continuation.yield(message)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in pump.cancel() }
        }
    }

    private func call<Request: Message, Response: Message>(
        _ path: String,
        _ request: Request,
        onMessage: (Response) async throws -> Void
    ) async throws {
        let stream = try await multiplexer.openStream { channel in
            channel.eventLoop.makeCompletedFuture {
                try CallStream(wrappingChannelSynchronously: channel)
            }
        }

        try await stream.executeThenClose { inbound, outbound in
            var requestHeaders = HPACKHeaders([
                (":method", "POST"),
                (":scheme", "http"),
                (":path", path),
                (":authority", authority),
                ("content-type", "application/grpc+proto"),
                ("te", "trailers"),
                ("user-agent", "luma-grpc/1"),
            ])
            for header in callHeaders {
                requestHeaders.add(name: header.name, value: header.value)
            }
            try await outbound.write(.headers(.init(headers: requestHeaders)))
            try await outbound.write(.data(.init(data: .byteBuffer(Self.frame(request)), endStream: true)))

            var pending = ByteBuffer()
            var status: GRPCCallError?
            var sawResponseHeaders = false

            for try await payload in inbound {
                switch payload {
                case .headers(let frame):
                    if sawResponseHeaders || frame.headers.first(name: "grpc-status") != nil {
                        status = Self.status(from: frame.headers, path: path)
                    } else {
                        sawResponseHeaders = true
                        if let code = frame.headers.first(name: ":status"), code != "200" {
                            throw GRPCCallError(code: -1, message: "the peer answered HTTP \(code)", path: path)
                        }
                    }
                case .data(let frame):
                    guard case .byteBuffer(var chunk) = frame.data else { break }
                    pending.writeBuffer(&chunk)
                    while let message: Response = try Self.nextMessage(from: &pending, path: path) {
                        try await onMessage(message)
                    }
                case .rstStream(let code):
                    throw GRPCCallError(code: -1, message: "the peer reset the stream (\(code))", path: path)
                default:
                    break
                }
            }

            if let status { throw status }
        }
    }

    private static func makeHTTP2Configuration() -> NIOHTTP2Handler.Configuration {
        var configuration = NIOHTTP2Handler.Configuration()
        configuration.connection.targetWindowSize = windowSize
        configuration.stream.targetWindowSize = windowSize
        configuration.connection.initialSettings = [
            HTTP2Setting(parameter: .initialWindowSize, value: windowSize),
            HTTP2Setting(parameter: .maxFrameSize, value: 1 << 20),
            HTTP2Setting(parameter: .maxConcurrentStreams, value: 100),
            HTTP2Setting(parameter: .enablePush, value: 0),
        ]
        return configuration
    }

    private static func frame(_ message: some Message) -> ByteBuffer {
        let bytes: [UInt8] = (try? message.serializedBytes()) ?? []
        var buffer = ByteBuffer()
        buffer.reserveCapacity(bytes.count + 5)
        buffer.writeInteger(UInt8(0))
        buffer.writeInteger(UInt32(bytes.count))
        buffer.writeBytes(bytes)
        return buffer
    }

    private static func nextMessage<M: Message>(from buffer: inout ByteBuffer, path: String) throws -> M? {
        guard let compressed: UInt8 = buffer.getInteger(at: buffer.readerIndex),
            let length: UInt32 = buffer.getInteger(at: buffer.readerIndex + 1),
            buffer.readableBytes >= 5 + Int(length)
        else { return nil }
        guard compressed == 0 else {
            throw GRPCCallError(code: -1, message: "the peer compressed a message, which we do not accept", path: path)
        }
        buffer.moveReaderIndex(forwardBy: 5)
        let bytes = buffer.readBytes(length: Int(length)) ?? []
        buffer.discardReadBytes()
        return try M(serializedBytes: bytes)
    }

    private static func status(from headers: HPACKHeaders, path: String) -> GRPCCallError? {
        let code = headers.first(name: "grpc-status").flatMap { Int($0) } ?? 0
        guard code != 0 else { return nil }
        let message = headers.first(name: "grpc-message").map(percentDecoded) ?? ""
        return GRPCCallError(code: code, message: message, path: path)
    }

    private static func percentDecoded(_ value: String) -> String {
        value.removingPercentEncoding ?? value
    }
}
