import Foundation

public struct WidgetUpdate: Sendable, Identifiable {
    public let id: UUID
    public let instanceID: UUID
    public let widget: String
    public let kind: Kind
    public let revision: Int

    public init(id: UUID = UUID(), instanceID: UUID, widget: String, kind: Kind, revision: Int = 0) {
        self.id = id
        self.instanceID = instanceID
        self.widget = widget
        self.kind = kind
        self.revision = revision
    }

    public enum Kind: Sendable {
        case counterSet(WidgetCounterValue)
        case histogramSet([WidgetHistogramBucket])
        case histogramIncrement(label: String, by: Double)
        case graphPoint(WidgetGraphPoint)
        case listUpsert(WidgetListItem)
        case listRemove(itemID: String)
        case tableUpsert(WidgetTableRow)
        case tableRemove(rowID: String)
        case hexSet(WidgetHexState)
        case consoleAppend(WidgetConsoleEntry)
        /// Posted by the agent when `onConsoleInput` has finished posting
        /// replies for `inputEntryID`. Lets request/response waiters exit
        /// before their timeout elapses.
        case consoleReplyDone(inputEntryID: String)
        case viewState(WidgetViewState)
        case viewEvent(WidgetViewPayload)
        case viewRefused(String)
        case clear
        case snapshot(WidgetState)
    }

    public func toWireJSON() -> [String: Any] {
        var obj = kind.wireJSON
        obj["instance_id"] = instanceID.uuidString
        obj["widget"] = widget
        obj["revision"] = revision
        return obj
    }

    public static func fromWireJSON(_ obj: [String: Any]) -> WidgetUpdate? {
        guard let instanceIDStr = obj["instance_id"] as? String,
            let instanceID = UUID(uuidString: instanceIDStr),
            let widget = obj["widget"] as? String,
            let kindStr = obj["kind"] as? String,
            let revision = obj["revision"] as? Int
        else { return nil }
        guard let kind = decodeKind(kindStr, from: obj) else { return nil }
        return WidgetUpdate(instanceID: instanceID, widget: widget, kind: kind, revision: revision)
    }

    private static func decodeKind(_ kindStr: String, from obj: [String: Any]) -> Kind? {
        switch kindStr {
        case "counter-set":
            guard let counter = obj["counter"] as? [String: Any],
                let value = decodeDouble(counter["value"])
            else { return nil }
            return .counterSet(WidgetCounterValue(
                value: value,
                unit: counter["unit"] as? String,
                delta: decodeDouble(counter["delta"])
            ))
        case "histogram-set":
            guard let buckets = obj["buckets"] as? [[String: Any]] else { return nil }
            let parsed = buckets.compactMap { b -> WidgetHistogramBucket? in
                guard let label = b["label"] as? String, let count = decodeDouble(b["count"]) else { return nil }
                return WidgetHistogramBucket(label: label, count: count)
            }
            return .histogramSet(parsed)
        case "histogram-increment":
            guard let label = obj["label"] as? String, let by = decodeDouble(obj["by"]) else { return nil }
            return .histogramIncrement(label: label, by: by)
        case "graph-point":
            guard let pointObj = obj["point"] as? [String: Any],
                let series = pointObj["series"] as? String,
                let x = decodeDouble(pointObj["x"]),
                let y = decodeDouble(pointObj["y"])
            else { return nil }
            return .graphPoint(WidgetGraphPoint(series: series, x: x, y: y))
        case "list-upsert":
            guard let itemObj = obj["item"] as? [String: Any],
                let id = itemObj["id"] as? String,
                let title = itemObj["title"] as? String
            else { return nil }
            return .listUpsert(WidgetListItem(
                id: id,
                title: title,
                subtitle: itemObj["subtitle"] as? String,
                accessory: itemObj["accessory"] as? String
            ))
        case "list-remove":
            guard let itemID = obj["item"] as? String else { return nil }
            return .listRemove(itemID: itemID)
        case "table-upsert":
            guard let rowObj = obj["row"] as? [String: Any],
                let id = rowObj["id"] as? String,
                let cells = rowObj["cells"] as? [String: String]
            else { return nil }
            return .tableUpsert(WidgetTableRow(id: id, cells: cells))
        case "table-remove":
            guard let rowID = obj["row"] as? String else { return nil }
            return .tableRemove(rowID: rowID)
        case "hex-set":
            guard let hex = obj["hex"] as? [String: Any],
                let b64 = hex["bytes"] as? String,
                let bytes = Data(base64Encoded: b64)
            else { return nil }
            let baseAddress: UInt64 = (hex["base_address"] as? NSNumber)?.uint64Value ?? 0
            return .hexSet(WidgetHexState(bytes: bytes, baseAddress: baseAddress))
        case "console-append":
            guard let entryObj = obj["entry"] as? [String: Any],
                let entry = WidgetConsoleEntry.fromWireJSON(entryObj)
            else { return nil }
            return .consoleAppend(entry)
        case "console-reply-done":
            guard let replyTo = obj["reply_to"] as? String else { return nil }
            return .consoleReplyDone(inputEntryID: replyTo)
        case "clear":
            return .clear
        case "replace":
            guard let state = obj["state"] as? [String: Any] else { return nil }
            return .snapshot(WidgetState(wireJSON: state))
        default:
            return nil
        }
    }

