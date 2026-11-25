import Foundation

@MainActor
final class RemoteStreamReceiver {
    typealias Stanza = [String: Any]

    var onStream: ((IncomingRemoteStream) -> Void)?

    private let send: (Stanza) -> Void
    private var streams: [Int: IncomingRemoteStream] = [:]

    init(send: @escaping (Stanza) -> Void) {
        self.send = send
    }

    func receive(_ stanza: Stanza, data: Data?) {
        guard let id = stanza["id"] as? Int, let name = stanza["name"] as? String else { return }
        guard let endpoint = (stanza["payload"] as? Stanza)?["endpoint"] as? Stanza, let endpointID = endpoint["id"] as? Int else {
            return reply(to: id, failure: "Invalid request: \(name)")
        }
        switch name {
        case ".create":
            let stream = IncomingRemoteStream(
                endpointID: endpointID, label: endpoint["label"] as? String ?? "", details: endpoint["details"] as? Stanza ?? [:], receiver: self)
            streams[endpointID] = stream
            onStream?(stream)
            reply(to: id, failure: nil)
        case ".write":
            guard let stream = streams[endpointID] else { return reply(to: id, failure: "Invalid endpoint ID") }
            guard let data else { return reply(to: id, failure: "Invalid request: missing data") }
            stream.deliver(data, requestID: id)
        case ".finish":
            guard let stream = streams.removeValue(forKey: endpointID) else { return reply(to: id, failure: "Invalid endpoint ID") }
            stream.finish()
            reply(to: id, failure: nil)
        default:
            reply(to: id, failure: "Invalid request: \(name)")
        }
    }

    func abort(endpointID: Int, reason: String) {
        streams.removeValue(forKey: endpointID)?.abort(reason)
    }

    func abortAll(reason: String) {
        for stream in streams.values {
            stream.abort(reason)
        }
        streams = [:]
    }

    fileprivate func reply(to id: Int, failure message: String?) {
        guard let message else {
            return send(["id": id, "name": "+result", "payload": Stanza()])
        }
        send(["id": id, "name": "+error", "payload": ["message": message]])
    }

    fileprivate func forget(_ stream: IncomingRemoteStream) {
        if streams[stream.endpointID] === stream {
            streams[stream.endpointID] = nil
        }
    }
}

@MainActor
final class IncomingRemoteStream {
    let endpointID: Int
    let label: String
    let details: [String: Any]
    var onAbort: ((String) -> Void)?

    private unowned let receiver: RemoteStreamReceiver
    private var delivery: (chunk: Data, requestID: Int)?
    private var reader: CheckedContinuation<Data?, Error>?
    private var ending: Ending?

    private enum Ending {
        case finished
        case refused(String)
        case aborted(String)
    }

    fileprivate init(endpointID: Int, label: String, details: [String: Any], receiver: RemoteStreamReceiver) {
        self.endpointID = endpointID
        self.label = label
        self.details = details
        self.receiver = receiver
    }

    func read() async throws -> Data? {
        if let delivery {
            self.delivery = nil
            return take(delivery)
        }
        switch ending {
        case .finished:
            return nil
        case .refused(let message), .aborted(let message):
            throw RemoteStreamError(message: message)
        case nil:
            return try await withCheckedThrowingContinuation { reader = $0 }
        }
    }

    func refuse(_ message: String) {
        guard ending == nil else { return }
        ending = .refused(message)
        if let delivery {
            self.delivery = nil
            receiver.reply(to: delivery.requestID, failure: message)
        }
        reader?.resume(throwing: RemoteStreamError(message: message))
        reader = nil
    }

    fileprivate func deliver(_ chunk: Data, requestID: Int) {
        if case .refused(let message) = ending {
            return receiver.reply(to: requestID, failure: message)
        }
        guard ending == nil, delivery == nil else {
            return receiver.reply(to: requestID, failure: "Protocol violation")
        }
        guard !chunk.isEmpty else {
            receiver.forget(self)
            finish()
            return receiver.reply(to: requestID, failure: "Stream closed")
        }
        guard let reader else {
            delivery = (chunk, requestID)
            return
        }
        self.reader = nil
        reader.resume(returning: take((chunk, requestID)))
    }

    fileprivate func finish() {
        guard ending == nil else { return }
        ending = .finished
        guard delivery == nil, let reader else { return }
        self.reader = nil
        reader.resume(returning: nil)
    }

    fileprivate func abort(_ reason: String) {
        guard ending == nil else { return }
        ending = .aborted(reason)
        delivery = nil
        reader?.resume(throwing: RemoteStreamError(message: reason))
        reader = nil
        onAbort?(reason)
    }

    private func take(_ delivery: (chunk: Data, requestID: Int)) -> Data {
        receiver.reply(to: delivery.requestID, failure: nil)
        return delivery.chunk
    }
}

public struct RemoteStreamError: LocalizedError, Sendable {
    public let message: String

    public var errorDescription: String? {
        message
    }
}
