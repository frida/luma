import Foundation

extension Engine {
    public func saveOfferedFile(_ id: UUID, to url: URL) async throws {
        guard let stream = takeOfferedFile(id) else { return }
        let handle: FileHandle
        do {
            try Data().write(to: url)
            handle = try FileHandle(forWritingTo: url)
        } catch {
            let failure = "Luma could not create \(url.path): \(error.localizedDescription)"
            stream.refuse(failure)
            throw RemoteStreamError(message: failure)
        }
        do {
            var total = 0
            while let chunk = try await stream.read() {
                total += chunk.count
                guard total <= OfferedFile.maxBytes else {
                    throw RemoteStreamError(message: "the file grew past \(OfferedFile.maxBytes) bytes (64 MiB)")
                }
                try handle.write(contentsOf: chunk)
            }
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
            stream.refuse(error.localizedDescription)
            throw error
        }
    }

    public func declineOfferedFile(_ id: UUID) {
        takeOfferedFile(id)?.refuse("the file was not saved")
    }

    @discardableResult
    private func takeOfferedFile(_ id: UUID) -> IncomingRemoteStream? {
        offeredFiles.removeAll { $0.id == id }
        let stream = offeredFileStreams.removeValue(forKey: id)
        stream?.onAbort = nil
        return stream
    }

    func handlerEnded(actionID: UUID, offeredFile: Bool) {
        if !offeredFile {
            fileRecipients[actionID] = nil
        }
    }

    func handleFileStreamTraffic(_ traffic: FileStreamTraffic, sessionID: UUID) {
        switch traffic {
        case .stanza(let stanza, let data):
            agentSent(stanza, data: data, sessionID: sessionID)
        case .abort(let actionID, let reason):
            agentAborted(actionID: actionID, reason: reason)
        }
    }

    private func agentSent(_ stanza: [String: Any], data: Data?, sessionID: UUID) {
        let endpoint = (stanza["payload"] as! [String: Any])["endpoint"] as! [String: Any]
        let key = FileStreamKey(sessionID: sessionID, endpointID: endpoint["id"] as! Int)
        if stanza["name"] as? String == ".create" {
            let details = endpoint["details"] as! [String: Any]
            let actionID = UUID(uuidString: details["action_id"] as! String)!
            fileStreamActions[key] = actionID
            switch fileRecipients.removeValue(forKey: actionID) ?? .person {
            case .person:
                fileStreams[actionID] = .local(key)
            case .member(let memberSessionID):
                fileStreams[actionID] = .relayed(RelayedFileStream(key: key, memberSessionID: memberSessionID, createID: stanza["id"] as! Int))
                var forwarded = stanza
                var payload = stanza["payload"] as! [String: Any]
                var strippedEndpoint = endpoint
                strippedEndpoint["details"] = ["name": details["name"] as Any, "media_type": details["media_type"] as Any]
                payload["endpoint"] = strippedEndpoint
                forwarded["payload"] = payload
                return collaboration.relayFileStream(sessionID: memberSessionID, actionID: actionID, stanza: forwarded, data: nil)
            }
        }
        guard let actionID = fileStreamActions[key], let route = fileStreams[actionID] else { return }
        let isFinish = stanza["name"] as? String == ".finish"
        switch route {
        case .local:
            localFileReceiver(sessionID: sessionID).receive(stanza, data: data)
        case .relayed(var relayed):
            let id = stanza["id"] as! Int
            if let failure = relayed.failure {
                return answerAgent(sessionID: sessionID, id: id, failure: isFinish ? nil : failure, endingStreamOf: isFinish ? actionID : nil)
            }
            if isFinish {
                relayed.finishID = id
            } else {
                relayed.outstandingWrite = id
            }
            fileStreams[actionID] = .relayed(relayed)
            collaboration.relayFileStream(sessionID: relayed.memberSessionID, actionID: actionID, stanza: stanza, data: data)
            return
        }
        if isFinish {
            forgetFileStream(actionID)
        }
    }

    func endFileStreams(ofSession sessionID: UUID, reason: String) {
        for (actionID, route) in fileStreams where route.key.sessionID == sessionID {
            agentAborted(actionID: actionID, reason: reason)
        }
        localFileReceivers.removeValue(forKey: sessionID)?.abortAll(reason: reason)
    }

    private func agentAborted(actionID: UUID, reason: String) {
        guard let route = fileStreams[actionID] else { return }
        switch route {
        case .local(let key):
            localFileReceiver(sessionID: key.sessionID).abort(endpointID: key.endpointID, reason: reason)
        case .relayed(let relayed):
            collaboration.abortRelayedStream(sessionID: relayed.memberSessionID, actionID: actionID, reason: reason)
        }
        forgetFileStream(actionID)
    }