    private static func decodeDouble(_ raw: Any?) -> Double? {
        if let n = raw as? NSNumber { return n.doubleValue }
        return nil
    }
}

extension WidgetUpdate.Kind {
    var wireJSON: [String: Any] {
        var obj: [String: Any] = [:]
        switch self {
        case .counterSet(let value):
            obj["kind"] = "counter-set"
            var counter: [String: Any] = ["value": value.value]
            if let unit = value.unit { counter["unit"] = unit }
            if let delta = value.delta { counter["delta"] = delta }
            obj["counter"] = counter
        case .histogramSet(let buckets):
            obj["kind"] = "histogram-set"
            obj["buckets"] = buckets.map { ["label": $0.label, "count": $0.count] }
        case .histogramIncrement(let label, let by):
            obj["kind"] = "histogram-increment"
            obj["label"] = label
            obj["by"] = by
        case .graphPoint(let point):
            obj["kind"] = "graph-point"
            obj["point"] = ["series": point.series, "x": point.x, "y": point.y]
        case .listUpsert(let item):
            obj["kind"] = "list-upsert"
            var itemObj: [String: Any] = ["id": item.id, "title": item.title]
            if let s = item.subtitle { itemObj["subtitle"] = s }
            if let a = item.accessory { itemObj["accessory"] = a }
            obj["item"] = itemObj
        case .listRemove(let itemID):
            obj["kind"] = "list-remove"
            obj["item"] = itemID
        case .tableUpsert(let row):
            obj["kind"] = "table-upsert"
            obj["row"] = ["id": row.id, "cells": row.cells]
        case .tableRemove(let rowID):
            obj["kind"] = "table-remove"
            obj["row"] = rowID
        case .hexSet(let state):
            obj["kind"] = "hex-set"
            obj["hex"] = [
                "bytes": state.bytes.base64EncodedString(),
                "base_address": state.baseAddress,
            ]
        case .consoleAppend(let entry):
            obj["kind"] = "console-append"
            obj["entry"] = entry.toWireJSON()
        case .consoleReplyDone(let inputEntryID):
            obj["kind"] = "console-reply-done"
            obj["reply_to"] = inputEntryID
        case .clear:
            obj["kind"] = "clear"
        case .viewState, .viewEvent, .viewRefused:
            preconditionFailure("A view's state and events travel on their own path")
        case .snapshot(let state):
            obj["kind"] = "replace"
            obj["state"] = state.wireJSON
        }
        return obj
    }
}

public struct WidgetCounterValue: Codable, Sendable, Equatable {
    public var value: Double
    public var unit: String?
    public var delta: Double?

