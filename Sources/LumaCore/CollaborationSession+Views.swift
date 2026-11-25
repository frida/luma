import Foundation

extension CollaborationSession {
    static let viewStateChunkBytes = 1024 * 1024

    public func sendViewState(_ state: WidgetViewState, sessionID: UUID, instanceID: UUID, widget: String) {
        guard case .joined(let labID) = status else { return }
        let size = state.payload.data?.count ?? 0
        var offset = 0
        repeat {
            let end = min(offset + Self.viewStateChunkBytes, size)
            var payload: JSONObject = [
                "instance_id": instanceID.uuidString,
                "revision": state.revision,
                "data_size": size,
                "offset": offset,
            ]
            WidgetSlot.addTarget(widget, to: &payload)
            if offset == 0 {
                payload["value"] = state.payload.value
            }
            let chunk = offset < end ? state.payload.data?.bytes(in: offset..<end) : nil
            sendNotification(to: viewStatesPath(labID: labID, sessionID: sessionID), type: "+set", payload: payload, data: chunk)
            offset = end
        } while offset < size
    }

    public func sendViewEvent(_ event: WidgetViewPayload, sessionID: UUID, instanceID: UUID, widget: String) {
        guard case .joined(let labID) = status else { return }
        var payload: JSONObject = ["instance_id": instanceID.uuidString, "value": event.value as Any]
        WidgetSlot.addTarget(widget, to: &payload)
        sendNotification(
            to: "/labs/\(labID)/sessions/\(sessionID.uuidString)/view-events", type: "+event", payload: payload, data: event.data?.array)
    }

    public func sendViewMessage(_ message: WidgetViewPayload, sessionID: UUID, instanceID: UUID, widget: String) {
        guard case .joined(let labID) = status else { return }
        var payload: JSONObject = ["instance_id": instanceID.uuidString, "value": message.value as Any]
        WidgetSlot.addTarget(widget, to: &payload)
        sendNotification(
            to: "/labs/\(labID)/sessions/\(sessionID.uuidString)/view-messages", type: "+message", payload: payload, data: message.data?.array)
    }

    static func customInstrumentEditors(in bundles: [JSONObject]) -> [UUID: UserInfo] {
        var editors: [UUID: UserInfo] = [:]
        for bundle in bundles {
            guard let defID = (bundle["id"] as? String).flatMap(UUID.init(uuidString:)),
                let editor = (bundle["changed_by"] as? JSONObject).flatMap(UserInfo.fromJSON)
            else { continue }
            editors[defID] = editor
        }
        return editors
    }

    func ingestViewStates(_ entries: [JSONObject], labID: String) {
        for entry in entries {
            guard let sessionID = (entry["session_id"] as? String).flatMap(UUID.init(uuidString:)) else { continue }
            receiveViewState(entry, data: nil, sessionID: sessionID, labID: labID)
        }
    }

    func receiveViewState(_ payload: JSONObject, data: [UInt8]?, sessionID: UUID, labID: String) {
        guard let target = Self.viewTarget(of: payload),
            let revision = payload["revision"] as? Int,
            let size = payload["data_size"] as? Int
        else { return }
        guard size <= WidgetViewPayload.maxStateDataBytes else {
            let refusal = WidgetViewRefusal.data(bytes: size, most: WidgetViewPayload.maxStateDataBytes)
            onSessionViewRefused?(sessionID, target.instanceID, target.widget, "A state from the lab was refused: \(refusal.message)")
            return
        }
        let value = WidgetViewPayload(value: payload["value"], data: nil)

        let deliver = { [weak self] (data: SharedBytes?) in
            let state = WidgetViewState(revision: revision, payload: WidgetViewPayload(json: value.json, data: data))
            self?.onSessionViewStateReceived?(sessionID, target.instanceID, target.widget, state)
        }
        if size == 0 {
            deliver(nil)
        } else if let data, data.count == size {
            deliver(SharedBytes(copying: data))
        } else {
            Task { [weak self] in
                guard let self,
                    let fetched = try? await fetchViewData(of: target, revision: revision, size: size, sessionID: sessionID, labID: labID)
                else { return }
                deliver(fetched)
            }
        }
    }

    private func fetchViewData(
        of target: (instanceID: UUID, widget: String),
        revision: Int,
        size: Int,
        sessionID: UUID,
        labID: String
    ) async throws -> SharedBytes {
        let assembly = SharedBytesAssembly(count: size)
        while !assembly.isComplete {
            let length = min(Self.viewStateChunkBytes, size - assembly.written)
            let chunk = try await fetchViewDataChunk(
                of: target, revision: revision, offset: assembly.written,
                length: length,
                sessionID: sessionID, labID: labID)
            guard !chunk.isEmpty else { throw LumaCoreError.invalidOperation("The lab holds less of the view's data than it said.") }
            guard chunk.count <= length else {
                throw LumaCoreError.invalidOperation("The lab sent more of the view's data than was asked for.")
            }
            chunk.withUnsafeBytes { assembly.append($0) }
        }
        return assembly.finish()
    }

    private func fetchViewDataChunk(
        of target: (instanceID: UUID, widget: String),
        revision: Int,
        offset: Int,
        length: Int,
        sessionID: UUID,
        labID: String
    ) async throws -> [UInt8] {
        var payload: JSONObject = ["instance_id": target.instanceID.uuidString, "revision": revision, "offset": offset, "length": length]
        WidgetSlot.addTarget(target.widget, to: &payload)
        return try await withCheckedThrowingContinuation { continuation in
            sendRequest(to: viewStatesPath(labID: labID, sessionID: sessionID), type: ".fetch", payload: payload) { result in
                switch result {
                case .success(let reply):
                    continuation.resume(returning: reply.data ?? [])
                case .failure(let failure):
                    continuation.resume(throwing: failure)
                }
            }
        }
    }

    static func viewTarget(of payload: JSONObject) -> (instanceID: UUID, widget: String)? {
        guard let instanceID = (payload["instance_id"] as? String).flatMap(UUID.init(uuidString:)),
            let widget = WidgetSlot.target(in: payload)
        else { return nil }
        return (instanceID, widget)
    }

    private func viewStatesPath(labID: String, sessionID: UUID) -> String {
        "/labs/\(labID)/sessions/\(sessionID.uuidString)/view-states"
    }
}
