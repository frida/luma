import Foundation
@testable import LumaCore
import SwiftyPharo
import Observation

@MainActor
func configs(engine: Engine, pid: UInt) async throws {
    let device = await engine.deviceManager.currentDevices().first { $0.id == "local" }!
    let process = try await device.enumerateProcesses(pids: [pid], scope: .full).first!
    let session = engine.prepareAttachSession(device: device, process: process)
    _ = try await engine.attach(device: device, process: process, session: session)
    let added = await engine.addTracerHook(
        sessionID: session.id, address: 0, kind: .function,
        preferredAnchor: .moduleExport(name: "LabTarget", export: "luma_target_score"), preferredDisplayName: "luma_target_score")!
    var tracer = try engine.store.fetchInstrument(id: added.instrumentID)!
    var config = try TracerConfig.decode(from: tracer.configJSON)
    config.hooks[0].itraceArming = ITraceArming(maxInvocations: 3, maxBytesPerInvocation: 4096)
    config.threadTraces = [.init(threadID: 7, threadName: "main")]
    await engine.applyInstrumentConfig(tracer, configJSON: config.encode())
    let share = CodeShareConfig(
        name: "Check", description: "A check", source: "", exports: [], project: CodeShareProjectRef(id: "1", owner: "lab", slug: "check"),
        lastSyncedHash: "abc", fridaVersion: "17.0.0")
    let codeShare = await engine.addInstrument(kind: .codeShare, sourceIdentifier: "lab/check", configJSON: try JSONEncoder().encode(share), sessionID: session.id)!
    try await waitFor("the tracer's config to be saved") { (try? TracerConfig.decode(from: engine.store.fetchInstrument(id: tracer.id)!.configJSON))?.threadTraces.count == 1 }
    tracer = try engine.store.fetchInstrument(id: tracer.id)!
    let text = String(decoding: tracer.configJSON, as: UTF8.self) + String(decoding: codeShare.configJSON, as: UTF8.self)
    expect(["display_name", "address_anchor", "itrace_arming", "max_invocations", "max_bytes_per_invocation", "last_edited_at", "thread_traces", "thread_id",
            "thread_name", "last_synced_hash", "frida_version", "allow_remote_updates"].allSatisfy { text.contains("\"\($0)\"") }
        && !["displayName", "itraceArming", "threadTraces", "lastSyncedHash", "allowRemoteUpdates"].contains { text.contains("\"\($0)\"") },
        "the tracer's and Code Share's config are stored in snake case at every depth: \(text.prefix(400))")

    let project = URL(fileURLWithPath: CommandLine.arguments[2])
    let reopened = try await makeEngine(at: project)
    let again = try TracerConfig.decode(from: reopened.store.fetchInstrument(id: tracer.id)!.configJSON)
    let shareAgain = try CodeShareConfig.decode(from: reopened.store.fetchInstrument(id: codeShare.id)!.configJSON)
    expect(again == (try TracerConfig.decode(from: tracer.configJSON)) && again.hooks[0].itraceArming?.maxInvocations == 3 && shareAgain == share,
        "a project holding tracer hooks and a Code Share instance reopens with both configs whole")

    let old = project.deletingLastPathComponent().appendingPathComponent("configs-old", isDirectory: true)
    try? FileManager.default.removeItem(at: old)
    try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
    let sqlite = { (arguments: [String]) in
        let tool = Process()
        tool.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        tool.arguments = arguments
        try tool.run()
        tool.waitUntilExit()
    }
    try sqlite([project.appendingPathComponent("db.sqlite").path, ".backup '\(old.appendingPathComponent("db.sqlite").path)'"])
    let camel = String(decoding: tracer.configJSON, as: UTF8.self).replacingOccurrences(of: "display_name", with: "displayName")
    let hex = Data(camel.utf8).map { String(format: "%02x", $0) }.joined()
    let blob = tracer.id.uuidString.replacingOccurrences(of: "-", with: "")
    try sqlite([old.appendingPathComponent("db.sqlite").path, "UPDATE instrument_instance SET config_json = X'\(hex)' WHERE hex(id) = '\(blob)';"])
    var refusal = ""
    do {
        _ = try ProjectStore(path: old.appendingPathComponent("db.sqlite").path)
    } catch {
        refusal = error.localizedDescription
    }
    expect(refusal == ProjectStoreError.savedByDevelopmentBuild.localizedDescription,
        "a development project holding a tracer config with the old keys is refused at open, with the explained message: \(refusal)")

    let anchors: [AddressAnchor] = [
        .absolute(0x1000), .moduleOffset(name: "libfoo.dylib", offset: 1120), .moduleExport(name: "libc.dylib", export: "open"),
        .objcMethod(selector: "-[NSObject init]"), .swiftFunc(module: "M", function: "f()"), .debugSymbol(name: "main"),
        .javaMethod(className: "com.example.A", methodName: "b"),
    ]
    let encoded = try anchors.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
    let roundTripped = try encoded.map { try JSONDecoder().decode(AddressAnchor.self, from: Data($0.utf8)) }
    let tooled = try anchors.map { try AddressAnchor(toolJSON: $0.toolJSON) }
    expect(roundTripped == anchors && tooled == anchors
        && encoded[0] == "{\"absolute\":{\"address\":\"0x1000\"}}" && encoded[6].contains("\"java_method\"") && encoded[6].contains("\"class_name\"")
        && anchors[6].toolJSON["type"] as? String == "java_method" && anchors[0].toolJSON["address"] as? String == "0x1000",
        "anchors are snake case in the store and on the wire, and in the tools' own form: \(encoded)")
    let oldSpellings = ["{\"moduleOffset\":{\"name\":\"a\",\"offset\":1}}", "{\"absolute\":{\"_0\":1}}",
                        "{\"java_method\":{\"className\":\"a\",\"methodName\":\"b\"}}", "{\"absolute\":{\"address\":1,\"extra\":2}}"]
    expect(oldSpellings.allSatisfy { (try? JSONDecoder().decode(AddressAnchor.self, from: Data($0.utf8))) == nil }
        && (try? AddressAnchor(toolJSON: ["type": "moduleOffset", "name": "a", "offset": 1])) == nil,
        "and nothing accepts the old spellings")
    let storedConfig = String(decoding: tracer.configJSON, as: UTF8.self)
    expect(storedConfig.contains("\"module_export\"") && !storedConfig.contains("moduleExport"), "a tracer hook's stored anchor has the new shape: \(storedConfig.prefix(300))")
    let oldAnchor = String(decoding: tracer.configJSON, as: UTF8.self).replacingOccurrences(of: "module_export", with: "moduleExport")
    try sqlite([project.appendingPathComponent("db.sqlite").path, ".backup '\(old.appendingPathComponent("db.sqlite").path)'"])
    let anchorHex = Data(oldAnchor.utf8).map { String(format: "%02x", $0) }.joined()
    try sqlite([old.appendingPathComponent("db.sqlite").path, "UPDATE instrument_instance SET config_json = X'\(anchorHex)' WHERE hex(id) = '\(blob)';"])
    var anchorRefusal = ""
    do {
        _ = try ProjectStore(path: old.appendingPathComponent("db.sqlite").path)
    } catch {
        anchorRefusal = error.localizedDescription
    }
    expect(anchorRefusal == ProjectStoreError.savedByDevelopmentBuild.localizedDescription, "a development project holding an old-shape anchor is refused at open too")

    let highs: [UInt64] = [0xffff_ffff_ffff_ffff, 0x8000_0000_0000_0000, 0x7fff_ffff_ffff_ffff]
    var highInsights: [UUID] = []
    for high in highs {
        let insight = try engine.getOrCreateInsight(
            sessionID: session.id, pointer: high, kind: .memory, preferredAnchor: .moduleOffset(name: "LabTarget", offset: high & 0x7fff_ffff_ffff_ffff))
        var absolute = try engine.getOrCreateInsight(sessionID: session.id, pointer: high, kind: .disassembly, preferredAnchor: .absolute(high))
        absolute.lastResolvedAddress = high
        highInsights += [insight.id, absolute.id]
    }
    let reopenedHigh = try await makeEngine(at: project)
    let storedHigh = try reopenedHigh.store.fetchInsights(sessionID: session.id).filter { highInsights.contains($0.id) }
    let wire = storedHigh.compactMap { $0.toWireJSON() }
    let backFromWire = wire.compactMap(AddressInsight.fromWireJSON)
    let anchorsOut = Set(storedHigh.map(\.anchor))
    let expectedAnchors = Set(highs.flatMap { [AddressAnchor.moduleOffset(name: "LabTarget", offset: $0 & 0x7fff_ffff_ffff_ffff), .absolute($0)] })
    let toolBack = try storedHigh.map { try AddressAnchor(toolJSON: $0.anchor.toolJSON) }
    expect(anchorsOut == expectedAnchors && Set(backFromWire.map(\.anchor)) == expectedAnchors
        && Set(storedHigh.compactMap(\.lastResolvedAddress)) == Set(highs) && Set(backFromWire.compactMap(\.lastResolvedAddress)) == Set(highs)
        && toolBack == storedHigh.map(\.anchor)
        && wire.contains { ($0["last_resolved_address"] as? String) == "0xffffffffffffffff" },
        "absolute addresses at 0xffffffffffffffff, 0x8000000000000000 and 0x7fffffffffffffff round-trip exactly through the store, a reopen, the wire form and the tools' form")
    let refused = ["0x00", "0x0abc", "0xABC", "abc", "123", "-0x1", "0x1ffffffffffffffff", ""]
    let refusedAnchors = refused.map { "{\"absolute\":{\"address\":\"\($0)\"}}" } + ["{\"absolute\":{\"address\":4096}}"]
    var refusalText = ""
    do {
        _ = try JSONDecoder().decode(AddressAnchor.self, from: Data(refusedAnchors[0].utf8))
    } catch DecodingError.dataCorrupted(let context) {
        refusalText = context.debugDescription
    }
    expect(refused.allSatisfy { HexAddress.parse($0) == nil } && HexAddress.parse("0x0") == 0
        && refusedAnchors.allSatisfy { (try? JSONDecoder().decode(AddressAnchor.self, from: Data($0.utf8))) == nil }
        && (try? AddressAnchor(toolJSON: ["type": "absolute", "address": "0xABC"])) == nil
        && refusalText == HexAddress.refusal,
        "every non-canonical address is refused, with the text: \(refusalText)")
    let offsets = ["{\"module_offset\":{\"name\":\"m\",\"offset\":9223372036854775808}}", "{\"module_offset\":{\"name\":\"m\",\"offset\":-1}}",
                   "{\"module_offset\":{\"name\":\"m\",\"offset\":1.5}}", "{\"module_offset\":{\"name\":\"m\",\"offset\":\"0x10\"}}"]
    let offsetMax = "{\"module_offset\":{\"name\":\"m\",\"offset\":9223372036854775807}}"
    expect(offsets.allSatisfy { (try? JSONDecoder().decode(AddressAnchor.self, from: Data($0.utf8))) == nil }
        && (try? JSONDecoder().decode(AddressAnchor.self, from: Data(offsetMax.utf8))) == .moduleOffset(name: "m", offset: 0x7fff_ffff_ffff_ffff)
        && (try? AddressAnchor(toolJSON: ["type": "module_offset", "name": "m", "offset": "0x10"])) == nil
        && ModuleOffset.value(NSNumber(value: UInt64(0x8000_0000_0000_0000))) == nil && ModuleOffset.value(1.5) == nil,
        "an offset stays a number: one above 2^63 - 1, a negative, a fraction or a string is refused rather than mangled")

    try await shapes(engine: engine, session: session, project: project, old: old, sqlite: sqlite)

    for (fixture, made) in [("luma3.sqlite", "Luma 3.0.0's schema at format 6"), ("luma2.sqlite", "an older format")] {
        let source = URL(fileURLWithPath: "Fixtures/\(fixture)")
        let copy = project.deletingLastPathComponent().appendingPathComponent("earlier-\(fixture)")
        try? FileManager.default.removeItem(at: copy)
        try FileManager.default.copyItem(at: source, to: copy)
        let before = try Data(contentsOf: copy)
        var earlier = ""
        do {
            _ = try ProjectStore(path: copy.path)
        } catch {
            earlier = error.localizedDescription
        }
        expect(earlier == "This project was made with an earlier version of Luma, which Luma 4 cannot open." && (try? Data(contentsOf: copy)) == before,
            "a project of \(made) is refused with a true message, and nothing is written to it: \(earlier)")
    }
}