    public init(value: Double, unit: String? = nil, delta: Double? = nil) {
        self.value = value
        self.unit = unit
        self.delta = delta
    }
}

public struct WidgetHistogramBucket: Codable, Sendable, Equatable {
    public let label: String
    public var count: Double

    public init(label: String, count: Double) {
        self.label = label
        self.count = count
    }
}

public struct WidgetGraphPoint: Codable, Sendable, Equatable {
    public let series: String
    public let x: Double
    public let y: Double

    public init(series: String, x: Double, y: Double) {
        self.series = series
        self.x = x
        self.y = y
    }
}

public struct WidgetListItem: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public var title: String
    public var subtitle: String?
    public var accessory: String?

    public init(id: String, title: String, subtitle: String? = nil, accessory: String? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory
    }
}

public struct WidgetTableRow: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public var cells: [String: String]

    public init(id: String, cells: [String: String]) {
        self.id = id
        self.cells = cells
    }
}

public struct WidgetHexState: Codable, Sendable, Equatable {
    public var bytes: Data
    public var baseAddress: UInt64

    public init(bytes: Data, baseAddress: UInt64 = 0) {
        self.bytes = bytes
        self.baseAddress = baseAddress
    }
}

public struct WidgetViewPayload: Sendable, Equatable {
    public static let maxJSONBytes = 256 * 1024
    public static let maxEventDataBytes = 1024 * 1024
    public static let maxStateDataBytes = 64 * 1024 * 1024

    public var json: String
    public var data: SharedBytes?

    public init(json: String, data: SharedBytes? = nil) {
        self.json = json
        self.data = data
    }

    public init(value: Any?, data: SharedBytes?) {
        let encoded = try! JSONSerialization.data(withJSONObject: value ?? NSNull(), options: [.fragmentsAllowed, .withoutEscapingSlashes])
        self.init(json: String(decoding: encoded, as: UTF8.self), data: data)
    }

    public func checking(atMost maxDataBytes: Int) throws(WidgetViewRefusal) -> WidgetViewPayload {
        let jsonBytes = json.utf8.count
        guard jsonBytes <= Self.maxJSONBytes else { throw .value(bytes: jsonBytes, most: Self.maxJSONBytes) }
        return try checkingData(atMost: maxDataBytes)
    }

    public func checkingData(atMost maxDataBytes: Int) throws(WidgetViewRefusal) -> WidgetViewPayload {
        if let data, data.count > maxDataBytes {
            throw .data(bytes: data.count, most: maxDataBytes)
        }
        return self
    }

    public var value: Any {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])) ?? NSNull()
    }
}

public enum WidgetViewRefusal: Error, Sendable {
    case value(bytes: Int, most: Int)
    case data(bytes: Int, most: Int)

    public var message: String {
        switch self {
        case .value(let bytes, let most):
            "its value is \(bytes) bytes of JSON as UTF-8; the most is \(most)"
        case .data(let bytes, let most):
            "its data is \(bytes) bytes; the most is \(most)"
        }
    }
}

public struct WidgetViewState: Codable, Sendable, Equatable {
    public var revision: Int
    public var payload: WidgetViewPayload

    public init(revision: Int, payload: WidgetViewPayload) {
        self.revision = revision
        self.payload = payload
    }

    private enum CodingKeys: String, CodingKey {
        case revision, json
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        revision = try c.decode(Int.self, forKey: .revision)
        payload = WidgetViewPayload(json: try c.decode(String.self, forKey: .json))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(revision, forKey: .revision)
        try c.encode(payload.json, forKey: .json)
    }
}

public struct ConsoleImage: Codable, Sendable, Equatable {
    public var mediaType: String
    public var data: Data
    public var width: Int
    public var height: Int

    public init(mediaType: String, data: Data, width: Int, height: Int) {
        self.mediaType = mediaType
        self.data = data
        self.width = width
        self.height = height
    }
}

