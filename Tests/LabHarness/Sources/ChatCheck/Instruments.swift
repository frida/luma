import Foundation
@testable import LumaCore
import SwiftyPharo
import Observation

@MainActor
func files(engine: Engine, provider: ScriptedProvider, pid: UInt) async throws {
    let device = await engine.deviceManager.currentDevices().first { $0.id == "local" }!
    let process = try await device.enumerateProcesses(pids: [pid], scope: .full).first!
    let session = engine.prepareAttachSession(device: device, process: process)
    _ = try await engine.attach(device: device, process: process, session: session)
    let names = ["export", "bad", "badtype", "big", "full", "twice", "late", "slow", "throws", "stream", "streambig", "hex4", "three"]
    let def = engine.createCustomInstrument(name: "Files")
    try engine.writeCustomInstrumentFile(defID: def.id, path: def.entrypoint, content: fileInstrumentSource)
    var laidOut = try engine.store.fetchCustomInstrumentDef(id: def.id)!
    laidOut.widgets = [
        InstrumentWidget(id: "log", name: "Log", kind: .console(.init()), actions: names.map { .init(id: $0, name: $0) }),
        InstrumentWidget(id: "dump", name: "Dump", kind: .hex(.init(maxBytes: 8 * 1024 * 1024))),
    ]
    engine.updateCustomInstrument(laidOut)
    try await waitFor("the library to know the widgets") { engine.customInstruments.bundle(forDefID: def.id)?.def.widgets.isEmpty == false }
    await engine.awaitCustomInstrumentReload(defID: def.id)
    let descriptor = engine.descriptor(withID: "custom:\(def.id.uuidString)")!
    let instance = await engine.addInstrument(
        kind: descriptor.kind, sourceIdentifier: descriptor.sourceIdentifier, configJSON: descriptor.makeInitialConfigJSON(), sessionID: session.id)!
    try await waitFor("the instance to be live") { engine.canChoose("export", of: "log", instance: instance) && engine.canSubmitConsoleInput(of: instance) }
    let log = { engine.widgetState(instanceID: instance.id, widget: "log").consoleEntries.map(\.text) }
    let saved = URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent("saved", isDirectory: true)
    try FileManager.default.createDirectory(at: saved, withIntermediateDirectories: true)
    func press(_ action: String) async { await engine.invokeWidgetAction(instance: instance, widget: "log", action: action) }
    func waitForFiles(_ count: Int) async throws { try await waitFor("\(count) offered files") { engine.offeredFiles.count == count } }
    func save(_ file: OfferedFile) async throws -> Data {
        let url = saved.appendingPathComponent(file.name)
        try await engine.saveOfferedFile(file.id, to: url)
        return try Data(contentsOf: url)
    }
    func declineAll() { for file in engine.offeredFiles { engine.declineOfferedFile(file.id) } }

    await press("export")
    try await waitForFiles(1)
    let cube = engine.offeredFiles[0]
    expect(cube.name == "cube.obj" && cube.mediaType == "model/obj" && cube.instrumentName == "Files",
        "an action's file is offered with its name, type and the instrument's name")
    let cubeBytes = try await save(cube)
    expect(cubeBytes == Data("v 0 0 0\n".utf8) && engine.offeredFiles.isEmpty, "saving it writes the bytes where the person chose, and takes it off the queue")

    for action in ["bad", "badtype", "big", "twice"] {
        await press(action)
    }
    try await waitForFiles(1)
    try await waitFor("four refusals in the log") { log().count >= 4 }
    let refusals = log()
    expect(refusals.contains("TypeError: respond.file: \"a/b.obj\" is not a plain file name: it contains \"/\""),
        "a name with a path is refused as a TypeError: \(refusals)")
    expect(refusals.contains("TypeError: respond.file: \"obj\" is not a media type such as \"model/obj\""), "a bad media type is a TypeError")
    expect(refusals.contains("RangeError: respond.file: \"big.bin\" is 67108865 bytes; the most a file can be is 67108864 (64 MiB)"), "over 64 MiB is a RangeError")
    expect(refusals.contains("Error: respond.file: this action has already offered a file")
        && engine.offeredFiles.map(\.name) == ["one.txt"], "a second file from one action throws, and the first is offered")
    declineAll()

    await press("late")
    try await waitFor("the late offer to be refused") { log().contains("Error: respond.file: offered after onAction returned") }
    expect(engine.offeredFiles.isEmpty, "a file offered after the handler returned throws and is not offered")

    await press("throws")
    try await waitForFiles(1)
    expect(engine.offeredFiles[0].name == "thrown.txt", "a file offered before the handler throws still streams: the stream outlives the handler")
    declineAll()

    await press("full")
    try await waitForFiles(1)
    let full = try await save(engine.offeredFiles[0])
    expect(full.count == 64 * 1024 * 1024 && full.allSatisfy { $0 == 7 }, "a 64 MiB file arrives whole")

    async let slow: Void = press("slow")
    try await Task.sleep(for: .milliseconds(100))
    await press("export")
    await slow
    try await waitForFiles(2)
    expect(engine.offeredFiles.map(\.name) == ["cube.obj", "slow.txt"], "two presses in flight each offer their own file, in the order they are opened")
    declineAll()

    for _ in 0..<5 {
        await press("export")
    }
    try await waitForFiles(4)
    try await Task.sleep(for: .milliseconds(300))
    expect(engine.offeredFiles.count == 4, "at most four offers are open; a fifth is refused")
    declineAll()

    await engine.submitConsoleInput(instance: instance, widget: "log", text: "hello")
    try await waitForFiles(1)
    let typed = try await save(engine.offeredFiles[0])
    expect(typed == Data("hello".utf8), "console input can offer a file")

    let before = log().count
    await press("stream")
    try await waitForFiles(1)
    try await Task.sleep(for: .milliseconds(800))
    expect(Array(log().dropFirst(before)) == ["written 1"],
        "until the person has chosen a place, the write that fills the first 4 MiB chunk waits: \(Array(log().dropFirst(before)))")
    let streamed = try await save(engine.offeredFiles[0])
    try await waitFor("the stream to finish in the agent") { log().contains("finished") }
    expect(streamed.count == 6 * 1024 * 1024 && streamed.prefix(2 * 1024 * 1024).allSatisfy { $0 == 1 } && streamed.suffix(2 * 1024 * 1024).allSatisfy { $0 == 3 }
        && Array(log().dropFirst(before)) == ["written 1", "written 2", "written 3", "finished"],
        "a streamed file arrives byte for byte, each write acknowledged before the next")

    await press("stream")
    try await waitForFiles(1)
    engine.declineOfferedFile(engine.offeredFiles[0].id)
    try await waitFor("the cancel to reach the agent") { log().contains("stream error: Error: the file was not saved") }
    expect(engine.offeredFiles.isEmpty, "a cancel in the dialog fails the agent's pending write")

    await press("streambig")
    try await waitForFiles(1)
    let bigURL = saved.appendingPathComponent("streambig.bin")
    var refused: String?
    do {
        try await engine.saveOfferedFile(engine.offeredFiles[0].id, to: bigURL)
    } catch {
        refused = error.localizedDescription
    }
    try await waitFor("the agent to see the cap") { log().contains { $0.hasPrefix("stream error: RangeError: respond.file: the file grew past") } }
    expect(refused != nil && !FileManager.default.fileExists(atPath: bigURL.path),
        "a stream that grows past 64 MiB fails in the agent, and the partial file is removed: \(refused ?? "saved")")

    await press("hex4")
    try await waitFor("the 4 MiB hex dump") { engine.widgetState(instanceID: instance.id, widget: "dump").hex?.bytes.count == 4 * 1024 * 1024 + 1024 }
    expect(engine.widgetState(instanceID: instance.id, widget: "dump").hex!.bytes.allSatisfy { $0 == 9 },
        "the agent's send() carries a data part of 4 MiB and more to the host's Luma whole")

    provider.missionSteps = [[.tool("invoke_widget_action", ["session_id": session.id.uuidString, "instance_id": instance.id.uuidString, "widget": "log", "action": "export"])]]
    let mission = engine.startMission(goal: "Export it", providerID: "scripted", modelID: "scripted-1", tokenBudgetInput: 0, tokenBudgetOutput: 0)!
    try await waitFor("the mission to propose the action") { (try engine.store.fetchMission(id: mission.id))?.status == .awaitingApproval }
    let proposed = try engine.store.fetchMissionActions(missionID: mission.id).first!
    await engine.approveMissionAction(actionID: proposed.id)
    try await waitFor("the action's result") { (try engine.store.fetchMissionAction(id: proposed.id))?.resultJSON != nil }
    let result = try engine.store.fetchMissionAction(id: proposed.id)!.resultJSON!
    try await Task.sleep(for: .milliseconds(300))
    expect(result.contains("only a person can save") && result.contains("cube.obj") && engine.offeredFiles.isEmpty,
        "a file offered to a mission's press is dropped, with a plain note in the result: \(result)")

    await press("export")
    try await waitForFiles(1)
    let waiting = engine.offeredFiles[0]
    engine.removeNode(engine.node(forSessionID: session.id)!)
    try await waitFor("the offer to end") { engine.offeredFiles.isEmpty }
    expect(engine.lostOfferedFiles.map(\.sentence) == ["“\(waiting.name)” was not saved: the session was detached."],
        "an offered file the session takes away before it is saved tells the person why: \(engine.lostOfferedFiles.map(\.sentence))")
}