@MainActor
func shapes(engine: Engine, session: ProcessSession, project: URL, old: URL, sqlite: ([String]) throws -> Void) async throws {
    let styled = StyledText(spans: [StyledText.Span(text: "a", foreground: RGBColor(r: 1, g: 2, b: 3), isBold: true), StyledText.Span(text: "b")])
    let results: [REPLCell.Result] = [
        .text("hi"), .styled(styled), .js(.number(1)),
        .binary(Data([1, 2]), meta: .init(typedArray: "Uint8Array", baseAddress: 0xffff_ffff_ffff_ffff)), .binary(Data([3]), meta: nil),
    ]
    let resultTexts = try results.map(sorted)
    expect(try resultTexts == [
        #"{"text":{"text":"hi"}}"#,
        #"{"styled":{"spans":[{"bold":true,"foreground":{"b":3,"g":2,"r":1},"text":"a"},{"bold":false,"text":"b"}]}}"#,
        #"{"js":{"value":[0,1]}}"#,
        #"{"binary":{"data":"AQI=","meta":{"base_address":"0xffffffffffffffff","typed_array":"Uint8Array"}}}"#,
        #"{"binary":{"data":"Aw=="}}"#,
    ] && (try resultTexts.map { try JSONDecoder().decode(REPLCell.Result.self, from: Data($0.utf8)) }) == results,
        "a REPL result, its styled text and its binary meta have their designed shapes, and round-trip: \(resultTexts)")
    expect(refuses(REPLCell.Result.self, [
        #"{"text":{"_0":"hi"}}"#, #"{"styled":{"_0":{"spans":[]}}}"#, #"{"js":{"_0":[0,1]}}"#, #"{"binary":{"_0":"AQI="}}"#,
        #"{"binary":{"data":"AQI=","meta":{"typedArray":"Uint8Array"}}}"#, #"{"binary":{"data":"AQI=","meta":{"baseAddress":"0x10"}}}"#,
        #"{"styled":{"spans":[{"text":"a","isBold":true}]}}"#, #"{"text":{"text":"hi"},"js":{"value":[0,1]}}"#, #"{"text":{"text":"hi","extra":1}}"#,
    ]), "a REPL result in the old spelling, with two cases or with an unknown key is refused")

    let graph = try JSONDecoder().decode(PharoGraph.self, from: Data(#"{"layout":"tree","nodes":[{"label":"a"},{"label":"b"}],"edges":[{"from":0,"to":1}]}"#.utf8))
    let chart = try JSONDecoder().decode(PharoChart.self, from: Data(#"{"scaleX":"linear","scaleY":"log","titleX":"t","titleY":"n","series":[{"kind":"bar","orientation":"vertical","points":[{"label":"p","x":1,"y":2}]}]}"#.utf8))
    let snapshot = PharoSnapshot(printString: "a Graph", className: "Graph", views: [
        .init(title: "Items", methodSelector: "gtItemsFor:", content: .items(kept: [[.init(text: "x", png: Data([9]))]], total: 4), priority: 1),
        .init(title: "Text", methodSelector: "gtTextFor:", content: .text("t"), priority: 2),
        .init(title: "Graph", methodSelector: "gtGraphFor:", content: .graph(graph), priority: 3),
        .init(title: "Chart", methodSelector: "gtChartFor:", content: .chart(chart), priority: 4),
        .init(title: "Canvas", methodSelector: "gtCanvasFor:", content: .canvas(scene: 5), priority: 5),
        .init(title: "Empty", methodSelector: "gtEmptyFor:", content: .empty, priority: 6),
    ])
    let snapshotText = try sorted(snapshot)
    let contents = try snapshot.views.map { try sorted($0.content) }
    expect(try contents == [
        #"{"items":{"kept":[[{"png":"CQ==","text":"x"}]],"total":4}}"#,
        #"{"text":{"text":"t"}}"#,
        #"{"graph":{"edges":[{"from":0,"to":1}],"layout":"tree","nodes":[{"label":"a"},{"label":"b"}]}}"#,
        #"{"chart":{"scale_x":"linear","scale_y":"log","series":[{"kind":"bar","orientation":"vertical","points":[{"label":"p","x":1,"y":2}]}],"title_x":"t","title_y":"n"}}"#,
        #"{"canvas":{"scene":5}}"#,
        #"{"empty":{}}"#,
    ] && snapshotText.hasPrefix(#"{"class_name":"Graph","print_string":"a Graph","views":[{"content":"#) && snapshotText.contains(#""method_selector":"gtItemsFor:""#)
        && (try JSONDecoder().decode(PharoSnapshot.self, from: Data(snapshotText.utf8))) == snapshot
        && (try sorted(chart)).contains("scaleX"),
        "a Pharo snapshot, with items, text, a graph, a chart, a canvas and an empty view, has its designed shape and round-trips, while SwiftyPharo's own chart keeps its keys: \(contents)")
    let snapshotView = #"{"title":"T","method_selector":"m","priority":1,"content":"#
    expect(refuses(PharoSnapshot.self, [
        #"{"printString":"a","className":"A","views":[]}"#, #"{"print_string":"a","class_name":"A","views":[],"extra":1}"#,
        #"{"print_string":"a","class_name":"A","views":[{"title":"T","methodSelector":"m","priority":1,"content":{"empty":{}}}]}"#,
    ]) && refuses(PharoSnapshot.View.self, [
        snapshotView + #"{"text":{"_0":"t"}}}"#, snapshotView + #"{"graph":{"_0":{"layout":"tree","nodes":[],"edges":[]}}}}"#,
        snapshotView + #"{"chart":{"scaleX":"l","scaleY":"l","titleX":"t","titleY":"n","series":[]}}}"#, snapshotView + #"{"empty":{"x":1}}}"#,
        snapshotView + #"{"graph":{"layout":"tree","nodes":[{"label":"a","extra":1}],"edges":[]}}}"#,
    ]), "a Pharo snapshot in the old spelling, or with an unknown key at any depth, is refused")

    let hook = UUID()
    let origins: [ITrace.Origin] = [.functionCall(hookID: hook, callIndex: 2), .thread(threadID: 7, threadName: "main"), .thread(threadID: 8, threadName: nil)]
    expect(try origins.map(sorted) == [
        #"{"function_call":{"call_index":2,"hook_id":"\#(hook.uuidString)"}}"#, #"{"thread":{"thread_id":7,"thread_name":"main"}}"#, #"{"thread":{"thread_id":8}}"#,
    ] && refuses(ITrace.Origin.self, [
        #"{"functionCall":{"hookID":"\#(hook.uuidString)","callIndex":2}}"#, #"{"thread":{"threadID":7}}"#, #"{"thread":{"thread_id":7,"threadName":"m"}}"#,
    ]), "a trace's origin is snake case, and the old spelling is refused")

    let error = JSError(text: "boom", fileName: "/a.js", lineNumber: 3, columnNumber: 4, stack: "s")
    let event = RuntimeEvent(source: .repl, payload: .jsError(error))
    let wireEvent = event.toWireJSON()!
    let value = (wireEvent["payload"] as? [String: Any])?["value"] as? [String: Any] ?? [:]
    var oldEvent = wireEvent
    oldEvent["payload"] = ["kind": "js-error", "value": ["text": "boom", "fileName": "/a.js", "lineNumber": 3]]
    let back = RuntimeEvent.fromWireJSON(wireEvent)
    let raw = RuntimeEvent(source: .script, payload: .raw(message: ["type": "send"], data: [1]))
    let logPayload = raw.logPayload
    expect(Set(value.keys) == ["text", "file_name", "line_number", "column_number", "stack"]
        && { if case .jsError(let e) = back?.payload { return e.fileName == "/a.js" && e.columnNumber == 4 } else { return false } }()
        && RuntimeEvent.fromWireJSON(oldEvent) == nil
        && logPayload["has_inline_data"] as? Bool == true && logPayload["hasInlineData"] == nil,
        "a runtime event's JavaScript error is snake case and the old spelling is refused; the event log says has_inline_data: \(value.keys.sorted())")

    let cell = REPLCell(sessionID: session.id, code: "1", result: .styled(styled))
    let binaryCell = REPLCell(sessionID: session.id, code: "2", result: results[3])
    try engine.store.save(cell)
    try engine.store.save(binaryCell)
    let trace = ITrace(sessionID: session.id, origin: origins[0], displayName: "t")
    try engine.store.save(trace)
    let entry = NotebookEntry(
        kind: .pharo, title: "e", details: "d", styledDetails: styled, pharoSnapshot: snapshot,
        binaryData: Data([1]), binaryMeta: .init(typedArray: "Uint8Array", baseAddress: 0x10), sessionID: session.id)
    try engine.store.save(entry)
    let chat = ObjectChat(
        title: "c", subject: .object(origin: .snippet(snippetID: UUID()), label: "g", source: nil, className: "Graph", printString: "a Graph", snapshot: snapshot),
        editors: [])
    try engine.store.save(chat)
    let object = ObjectChatObject(
        chatID: chat.id, objectID: "o1", name: nil, className: "Graph", printString: "a Graph", snapshot: snapshot, producedBy: nil, standsFor: nil, addedBy: nil)
    try engine.store.save(object)
    let dump = { (sql: String) -> String in
        let tool = Process()
        let pipe = Pipe()
        tool.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        tool.arguments = [project.appendingPathComponent("db.sqlite").path, sql]
        tool.standardOutput = pipe
        try! tool.run()
        tool.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
    let stored = dump("SELECT CAST(result AS TEXT) FROM repl_cell; SELECT CAST(origin AS TEXT) FROM itrace; SELECT CAST(styled_details AS TEXT), CAST(pharo_snapshot AS TEXT), CAST(binary_meta AS TEXT) FROM notebook_entry; SELECT CAST(subject AS TEXT) FROM object_chat; SELECT CAST(snapshot AS TEXT) FROM object_chat_object;")
    expect(["\"bold\"", "\"function_call\"", "\"hook_id\"", "\"print_string\"", "\"method_selector\"", "\"scale_x\"", "\"typed_array\"", "\"base_address\""].allSatisfy(stored.contains)
        && !["isBold", "functionCall", "hookID", "printString", "methodSelector", "scaleX", "typedArray", "baseAddress", "\"_0\""].contains(where: stored.contains),
        "the store keeps the new shapes for REPL results, traces, notebook entries and chat snapshots: \(stored.prefix(300))")
    let reopened = try await makeEngine(at: project)
    expect(try reopened.store.fetchREPLCell(id: cell.id)?.result == cell.result && reopened.store.fetchREPLCell(id: binaryCell.id)?.result == results[3]
        && reopened.store.fetchITraces(sessionID: session.id).first { $0.id == trace.id }?.origin == trace.origin
        && reopened.store.fetchNotebookEntry(id: entry.id).map { [$0.styledDetails == styled, $0.pharoSnapshot == snapshot, $0.binaryMeta == entry.binaryMeta] } == [true, true, true]
        && reopened.store.fetchObjectChatObjects(chatID: chat.id).first?.snapshot == snapshot,
        "and a reopened project reads them back whole")

    let notebookWire = entry.toJSON()
    var oldNotebook = notebookWire
    oldNotebook["styled_details"] = ["spans": [["text": "a", "isBold": true]]]
    var oldSnapshotNotebook = notebookWire
    oldSnapshotNotebook["pharo_snapshot"] = ["printString": "a", "className": "A", "views": []]
    let wireEntry = NotebookEntry.fromJSON(notebookWire, binaryData: [1])
    expect(wireEntry?.styledDetails == styled && wireEntry?.pharoSnapshot == snapshot
        && NotebookEntry.fromJSON(oldNotebook, binaryData: nil) == nil && NotebookEntry.fromJSON(oldSnapshotNotebook, binaryData: nil) == nil,
        "a notebook entry on the wire carries the new shapes, and one with an old styled_details or pharo_snapshot is refused whole")

    let rewrites: [(String, String)] = [
        ("UPDATE repl_cell SET result = CAST(replace(CAST(result AS TEXT), '\"bold\"', '\"isBold\"') AS BLOB)", "a REPL result with isBold"),
        ("UPDATE itrace SET origin = CAST(replace(CAST(origin AS TEXT), 'function_call', 'functionCall') AS BLOB)", "a trace origin with functionCall"),
        ("UPDATE notebook_entry SET pharo_snapshot = CAST(replace(CAST(pharo_snapshot AS TEXT), 'print_string', 'printString') AS BLOB)", "a notebook snapshot with printString"),
        ("UPDATE object_chat_object SET snapshot = CAST(replace(CAST(snapshot AS TEXT), 'scale_x', 'scaleX') AS BLOB)", "a chat object's chart with scaleX"),
    ]
    for (sql, what) in rewrites {
        try sqlite([project.appendingPathComponent("db.sqlite").path, ".backup '\(old.appendingPathComponent("db.sqlite").path)'"])
        try sqlite([old.appendingPathComponent("db.sqlite").path, sql])
        var refusal = ""
        do {
            _ = try ProjectStore(path: old.appendingPathComponent("db.sqlite").path)
        } catch {
            refusal = error.localizedDescription
        }
        expect(refusal == ProjectStoreError.savedByDevelopmentBuild.localizedDescription, "a development project holding \(what) is refused at open")
    }

    let anchorJSON = AddressAnchor.absolute(0xffff_ffff_ffff_fff0).toJSON()
    expect(anchorJSON["address"] as? String == "0xfffffffffffffff0" && (try? AddressAnchor.fromJSON(anchorJSON)) == .absolute(0xffff_ffff_ffff_fff0),
        "the agent's anchor form carries an absolute address as a hex string")
}

func sorted<Value: Encodable>(_ value: Value) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

func refuses<Value: Decodable>(_: Value.Type, _ texts: [String]) -> Bool {
    texts.allSatisfy { (try? JSONDecoder().decode(Value.self, from: Data($0.utf8))) == nil }
}

@MainActor
func edits(project: URL, pid: UInt) async throws {
    let open = { () async throws -> Engine in
        let traces = project.appendingPathComponent("traces", isDirectory: true)
        try FileManager.default.createDirectory(at: traces, withIntermediateDirectories: true)
        let store = try ProjectStore(path: project.appendingPathComponent("db.sqlite").path)
        let engine = Engine(
            store: store, blobs: try BlobStore(directory: traces), eventStore: EventStore(fileURL: project.appendingPathComponent("events.log")),
            dataDirectory: project.appendingPathComponent("data"))
        await engine.start()
        return engine
    }
    let engine = try await open()
    var counts = (edits: 0, records: 0)
    let observers = [
        NotificationCenter.default.addObserver(forName: ProjectStore.didEditNotification, object: nil, queue: .main) { note in
            if note.userInfo?["instanceID"] as? UUID == engine.store.instanceID { MainActor.assumeIsolated { counts.edits += 1 } }
        },
        NotificationCenter.default.addObserver(forName: ProjectStore.didRecordNotification, object: nil, queue: .main) { note in
            if note.userInfo?["instanceID"] as? UUID == engine.store.instanceID { MainActor.assumeIsolated { counts.records += 1 } }
        },
    ]
    let device = await engine.deviceManager.currentDevices().first { $0.id == "local" }!
    let process = try await device.enumerateProcesses(pids: [pid], scope: .full).first!
    let session = engine.prepareAttachSession(device: device, process: process)
    _ = try await engine.attach(device: device, process: process, session: session)
    let instance = try await addFloodInstrument(engine: engine, session: session, rate: 200, seconds: 60)
    try await waitFor("the flood to start") { engine.eventLog.totalReceived > 0 }
    let long = engine.widgetState(instanceID: instance.id, widget: "log").consoleEntries.first { $0.text.hasPrefix("zzz") }?.text ?? ""
    expect(long.utf8.count < DisplayTruncation.maxKeptBytes + 64 && long.hasSuffix("<truncated; 102400 bytes total>"),
        "a console entry longer than 64 KiB is cut on arrival, saying how long it was: \(long.utf8.count) bytes kept")
    try await Task.sleep(for: .seconds(2))
    counts = (0, 0)
    let streamed = Date()
    var perSecond: [Int] = []
    while Date().timeIntervalSince(streamed) < 55 {
        let before = counts.records
        try await Task.sleep(for: .seconds(1))
        perSecond.append(counts.records - before)
    }
    let received = engine.eventLog.totalReceived
    let notKept = engine.consoleEntriesNotKept(instanceID: instance.id, widget: "log") ?? ""
    expect(notKept.hasSuffix("earlier entries not kept") && engine.eventLog.notShown?.hasSuffix("earlier events not shown") == true,
        "the engine counts what it did not keep: \(notKept); \(engine.eventLog.notShown ?? "nothing")")
    expect(counts.edits == 0 && counts.records > 0 && perSecond.max()! <= 60,
        "a minute of an instrument streaming leaves the project unedited: \(counts.edits) edits, \(counts.records) records, at most \(perSecond.max()!) a second, for \(received) events")
    counts = (0, 0)
    engine.addNotebookEntry(NotebookEntry(kind: .note, title: "A note", details: "by hand"))
    try await Task.sleep(for: .seconds(1))
    expect(counts.edits == 1, "a user's edit marks the project edited once: \(counts.edits)")
    try await Task.sleep(for: .seconds(6))
    let rows = engine.widgetState(instanceID: instance.id, widget: "rows").tableRows
    await engine.shutdown()
    for observer in observers { NotificationCenter.default.removeObserver(observer) }

    let reopened = try await open()
    try await waitFor("the event log to be restored") { reopened.eventLog.totalReceived > 0 }
    let restoredRows = try reopened.store.fetchWidgetStates(instanceID: instance.id)["rows"]?.tableRows ?? []
    expect(!rows.isEmpty && restoredRows == rows && reopened.eventLog.totalReceived >= received,
        "after streaming, a reopened project holds the last widget state (\(restoredRows.first?.cells["count"] ?? "none")) and the events (\(reopened.eventLog.totalReceived) of \(received))")
}

@MainActor
func storeUpdates(scratch: URL) async throws {
    let fm = FileManager.default
    try? fm.removeItem(at: scratch)
    let library = InstrumentFolderLibrary(directory: scratch.appendingPathComponent("library", isDirectory: true))
    try fm.createDirectory(at: library.directory, withIntermediateDirectories: true)
    let installed = InstalledStoreItems(library: library)
    let manifest = { (version: String) in #"{ "name": "probe", "displayName": "Probe", "version": "\#(version)", "main": "main.ts", "engines": { "luma": ">=4.0.0" }, "luma": { "settings": [], "widgets": [] } }"# }
    let bundle = { (version: String, files: [String: String]) throws -> CustomInstrumentBundle in
        let source = scratch.appendingPathComponent("source-\(version)", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try manifest(version).write(to: source.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        for (path, content) in files {
            try content.write(to: source.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        return try InstrumentFolder(folderURL: source).customInstrument(id: UUID(), createdAt: .distantPast, updatedAt: .distantPast)
    }
    let item = { (version: String) in
        StoreItem.fromWireJSON([
            "id": "lab/probe", "kind": "instrument", "publisher": ["handle": "lab", "name": "Lab"], "slug": "probe", "name": "Probe",
            "summary": "A probe", "category": "misc", "icon": ["kind": "symbolic", "value": "antenna"], "access": ["kind": "free"],
            "version": version, "published_at": "2026-11-26T00:00:00Z",
        ])!
    }
    let main = "export const instrument: CustomInstrument = { create() { return {}; } };\n"
    let folder = installed.folderURL(for: "lab/probe")
    let names = { () -> Set<String> in Set((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []) }

    try installed.deploy(try bundle("1.0.0", ["main.ts": main, "extra.ts": "export const extra = 1;\n"]), as: item("1.0.0"))
    let first = names()
    expect(first.contains("extra.ts") && !installed.holdsLocalChanges(itemID: "lab/probe", linkedCopy: nil),
        "a fresh install holds its files and no edits of the user's own: \(first.sorted())")
    try installed.deploy(try bundle("1.1.0", ["main.ts": main + "// 1.1\n"]), as: item("1.1.0"))
    expect(!names().contains("extra.ts") && names().contains("main.ts"),
        "an update leaves only the new version's files: \(names().sorted())")

    try #"{ "name": "probe", "version": "0.9.0", "main": "agent.ts", "luma": { "widgets": "from Luma 3" } }"#
        .write(to: folder.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
    let oldFiles = ["agent.ts": "export default 3;\n", "Old.class.st": "Object subclass: #Old\n"]
    for path in names() where path != "package.json" {
        try fm.removeItem(at: folder.appendingPathComponent(path))
    }
    for (path, content) in oldFiles {
        try content.write(to: folder.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }
    let digests = oldFiles.mapValues { InstrumentFolderLink.Snapshot.digest(Data($0.utf8)) }
    let snapshot = try JSONDecoder().decode(
        InstrumentFolderLink.Snapshot.self, from: try JSONSerialization.data(withJSONObject: ["definition": "luma 3", "files": digests]))
    LumaAppState.shared.setStoreInstallation(
        StoreInstallation(itemID: "lab/probe", version: StoreVersion("0.9.0")!, snapshot: snapshot, hostCodeDigest: nil), forItemID: "lab/probe")
    installed.reconcile()
    library.reload()
    expect(library.unreadableFolders[folder.standardizedFileURL] == "probe" && !library.folders.contains { $0.folderURL.standardizedFileURL == folder.standardizedFileURL },
        "a Luma 3 install is unreadable to the library, and the library says which folder")
    expect(!installed.holdsLocalChanges(itemID: "lab/probe", linkedCopy: nil),
        "an untouched Luma 3 install holds no edits of the user's own: its files match what was installed")
    try "export default 4;\n".write(to: folder.appendingPathComponent("agent.ts"), atomically: true, encoding: .utf8)
    expect(installed.holdsLocalChanges(itemID: "lab/probe", linkedCopy: nil), "an edited Luma 3 install is seen as edited")
    try installed.deploy(try bundle("1.2.0", ["main.ts": main]), as: item("1.2.0"))
    library.reload()
    expect(names() == ["package.json", "main.ts"] || names() == ["package.json", "main.ts", "luma.d.ts"],
        "updating a Luma 3 install leaves exactly the new version's files: \(names().sorted())")
    expect(library.unreadableFolders.isEmpty && library.folders.count == 1, "and the library reads it again")
    LumaAppState.shared.setStoreInstallation(nil, forItemID: "lab/probe")
    try? fm.removeItem(at: scratch)
}