public struct WidgetConsoleEntry: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case input
        case output
        case image
        case error
    }

    public let id: String
    public let kind: Kind
    public var text: String
    public var value: JSInspectValue?
    public var image: ConsoleImage?
    public var replyTo: String?

    public init(
        id: String = UUID().uuidString,
        kind: Kind,
        text: String,
        value: JSInspectValue? = nil,
        image: ConsoleImage? = nil,
        replyTo: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.value = value
        self.image = image
        self.replyTo = replyTo
    }

    public func toWireJSON() -> [String: Any] {
        var obj: [String: Any] = [
            "id": id,
            "kind": kind.rawValue,
            "text": text,
        ]
        if let value, let encoded = try? JSONEncoder().encode(value),
           let valueJSON = try? JSONSerialization.jsonObject(with: encoded)
        {
            obj["value"] = valueJSON
        }
        if let image {
            obj["image"] = [
                "media_type": image.mediaType,
                "data_base64": image.data.base64EncodedString(),
                "width": image.width,
                "height": image.height,
            ]
        }
        if let replyTo { obj["reply_to"] = replyTo }
        return obj
    }

    public static func fromWireJSON(_ obj: [String: Any]) -> WidgetConsoleEntry? {
        guard let id = obj["id"] as? String,
            let kindStr = obj["kind"] as? String,
            let kind = Kind(rawValue: kindStr),
            let text = obj["text"] as? String
        else { return nil }
        var value: JSInspectValue? = nil
        if let raw = obj["value"],
           let data = try? JSONSerialization.data(withJSONObject: raw)
        {
            value = try? JSONDecoder().decode(JSInspectValue.self, from: data)
        }
        let image = (obj["image"] as? [String: Any]).flatMap(parseConsoleImage)
        let replyTo = obj["reply_to"] as? String
        return WidgetConsoleEntry(id: id, kind: kind, text: text, value: value, image: image, replyTo: replyTo)
    }
}

private func parseConsoleImage(_ obj: [String: Any]) -> ConsoleImage? {
    guard let mediaType = obj["media_type"] as? String,
        let base64 = obj["data_base64"] as? String,
        let data = Data(base64Encoded: base64),
        let width = obj["width"] as? Int,
        let height = obj["height"] as? Int
    else { return nil }
    return ConsoleImage(mediaType: mediaType, data: data, width: width, height: height)
}

public struct WidgetStateSnapshot: Sendable {
    public let sessionID: UUID
    public let instanceID: UUID
    public let widget: String
    public let state: WidgetState

    public init(sessionID: UUID, instanceID: UUID, widget: String, state: WidgetState) {
        self.sessionID = sessionID
        self.instanceID = instanceID
        self.widget = widget
        self.state = state
    }

    public static func fromWireJSON(_ obj: [String: Any]) -> WidgetStateSnapshot? {
        guard let sessionStr = obj["session_id"] as? String,
            let sessionID = UUID(uuidString: sessionStr),
            let instanceStr = obj["instance_id"] as? String,
            let instanceID = UUID(uuidString: instanceStr),
            let widget = obj["widget"] as? String,
            let stateObj = obj["state"] as? [String: Any],
            let revision = obj["revision"] as? Int
        else { return nil }

        var state = WidgetState(wireJSON: stateObj)
        state.revision = revision
        return WidgetStateSnapshot(sessionID: sessionID, instanceID: instanceID, widget: widget, state: state)
    }
}

public struct WidgetState: Codable, Sendable, Equatable {
    public var counter: WidgetCounterValue?
    public var histogram: [WidgetHistogramBucket]
    public var graphSeries: [String: [WidgetGraphPoint]]
    public var listItems: [WidgetListItem]
    public var tableRows: [WidgetTableRow]
    public var hex: WidgetHexState?
    public var consoleEntries: [WidgetConsoleEntry]
    public var view: WidgetViewState?
    public var revision: Int