var fileInstrumentSource: String { """
const ascii = (text: string): number[] => Array.from(text, (c: string) => c.charCodeAt(0));
const sleep = (ms: number) => new Promise(resolve => setTimeout(resolve, ms));

export const instrument: CustomInstrument = {
    create(ctx) {
        const log = ctx.widget("log");
        const tell = (e: Error) => log.appendOutput(`${e.constructor.name}: ${e.message}`);
        return {
            async onAction({ action }, respond) {
                try {
                    switch (action) {
                        case "export":
                            respond.file({ name: "cube.obj", mediaType: "model/obj", bytes: ascii("v 0 0 0\\n") });
                            break;
                        case "bad":
                            respond.file({ name: "a/b.obj", mediaType: "model/obj", bytes: [1] });
                            break;
                        case "badtype":
                            respond.file({ name: "b.obj", mediaType: "obj", bytes: [1] });
                            break;
                        case "big":
                            respond.file({ name: "big.bin", mediaType: "application/octet-stream", bytes: new Uint8Array(64 * 1024 * 1024 + 1) });
                            break;
                        case "full":
                            respond.file({ name: "full.bin", mediaType: "application/octet-stream", bytes: new Uint8Array(64 * 1024 * 1024).fill(7) });
                            break;
                        case "twice":
                            respond.file({ name: "one.txt", mediaType: "text/plain", bytes: ascii("1") });
                            respond.file({ name: "two.txt", mediaType: "text/plain", bytes: ascii("2") });
                            break;
                        case "late":
                            setTimeout(() => { try { respond.file({ name: "late.txt", mediaType: "text/plain", bytes: [1] }); } catch (e) { tell(e as Error); } }, 50);
                            break;
                        case "slow":
                            await sleep(800);
                            respond.file({ name: "slow.txt", mediaType: "text/plain", bytes: ascii("slow") });
                            break;
                        case "three": {
                            const bytes = new Uint8Array(3 * 1024 * 1024);
                            for (let i = 0; i < bytes.length; i++) bytes[i] = (i * 7) % 256;
                            respond.file({ name: "three.bin", mediaType: "application/octet-stream", bytes });
                            break;
                        }
                        case "hex4":
                            ctx.widget("dump").setHex({ bytes: new Uint8Array(4 * 1024 * 1024 + 1024).fill(9).buffer });
                            break;
                        case "stream":
                        case "streambig": {
                            const out = respond.file({ name: `${action}.bin`, mediaType: "application/octet-stream" });
                            out.on("error", (e: Error) => log.appendOutput(`stream error: ${e.constructor.name}: ${e.message}`));
                            const pieces = action === "stream" ? 3 : 65;
                            const size = action === "stream" ? 2 * 1024 * 1024 : 1024 * 1024;
                            (async () => {
                                for (let i = 1; i <= pieces; i++) {
                                    await new Promise<void>((resolve, reject) =>
                                        out.write(new Uint8Array(size).fill(i), (e?: Error | null) => e ? reject(e) : resolve()));
                                    log.appendOutput(`written ${i}`);
                                }
                                out.end(() => log.appendOutput("finished"));
                            })().catch(() => {});
                            break;
                        }
                        case "throws":
                            respond.file({ name: "thrown.txt", mediaType: "text/plain", bytes: [1] });
                            throw new Error("after offering");
                    }
                } catch (e) {
                    if (action === "throws") throw e;
                    tell(e as Error);
                }
            },
            onConsoleInput({ text }, respond) {
                respond.file({ name: "typed.txt", mediaType: "text/plain", bytes: ascii(text) });
            },
        };
    },
};
""" }