    func relayedStreamReplied(actionID: UUID, stanza: [String: Any]) {
        guard case .relayed(var relayed) = fileStreams[actionID], let id = stanza["id"] as? Int else { return }
        let failure = stanza["name"] as? String == "+error" ? ((stanza["payload"] as? [String: Any])?["message"] as? String ?? "the file was not saved") : nil
        if id == relayed.createID || id == relayed.finishID {
            let ending = id == relayed.finishID
            relayed.failure = relayed.failure ?? failure
            fileStreams[actionID] = .relayed(relayed)
            if ending {
                collaboration.endRelayedStream(actionID: actionID)
            }
            return answerAgent(sessionID: relayed.key.sessionID, id: id, failure: nil, endingStreamOf: ending ? actionID : nil)
        }
        guard relayed.outstandingWrite == id else { return }
        relayed.outstandingWrite = nil
        relayed.failure = relayed.failure ?? failure
        fileStreams[actionID] = .relayed(relayed)
        if failure != nil {
            collaboration.endRelayedStream(actionID: actionID)
        }
        answerAgent(sessionID: relayed.key.sessionID, id: id, failure: failure, endingStreamOf: failure != nil ? actionID : nil)
    }

    func relayedStreamEnded(actionID: UUID, reason: String) {
        guard case .relayed(var relayed) = fileStreams[actionID] else { return }
        relayed.failure = reason
        let outstanding = relayed.outstandingWrite
        relayed.outstandingWrite = nil
        fileStreams[actionID] = .relayed(relayed)
        if let outstanding {
            answerAgent(sessionID: relayed.key.sessionID, id: outstanding, failure: reason, endingStreamOf: nil)
        }
    }

    private func answerAgent(sessionID: UUID, id: Int, failure: String?, endingStreamOf actionID: UUID?) {
        let reply: [String: Any] = failure.map { ["id": id, "name": "+error", "payload": ["message": $0]] }
            ?? ["id": id, "name": "+result", "payload": [String: Any]()]
        node(forSessionID: sessionID)?.postFileStreamStanza(reply)
        if let actionID {
            forgetFileStream(actionID)
        }
    }

    private func forgetFileStream(_ actionID: UUID) {
        guard let route = fileStreams.removeValue(forKey: actionID) else { return }
        fileStreamActions[route.key] = nil
    }

    private func localFileReceiver(sessionID: UUID) -> RemoteStreamReceiver {
        if let receiver = localFileReceivers[sessionID] {
            return receiver
        }
        let receiver = RemoteStreamReceiver { [weak self] reply in
            self?.node(forSessionID: sessionID)?.postFileStreamStanza(reply)
        }
        receiver.onStream = { [weak self] stream in
            let instanceID = (stream.details["instance_id"] as? String).flatMap(UUID.init(uuidString:))
            self?.offer(stream, instanceID: instanceID)
        }
        localFileReceivers[sessionID] = receiver
        return receiver
    }

    func offer(_ stream: IncomingRemoteStream, instanceID: UUID?) {
        let name = stream.details["name"] as? String ?? ""
        let mediaType = stream.details["media_type"] as? String ?? ""
        if let problem = OfferedFile.problem(name: name, mediaType: mediaType) {
            return stream.refuse(problem)
        }
        let instrumentName = instrumentsBySession.values.flatMap { $0 }.first { $0.id == instanceID }
            .map { descriptor(for: $0).displayName } ?? "an instrument"
        guard offeredFiles.count < OfferedFile.maxOpen else {
            stream.refuse("four files are already waiting to be saved")
            emitEngineWarning(
                subsystem: "instruments",
                text: "“\(name)” from \(instrumentName) was not offered for saving because four files are already waiting.")
            return
        }
        let file = OfferedFile(id: UUID(), name: name, mediaType: mediaType, instrumentName: instrumentName)
        offeredFiles.append(file)
        offeredFileStreams[file.id] = stream
        stream.onAbort = { [weak self] _ in
            self?.takeOfferedFile(file.id)
        }
    }
}

enum ActionChooser: Sendable {
    case person
    case mission
}

struct FileStreamKey: Hashable {
    let sessionID: UUID
    let endpointID: Int
}

enum FileRecipient {
    case person
    case member(UUID)
}

enum FileStreamRoute {
    case local(FileStreamKey)
    case relayed(RelayedFileStream)

    var key: FileStreamKey {
        switch self {
        case .local(let key): key
        case .relayed(let relayed): relayed.key
        }
    }
}

struct RelayedFileStream {
    let key: FileStreamKey
    let memberSessionID: UUID
    let createID: Int
    var finishID: Int?
    var outstandingWrite: Int?
    var failure: String?
}