    public init(
        counter: WidgetCounterValue? = nil,
        histogram: [WidgetHistogramBucket] = [],
        graphSeries: [String: [WidgetGraphPoint]] = [:],
        listItems: [WidgetListItem] = [],
        tableRows: [WidgetTableRow] = [],
        hex: WidgetHexState? = nil,
        consoleEntries: [WidgetConsoleEntry] = [],
        view: WidgetViewState? = nil,
        revision: Int = 0
    ) {
        self.counter = counter
        self.histogram = histogram
        self.graphSeries = graphSeries
        self.listItems = listItems
        self.tableRows = tableRows
        self.hex = hex
        self.consoleEntries = consoleEntries
        self.view = view
        self.revision = revision
    }

    init(wireJSON stateObj: [String: Any]) {
        var counter: WidgetCounterValue?
        if let c = stateObj["counter"] as? [String: Any], let value = (c["value"] as? NSNumber)?.doubleValue {
            counter = WidgetCounterValue(
                value: value,
                unit: c["unit"] as? String,
                delta: (c["delta"] as? NSNumber)?.doubleValue
            )
        }

        var histogram: [WidgetHistogramBucket] = []
        if let buckets = stateObj["buckets"] as? [[String: Any]] {
            for b in buckets {
                guard let label = b["label"] as? String, let count = (b["count"] as? NSNumber)?.doubleValue else { continue }
                histogram.append(WidgetHistogramBucket(label: label, count: count))
            }
        }

        var graphSeries: [String: [WidgetGraphPoint]] = [:]
        if let pts = stateObj["points"] as? [[String: Any]] {
            for p in pts {
                guard let series = p["series"] as? String,
                    let x = (p["x"] as? NSNumber).map({ $0.doubleValue }),
                    let y = (p["y"] as? NSNumber).map({ $0.doubleValue })
                else { continue }
                graphSeries[series, default: []].append(WidgetGraphPoint(series: series, x: x, y: y))
            }
        }

        var listItems: [WidgetListItem] = []
        if let items = stateObj["items"] as? [[String: Any]] {
            for it in items {
                guard let id = it["id"] as? String, let title = it["title"] as? String else { continue }
                listItems.append(WidgetListItem(
                    id: id,
                    title: title,
                    subtitle: it["subtitle"] as? String,
                    accessory: it["accessory"] as? String
                ))
            }
        }

        var tableRows: [WidgetTableRow] = []
        if let rows = stateObj["rows"] as? [[String: Any]] {
            for row in rows {
                guard let id = row["id"] as? String, let cells = row["cells"] as? [String: String] else { continue }
                tableRows.append(WidgetTableRow(id: id, cells: cells))
            }
        }

        var hex: WidgetHexState?
        if let h = stateObj["hex"] as? [String: Any],
            let b64 = h["bytes"] as? String,
            let bytes = Data(base64Encoded: b64)
        {
            hex = WidgetHexState(
                bytes: bytes,
                baseAddress: (h["base_address"] as? NSNumber)?.uint64Value ?? 0
            )
        }

        var consoleEntries: [WidgetConsoleEntry] = []
        if let entries = stateObj["entries"] as? [[String: Any]] {
            for e in entries {
                if let parsed = WidgetConsoleEntry.fromWireJSON(e) {
                    consoleEntries.append(parsed)
                }
            }
        }

        self.init(
            counter: counter,
            histogram: histogram,
            graphSeries: graphSeries,
            listItems: listItems,
            tableRows: tableRows,
            hex: hex,
            consoleEntries: consoleEntries
        )
    }