@MainActor
func children(engine: Engine, pid: UInt) async throws {
    let device = await engine.deviceManager.currentDevices().first { $0.id == "local" }!
    let process = try await device.enumerateProcesses(pids: [pid], scope: .full).first!
    let session = engine.prepareAttachSession(device: device, process: process)
    _ = try await engine.attach(device: device, process: process, session: session)
    let names = ["add", "add2", "rename", "remove", "show", "addtmp", "many", "bad"]
    let def = engine.createCustomInstrument(name: "Kids")
    try engine.writeCustomInstrumentFile(defID: def.id, path: def.entrypoint, content: childrenInstrumentSource)
    var laidOut = try engine.store.fetchCustomInstrumentDef(id: def.id)!
    laidOut.widgets = [InstrumentWidget(id: "log", name: "Log", kind: .console(.init()), actions: names.map { .init(id: $0, name: $0) })]
    laidOut.children = [
        InstrumentChildTemplate(id: "bin", name: "Bins", symbol: "point.3.connected.trianglepath.dotted", widgets: [
            InstrumentWidget(id: "rows", name: "Rows", kind: .table(.init(columns: [.init(id: "name", name: "Name")], rowActions: [.init(id: "poke", name: "Poke")])),
                             persistence: .session),
            InstrumentWidget(id: "note", name: "Note", kind: .console(.init())),
        ]),
        InstrumentChildTemplate(id: "tmp", name: "Temporaries", widgets: [InstrumentWidget(id: "count", name: "Count", kind: .counter(.init()))]),
    ]
    engine.updateCustomInstrument(laidOut)
    try await waitFor("the library to know the children") { engine.customInstruments.bundle(forDefID: def.id)?.def.children.count == 2 }
    await engine.awaitCustomInstrumentReload(defID: def.id)
    let descriptor = engine.descriptor(withID: "custom:\(def.id.uuidString)")!
    var instance = await engine.addInstrument(
        kind: descriptor.kind, sourceIdentifier: descriptor.sourceIdentifier, configJSON: descriptor.makeInitialConfigJSON(), sessionID: session.id)!
    try await waitFor("the instance to be live") { engine.canChoose("add", of: "log", instance: instance) }
    let log = { engine.widgetState(instanceID: instance.id, widget: "log").consoleEntries.map(\.text) }
    func press(_ action: String) async { await engine.invokeWidgetAction(instance: instance, widget: "log", action: action) }
    let kids = { engine.children(of: instance.id) }
    let b1 = ChildRef(template: "bin", id: "b1")

    await press("add")
    try await waitFor("b1") { kids().contains { $0.ref == b1 } }
    let first = kids().first { $0.ref == b1 }!
    try await waitFor("b1's widgets") {
        !engine.widgetState(instanceID: instance.id, widget: first.widgetKey("rows")).tableRows.isEmpty
            && !engine.widgetState(instanceID: instance.id, widget: first.widgetKey("note")).consoleEntries.isEmpty
    }
    expect(first.title == "first" && first.subtitle == "GstPipeline" && first.badge == ChildBadge(text: "playing", tone: .active) && first.position == 0
        && engine.widgetState(instanceID: instance.id, widget: first.widgetKey("rows")).tableRows.map(\.id) == ["r"]
        && engine.widgetState(instanceID: instance.id, widget: "rows").tableRows.isEmpty,
        "the agent adds a child with a title, subtitle and badge, and its widgets have their own state")
    expect(engine.childTemplate("bin", of: instance)?.name == "Bins" && engine.childTemplate("bin", of: instance)?.symbol == "point.3.connected.trianglepath.dotted",
        "a child's template gives its group name and icon")

    await press("add2")
    await press("rename")
    try await waitFor("the rename") { kids().first { $0.ref == b1 }?.title == "renamed" }
    expect(kids().map(\.ref.id) == ["b1", "b2"] && kids().map(\.position) == [0, 1] && kids()[0].badge?.tone == .waiting,
        "children keep the order they were added in; an update changes the row in place")

    await engine.invokeRowAction(instance: instance, widget: first.widgetKey("rows"), action: "poke", item: "r")
    try await waitFor("the child's press") { log().contains("pressed poke on bin/b1 row r") }
    expect(true, "a press on a child's widget reaches onAction with the child")

    await press("show")
    try await waitFor("the show request") { engine.childSelectionRequest != nil }
    expect(engine.childSelectionRequest == ChildSelectionRequest(sessionID: session.id, instanceID: instance.id, child: b1),
        "respond.show asks Luma to show that child to the person who pressed")
    engine.consumeChildSelectionRequest()

    await press("remove")
    try await waitFor("b2 to go") { kids().count == 1 }
    expect(kids().map(\.ref.id) == ["b1"], "the agent removes a child")

    await press("addtmp")
    await press("many")
    try await waitFor("the cap") { log().contains { $0.hasPrefix("RangeError") } }
    expect(kids().count == 256 && log().contains("RangeError: ctx.children: the most children an instance can have is 256"),
        "an instance holds at most 256 children; the next add is a RangeError")

    await press("bad")
    try await waitFor("the unknown template") { log().contains { $0.hasPrefix("TypeError: ctx.children") } }
    expect(log().contains("TypeError: ctx.children: \"nope\" is not a kind of child this instrument declares"), "an unknown kind of child is a TypeError")

    await engine.setInstrumentState(instance, state: .disabled)
    try await waitFor("the transient children to go") { kids().count == 1 }
    expect(kids().map(\.ref) == [b1] && engine.widgetState(instanceID: instance.id, widget: first.widgetKey("rows")).tableRows.map(\.id) == ["r"],
        "with the agent down, children of a kind with saved widgets stay with their saved state, and the rest are dropped")

    instance = try engine.store.fetchInstrument(id: instance.id)!
    await engine.setInstrumentState(instance, state: .enabled)
    try await waitFor("the agent back") { engine.canChoose("add", of: "log", instance: instance) }
    try await waitFor("the restored log line") { log().contains { $0.hasPrefix("restored ") } }
    expect(log().contains("restored b1 live b1") && kids().map(\.ref) == [b1] && kids()[0].title == "renamed",
        "a re-created agent gets its saved children back in restored and as live handles to prune or keep: \(log().filter { $0.hasPrefix("restored") })")

    let typings = CustomInstrumentTypings.defScopedDeclarations(for: engine.customInstruments.def(withId: def.id)!)
    expect(typings.contains("declare interface CustomInstrumentChildMap") && typings.contains("\"bin/rows\"")
        && typings.contains("child: { template: \"bin\"; id: string }"), "the typings name each kind of child, its widgets and its actions")

    var laidOutKids = engine.customInstruments.def(withId: def.id)!
    laidOutKids.children[0].layout = InstrumentLayout(root: .row([.widget("rows", share: 2), .widget("note")]))
    let bundle = CustomInstrumentBundle(def: laidOutKids, files: engine.customInstruments.bundle(forDefID: def.id)!.files)
    let manifest = try InstrumentFolder.files(for: bundle).first { $0.path == "package.json" }!
    let text = String(decoding: manifest.content, as: UTF8.self)
    let children = text.range(of: "\"children\"")!.lowerBound
    expect(text.range(of: "\"widgets\"")!.lowerBound < children && text[children...].contains("\"layout\""),
        "the manifest writes luma.children after luma.widgets, each kind of child with its own layout: \(text[children...].prefix(600))")
    let folder = URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent("kids-folder", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for file in try InstrumentFolder.files(for: bundle) {
        let url = folder.appendingPathComponent(file.path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try file.content.write(to: url)
    }
    let reread = try InstrumentFolder(folderURL: folder).definition(id: def.id, createdAt: Date(), updatedAt: Date())
    expect(reread.children == laidOutKids.children, "and reads them back as they were")
    var wire: [String: Any] = laidOutKids.toJSON()
    expect(CustomInstrumentDef.fromJSON(wire)?.children == laidOutKids.children, "a definition with children round-trips on the wire")
    var wireChildren = wire["children"] as! [[String: Any]]
    wireChildren[0]["layout"] = ["row": [["widget": "rows"], "sents"]]
    wire["children"] = wireChildren
    expect(CustomInstrumentDef.fromJSON(wire) == nil, "a kind of child with an invalid layout refuses the whole definition on the wire")
    let broken = text.replacingOccurrences(of: "\"share\": 2 }, \"note\"]", with: "\"share\": 2 }, \"sents\"]")
    expect(broken != text, "the test breaks the child's layout")
    try Data(broken.utf8).write(to: folder.appendingPathComponent("package.json"))
    var refusal = ""
    do {
        _ = try InstrumentFolder(folderURL: folder)
    } catch {
        refusal = error.localizedDescription
    }
    expect(refusal.contains("is not the id of a widget in luma.children[0].widgets"), "a child's layout names only its own widgets: \(refusal)")

    var twice = engine.customInstruments.def(withId: def.id)!
    twice.children.append(twice.children[0])
    let problem = twice.childrenProblem
    expect(problem.map { InstrumentLayout.text(of: $0.path) } == ".luma.children[2].id" && problem?.text == "\"bin\" is already the id of another kind of child",
        "childrenProblem names a repeated kind of child with its path and text: \(String(describing: problem))")
    engine.updateCustomInstrument(twice)
    try await Task.sleep(for: .milliseconds(300))
    expect(try engine.store.fetchCustomInstrumentDef(id: def.id)!.children.count == 2, "and updateCustomInstrument refuses to save it")

    let list = InstrumentWidget(id: "items", name: nil, kind: .list(.init()))
    let stack = InstrumentLayout.stack(of: [list])
    let plain = stack.arranged(widgets: [list], width: 800, height: 2000, rowCounts: ["items": 4]).frames.values.first!.height
    let twoLine = stack.arranged(widgets: [list], width: 800, height: 2000, rowCounts: ["items": 4], subtitledRowCounts: ["items": 3]).frames.values.first!.height
    let metrics = InstrumentLayout.Metrics.standard
    expect(twoLine - plain == 3 * (metrics.twoLineRowHeight - metrics.rowHeight),
        "a list's natural height counts its rows with subtitles at the two-line row height: \(plain) and \(twoLine)")
}

var childrenInstrumentSource: String { """
const tell = (e: unknown) => `${(e as Error).constructor.name}: ${(e as Error).message}`;

export const instrument: CustomInstrument = {
    create(ctx, config, restored) {
        const bins = ctx.children("bin");
        const temps = ctx.children("tmp");
        const log = ctx.widget("log");
        log.appendOutput(`restored ${Object.keys(restored.children?.bin ?? {}).join(",")} live ${bins.ids().join(",")}`);
        return {
            onAction(action, respond) {
                if (action.child !== undefined) {
                    log.appendOutput(`pressed ${action.action} on ${action.child.template}/${action.child.id} row ${action.item}`);
                    return;
                }
                switch (action.action) {
                    case "add": {
                        const bin = bins.add("b1", { title: "first", subtitle: "GstPipeline", badge: { text: "playing", tone: "active" } });
                        bin.widget("rows").upsertRow({ id: "r", cells: { name: "x" } });
                        bin.widget("note").appendOutput("hello from b1");
                        break;
                    }
                    case "add2":
                        bins.add("b2", { title: "second" });
                        break;
                    case "rename":
                        bins.get("b1")!.update({ title: "renamed", badge: { text: "paused", tone: "waiting" } });
                        break;
                    case "remove":
                        bins.remove("b2");
                        break;
                    case "show":
                        respond.show(bins.get("b1")!);
                        break;
                    case "addtmp":
                        temps.add("t1", { title: "transient" }).widget("count").setCounter({ value: 3 });
                        break;
                    case "many":
                        try {
                            for (let i = 0; i < 300; i++) temps.add(`m${i}`, { title: `m${i}` });
                        } catch (e) {
                            log.appendOutput(tell(e));
                        }
                        break;
                    case "bad":
                        try {
                            ctx.children("nope" as any);
                        } catch (e) {
                            log.appendOutput(tell(e));
                        }
                        break;
                }
            },
        };
    },
};
""" }

@MainActor
func banner(engine: Engine, provider: ScriptedProvider, pid: UInt) async throws {
    let device = await engine.deviceManager.currentDevices().first { $0.id == "local" }!
    let second = Process()
    second.executableURL = labTarget
    let pipe = Pipe()
    second.standardOutput = pipe
    try second.run()
    let secondPID = UInt(String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))!
    var sessions: [ProcessSession] = []
    for target in [pid, secondPID] {
        let process = try await device.enumerateProcesses(pids: [target], scope: .full).first!
        let session = engine.prepareAttachSession(device: device, process: process)
        _ = try await engine.attach(device: device, process: process, session: session)
        sessions.append(session)
    }
    let def = engine.createCustomInstrument(name: "Gated")
    try engine.writeCustomInstrumentFile(defID: def.id, path: def.entrypoint, content: """
        export const instrument: CustomInstrument = {
            create(ctx) {
                ctx.children("pane").add("p1", { title: "pane" });
                return {
                    onAction() {
                        ctx.widget("log").appendOutput("pinged");
                    },
                };
            },
        };
        """)
    try engine.writeCustomInstrumentFile(defID: def.id, path: "BannerView.class.st", content: bannerSource(), by: .mission)
    var laidOut = try engine.store.fetchCustomInstrumentDef(id: def.id)!
    laidOut.widgets = [
        InstrumentWidget(id: "log", name: "Log", kind: .console(.init()), actions: [.init(id: "ping", name: "Ping")], persistence: .session),
        InstrumentWidget(id: "graph", name: "Graph", kind: .view(.init(className: "BannerView"))),
    ]
    laidOut.children = [InstrumentChildTemplate(id: "pane", name: "Panes", widgets: [
        InstrumentWidget(id: "graph", name: "Graph", kind: .view(.init(className: "BannerView"))),
    ])]
    engine.updateCustomInstrument(laidOut)
    try await waitFor("the library to know the instrument") { engine.customInstruments.bundle(forDefID: def.id)?.def.children.count == 1 }
    await engine.awaitCustomInstrumentReload(defID: def.id)
    let descriptor = engine.descriptor(withID: "custom:\(def.id.uuidString)")!
    var instances: [InstrumentInstance] = []
    for session in sessions {
        instances.append(await engine.addInstrument(
            kind: descriptor.kind, sourceIdentifier: descriptor.sourceIdentifier, configJSON: descriptor.makeInitialConfigJSON(), sessionID: session.id)!)
    }
    let views = engine.instrumentViews
    let attached = { (instance: InstrumentInstance) in
        engine.node(forSessionID: instance.sessionID)?.instruments.first { $0.id == instance.id }?.attachment == .attached
    }
    try await waitFor("both instances to be gated") { instances.allSatisfy { views.approvalWanted(byInstance: $0.id) == .mission } }
    try await Task.sleep(for: .seconds(2))
    expect(instances.allSatisfy { !attached($0) && engine.children(of: $0.id).isEmpty && !engine.canChoose("ping", of: "log", instance: $0) }
        && engine.agentState(of: instances[0]).awaitsApproval,
        "an instance with untrusted host code is gated with no view shown: its agent script is not loaded (no attachment, its create never ran)")

    provider.missionSteps = [[.tool("invoke_widget_action", ["session_id": sessions[0].id.uuidString, "instance_id": instances[0].id.uuidString, "widget": "log", "action": "ping"])]]
    let mission = engine.startMission(goal: "Ping it", providerID: "scripted", modelID: "scripted-1", tokenBudgetInput: 0, tokenBudgetOutput: 0)!
    try await waitFor("the mission to propose the press") { (try engine.store.fetchMission(id: mission.id))?.status == .awaitingApproval }
    let proposed = try engine.store.fetchMissionActions(missionID: mission.id).first!
    await engine.approveMissionAction(actionID: proposed.id)
    try await waitFor("the press's result") { (try engine.store.fetchMissionAction(id: proposed.id)).map { $0.resultJSON != nil || $0.error != nil } == true }
    let pressed = try engine.store.fetchMissionAction(id: proposed.id)!
    let pressText = (pressed.resultJSON ?? "") + (pressed.error ?? "")
    try await waitFor("the mission to go on") { (try engine.store.fetchMission(id: mission.id))?.status != .awaitingApproval }
    expect(pressText.contains("waiting for the user to allow its code to run"),
        "a mission's press on a gated instrument gets a plain result, and the mission goes on: \(pressText)")

    views.allow(instance: instances[1].id)
    try await waitFor("both agents to start") { instances.allSatisfy { attached($0) && !engine.children(of: $0.id).isEmpty } }
    expect(instances.allSatisfy { views.approvalWanted(byInstance: $0.id) == nil } && engine.canChoose("ping", of: "log", instance: instances[0]),
        "allowing one instance approves the definition's code: every instance of it here loads its agent and runs")
    await engine.invokeWidgetAction(instance: instances[0], widget: "log", action: "ping")
    try await waitFor("the ping") { engine.widgetState(instanceID: instances[0].id, widget: "log").consoleEntries.contains { $0.text == "pinged" } }

    let third = await engine.addInstrument(
        kind: descriptor.kind, sourceIdentifier: descriptor.sourceIdentifier, configJSON: descriptor.makeInitialConfigJSON(), sessionID: sessions[1].id)!
    try await waitFor("the trusted instance to run") { attached(third) }
    expect(views.approvalWanted(byInstance: third.id) == nil, "an instance of a definition whose code is trusted runs at once and asks nothing")

    try engine.writeCustomInstrumentFile(defID: def.id, path: "BannerView.class.st", content: bannerSource(), by: .mission)
    try await waitFor("the changed code to gate again") { (instances + [third]).allSatisfy { views.approvalWanted(byInstance: $0.id) == .mission } }
    try await waitFor("the agents to stop") { (instances + [third]).allSatisfy { !attached($0) } }
    expect(engine.widgetState(instanceID: instances[0].id, widget: "log").consoleEntries.contains { $0.text == "pinged" },
        "code a mission changed after approval gates every instance again: the agents stop, and saved widget state stays as it was")
    second.terminate()

    let project = URL(fileURLWithPath: CommandLine.arguments[2])
    let folder = project.appendingPathComponent("linked-folder", isDirectory: true)
    let folderBundle = engine.customInstruments.bundle(forDefID: def.id)!
    var linkedBundle = folderBundle
    linkedBundle.def.id = UUID()
    linkedBundle.def.name = "Linked"
    for file in try InstrumentFolder.files(for: linkedBundle) {
        let url = folder.appendingPathComponent(file.path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try file.content.write(to: url)
    }
    let linked = try engine.linkInstrumentFolder(at: folder)
    var received = folderBundle
    received.def.id = UUID()
    received.def.name = "Received"
    engine.collaboration.onCustomInstrumentOpReceived?(.upsert(.init(bundle: received)), CollaborationSession.UserInfo(id: "bob", name: "Bob", avatarURL: nil))
    let reopened = try await makeEngine(at: project)
    let origins = [def.id, linked.id, received.def.id].map { (engine.codeOrigin(ofCustomInstrument: $0), reopened.codeOrigin(ofCustomInstrument: $0)) }
    let stored = try reopened.store.fetchCodeOrigin(ofCustomInstrument: linked.id)
    let folderPath = folder.standardizedFileURL.path
    expect(origins.map(\.0) == [.mission, .folder(path: folderPath), .labMember(name: "Bob")] && origins.allSatisfy { $0.0 == $0.1 }
        && stored == .folder(path: folderPath),
        "the origin is a fact of the project: a fresh engine on the same project gives the same provenance for a mission-written, a folder-linked and a lab-received instrument: \(origins)")
}

func bannerSource() -> String {
    """
    "\(UUID().uuidString)"
    Class {
    \t#name : 'BannerView',
    \t#superclass : 'Object',
    \t#category : 'Banner'
    }
    """
}

@MainActor
func refusals(engine: Engine) async throws {
    engine.collaboration.keepProjectLab("lab-refusals")
    let def = engine.createCustomInstrument(name: "Refused")
    try engine.writeCustomInstrumentFile(defID: def.id, path: def.entrypoint, content: "export const instrument: CustomInstrument = { create() { return {}; } };\n")
    try await waitFor("the definition's upsert to be queued") {
        try engine.store.fetchOutboxOps(CustomInstrumentOp.self).contains { $0.defID == def.id }
    }
    for op in try engine.store.fetchOutboxOps(CustomInstrumentOp.self) where op.defID == def.id {
        engine.collaboration.handleOpRejected(["op_id": op.opID.uuidString, "reason": "upsert: too many files"])
    }
    engine.collaboration.onCustomInstrumentSnapshot?([], [:])
    try await Task.sleep(for: .milliseconds(300))
    let kept = engine.subjectsKeptFromLab.contains(LabSubject(.definition, def.id))
    expect(try engine.store.fetchCustomInstrumentDef(id: def.id) != nil && !(try engine.store.fetchCustomInstrumentFiles(defID: def.id)).isEmpty
        && kept && (try engine.store.fetchOutboxOps(CustomInstrumentOp.self)).allSatisfy { $0.defID != def.id }
        && engine.labProblems.contains { $0.reason.contains("it holds more files than the lab takes") },
        "a definition the lab turns away stays whole here, kept from the lab with the reason, and is not sent again on a resync: \(engine.labProblems.map(\.reason))")

    let entry = NotebookEntry(kind: .note, title: "Refused note", details: "")
    engine.addNotebookEntry(entry)
    try await waitFor("the entry's add to be queued") { try engine.store.fetchOutboxOps(NotebookOp.self).contains { $0.entryID == entry.id } }
    for op in try engine.store.fetchOutboxOps(NotebookOp.self) where op.entryID == entry.id {
        engine.collaboration.handleOpRejected(["op_id": op.opID.uuidString, "reason": "entry too large"])
    }
    engine.collaboration.onNotebookSnapshot?([])
    try await Task.sleep(for: .milliseconds(300))
    expect(try engine.notebookEntries.contains { $0.id == entry.id } && (try engine.store.fetchNotebookEntry(id: entry.id)) != nil
        && (try engine.store.fetchOutboxOps(NotebookOp.self)).isEmpty,
        "a notebook entry the lab turns away stays here and is not sent again")

    let big = engine.createCustomInstrument(name: "Big")
    try engine.writeCustomInstrumentFile(defID: big.id, path: big.entrypoint, content: "export const instrument: CustomInstrument = { create() { return {}; } };\n")
    for index in 0..<CustomInstrumentBundle.labMaxFiles {
        try engine.writeCustomInstrumentFile(defID: big.id, path: "part\(index).ts", content: "export const n = \(index);\n")
    }
    try await Task.sleep(for: .milliseconds(500))
    let bigKept = engine.subjectsKeptFromLab.contains(LabSubject(.definition, big.id))
    let oversized = try engine.store.fetchOutboxOps(CustomInstrumentOp.self).contains { op in
        if case .upsert(let upsert) = op { upsert.bundle.def.id == big.id && upsert.bundle.files.count > CustomInstrumentBundle.labMaxFiles } else { false }
    }
    expect(try bigKept && !oversized
        && engine.labProblems.contains { $0.reason.contains("has \(CustomInstrumentBundle.labMaxFiles + 1) files; a lab takes at most \(CustomInstrumentBundle.labMaxFiles)") },
        "an instrument over a lab's cap is never sent, and says which cap: \(engine.labProblems.last?.reason ?? "")")

    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("luma-big-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try #"{ "name": "big-folder", "displayName": "Big Folder", "version": "1.0.0", "main": "main.ts", "engines": { "luma": ">=4.0.0" }, "luma": { "settings": [], "widgets": [] } }"#
        .write(to: folder.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
    try "export const instrument: CustomInstrument = { create() { return {}; } };\n".write(to: folder.appendingPathComponent("main.ts"), atomically: true, encoding: .utf8)
    for index in 0..<300 {
        try "export const n = \(index);\n".write(to: folder.appendingPathComponent("part\(index).ts"), atomically: true, encoding: .utf8)
    }
    let linked = try engine.linkInstrumentFolder(at: folder)
    let subject = LabSubject(.definition, linked.id)
    try await Task.sleep(for: .milliseconds(300))
    let sentBig = try engine.store.fetchOutboxOps(CustomInstrumentOp.self).contains { $0.defID == linked.id }
    expect(engine.subjectsKeptFromLab.contains(subject) && !sentBig
        && engine.keptFromLabReason(subject).contains("“Big Folder” has 301 files; a lab takes at most 256")
        && engine.descriptor(withID: "custom:\(linked.id.uuidString)") != nil,
        "a folder over a lab's cap links, works here and is kept from the lab with the cap as its reason: \(engine.keptFromLabReason(subject))")
    for index in 0..<300 {
        try FileManager.default.removeItem(at: folder.appendingPathComponent("part\(index).ts"))
    }
    try engine.reloadCustomInstrumentFromFolder(defID: linked.id)
    try await waitFor("the trimmed folder to be offered to the lab") {
        try !engine.subjectsKeptFromLab.contains(subject) && engine.store.fetchOutboxOps(CustomInstrumentOp.self).contains { $0.defID == linked.id }
    }
    expect(!engine.labProblems.contains { if case .copyKeptFromLab(subject, _) = $0.concern { true } else { false } },
        "once a save brings the linked folder within the caps it is offered to the lab and its notice goes")
    try? FileManager.default.removeItem(at: folder)
}