    public mutating func apply(_ kind: WidgetUpdate.Kind) {
        if case .snapshot(let snapshot) = kind {
            self = snapshot
            return
        }
        switch kind {
        case .counterSet(let value):
            counter = value
        case .histogramSet(let buckets):
            histogram = buckets
        case .histogramIncrement(let label, let by):
            if let index = histogram.firstIndex(where: { $0.label == label }) {
                histogram[index].count += by
            } else {
                histogram.append(WidgetHistogramBucket(label: label, count: by))
            }
        case .graphPoint(let point):
            graphSeries[point.series, default: []].append(point)
        case .listUpsert(let item):
            if let index = listItems.firstIndex(where: { $0.id == item.id }) {
                listItems[index] = item
            } else {
                listItems.append(item)
            }
        case .listRemove(let id):
            listItems.removeAll { $0.id == id }
        case .tableUpsert(let row):
            if let index = tableRows.firstIndex(where: { $0.id == row.id }) {
                tableRows[index] = row
            } else {
                tableRows.append(row)
            }
        case .tableRemove(let id):
            tableRows.removeAll { $0.id == id }
        case .hexSet(let value):
            hex = value
        case .consoleAppend(let entry):
            consoleEntries.append(entry)
        case .consoleReplyDone, .viewEvent, .viewRefused:
            break
        case .viewState(let value):
            view = value
        case .clear:
            counter = nil
            histogram.removeAll()
            graphSeries.removeAll()
            listItems.removeAll()
            tableRows.removeAll()
            hex = nil
            consoleEntries.removeAll()
            view = nil
        case .snapshot:
            break
        }
    }

    public mutating func cap(to kind: InstrumentWidget.Kind) {
        switch kind {
        case .counter:
            break
        case .histogram(let cfg):
            if histogram.count > cfg.maxBuckets {
                histogram.removeFirst(histogram.count - cfg.maxBuckets)
            }
        case .graph(let cfg):
            for (seriesID, points) in graphSeries where points.count > cfg.maxPoints {
                graphSeries[seriesID] = Array(points.suffix(cfg.maxPoints))
            }
        case .list(let cfg):
            if listItems.count > cfg.maxItems {
                listItems.removeFirst(listItems.count - cfg.maxItems)
            }
        case .table(let cfg):
            if tableRows.count > cfg.maxRows {
                tableRows.removeFirst(tableRows.count - cfg.maxRows)
            }
        case .hex(let cfg):
            if let h = hex, h.bytes.count > cfg.maxBytes {
                let drop = h.bytes.count - cfg.maxBytes
                hex = WidgetHexState(
                    bytes: h.bytes.suffix(cfg.maxBytes),
                    baseAddress: h.baseAddress &+ UInt64(drop)
                )
            }
        case .console(let cfg):
            if consoleEntries.count > cfg.maxEntries {
                consoleEntries.removeFirst(consoleEntries.count - cfg.maxEntries)
            }
        case .view:
            break
        }
    }

    var wireJSON: [String: Any] {
        let updates = rebuildingUpdates.map(\.wireJSON)
        var obj: [String: Any] = [
            "points": updates.compactMap { $0["point"] },
            "items": updates.compactMap { $0["item"] },
            "rows": updates.compactMap { $0["row"] },
            "buckets": updates.compactMap { $0["buckets"] }.first ?? [Any](),
            "entries": updates.compactMap { $0["entry"] },
        ]
        obj["counter"] = updates.compactMap { $0["counter"] }.first
        obj["hex"] = updates.compactMap { $0["hex"] }.first
        return obj
    }

    public var rebuildingUpdates: [WidgetUpdate.Kind] {
        var updates: [WidgetUpdate.Kind] = []
        if let counter {
            updates.append(.counterSet(counter))
        }
        if !histogram.isEmpty {
            updates.append(.histogramSet(histogram))
        }
        for series in graphSeries.keys.sorted() {
            updates += graphSeries[series]!.map(WidgetUpdate.Kind.graphPoint)
        }
        updates += listItems.map(WidgetUpdate.Kind.listUpsert)
        updates += tableRows.map(WidgetUpdate.Kind.tableUpsert)
        if let hex {
            updates.append(.hexSet(hex))
        }
        updates += consoleEntries.map(WidgetUpdate.Kind.consoleAppend)
        return updates
    }
}
