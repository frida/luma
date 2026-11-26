import Foundation
@testable import LumaCore
import SwiftyPharo
import Observation

@MainActor
func flood(engine: Engine, pid: UInt, rate: Int, seconds: Int) async throws {
    let device = await engine.deviceManager.currentDevices().first { $0.id == "local" }!
    let process = try await device.enumerateProcesses(pids: [pid], scope: .full).first!
    let session = engine.prepareAttachSession(device: device, process: process)
    _ = try await engine.attach(device: device, process: process, session: session)
    let instance = try await addFloodInstrument(engine: engine, session: session, rate: rate, seconds: seconds)

    var consoleUpdates = 0
    let counter = Task { @MainActor in
        for await update in engine.widgetUpdates where update.instanceID == instance.id {
            if case .consoleAppend = update.kind { consoleUpdates += 1 }
        }
    }
    var delays: [Double] = []
    let timing = Task { @MainActor in
        for await event in engine.events {
            guard case .jsValue(.object(_, let properties)) = event.payload,
                let at = properties.first(where: { if case .string("at") = $0.key { true } else { false } }),
                case .number(let sentAt) = at.value
            else { continue }
            delays.append(Date().timeIntervalSince1970 * 1000 - sentAt)
        }
    }
    var lags: [Double] = []
    let probe = Task { @MainActor in
        while !Task.isCancelled {
            let asked = Date()
            try? await Task.sleep(for: .milliseconds(10))
            lags.append(Date().timeIntervalSince(asked) * 1000 - 10)
        }
    }
    let mainThread = mach_thread_self()
    var lastCPU = threadCPU(mainThread)
    var lastAt = Date()
    let started = Date()
    var doneAt: Date?
    var caughtUpAt: Date?
    let expected = rate * seconds
    note("second\tevents_in\tconsole_in\tmain_cpu%\tlag_p50_ms\tlag_max_ms\tfootprint_mb")
    while Date().timeIntervalSince(started) < Double(seconds + 30) {
        try await Task.sleep(for: .seconds(1))
        let cpu = threadCPU(mainThread)
        let now = Date()
        let share = (cpu - lastCPU) / now.timeIntervalSince(lastAt) * 100
        lastCPU = cpu
        lastAt = now
        let sorted = lags.sorted()
        lags.removeAll()
        let p50 = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        let worst = sorted.last ?? 0
        let received = engine.eventLog.totalReceived
        note(String(format: "%d\t%d\t%d\t%.0f\t%.1f\t%.1f\t%.0f", Int(now.timeIntervalSince(started)), received, consoleUpdates, share, p50, worst, footprintMB()))
        if doneAt == nil, engine.eventLog.events.contains(where: { isDone($0) }) {
            doneAt = now
        }
        if Date().timeIntervalSince(started) > Double(seconds), caughtUpAt == nil, received >= expected + 1, consoleUpdates >= expected {
            caughtUpAt = now
            break
        }
    }
    probe.cancel()
    counter.cancel()
    timing.cancel()
    let sortedDelays = delays.sorted()
    note(String(format: "DELAY emit-to-host p50=%.1fms p99=%.1fms over %d samples",
        sortedDelays.isEmpty ? 0 : sortedDelays[sortedDelays.count / 2], sortedDelays.isEmpty ? 0 : sortedDelays[sortedDelays.count * 99 / 100], sortedDelays.count))
    let behind = caughtUpAt.map { $0.timeIntervalSince(started) - Double(seconds) } ?? -1
    note(String(format: "SUMMARY rate=%d seconds=%d expected=%d events_in=%d console_in=%d caught_up_after_end=%.1fs footprint=%.0fMB",
        rate, seconds, expected, engine.eventLog.totalReceived, consoleUpdates, behind, footprintMB()))
    expect(caughtUpAt != nil, "the host caught up with \(expected) events within 30 s of the stream's end")
}

func isDone(_ event: RuntimeEvent) -> Bool {
    guard case .jsValue(.object(_, let properties)) = event.payload else { return false }
    return properties.contains { if case .string("done") = $0.key { return true } else { return false } }
}

func threadCPU(_ thread: thread_t) -> Double {
    var info = thread_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
    _ = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
    }
    return Double(info.user_time.seconds + info.system_time.seconds) + Double(info.user_time.microseconds + info.system_time.microseconds) / 1_000_000
}

func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    _ = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return Double(info.phys_footprint) / 1_048_576
}

@MainActor
func addFloodInstrument(engine: Engine, session: ProcessSession, rate: Int, seconds: Int) async throws -> InstrumentInstance {
    let def = engine.createCustomInstrument(name: "Flood")
    try engine.writeCustomInstrumentFile(defID: def.id, path: def.entrypoint, content: """
        export const instrument: CustomInstrument = {
            create(ctx) {
                const log = ctx.widget("log");
                const table = ctx.widget("rows");
                const perTick = \(rate) / 100;
                log.appendOutput("z".repeat(100 * 1024));
                let sent = 0;
                const started = Date.now();
                const timer = setInterval(() => {
                    if (Date.now() - started > \(seconds) * 1000) {
                        clearInterval(timer);
                        ctx.emit({ done: sent });
                        return;
                    }
                    ctx.emit({ at: Date.now() });
                    for (let i = 0; i < perTick; i++) {
                        sent++;
                        ctx.emit({ seq: sent, service: "com.example.flood", message: { kind: "request", body: "x".repeat(200), list: [1, 2, 3, 4, 5] } });
                        log.appendOutput(`message ${sent} ` + "y".repeat(80));
                    }
                    table.upsertRow({ id: "svc", cells: { name: "com.example.flood", count: String(sent) } });
                }, 10);
                return { dispose() { clearInterval(timer); } };
            },
        };
        """)
    var laidOut = try engine.store.fetchCustomInstrumentDef(id: def.id)!
    laidOut.widgets = [
        InstrumentWidget(id: "log", name: "Log", kind: .console(.init(maxEntries: 500))),
        InstrumentWidget(
            id: "rows", name: "Rows", kind: .table(.init(columns: [.init(id: "name", name: "Name"), .init(id: "count", name: "Count")])),
            persistence: .session),
    ]
    engine.updateCustomInstrument(laidOut)
    try await waitFor("the library to know the instrument") { engine.customInstruments.bundle(forDefID: def.id)?.def.widgets.count == 2 }
    await engine.awaitCustomInstrumentReload(defID: def.id)
    let descriptor = engine.descriptor(withID: "custom:\(def.id.uuidString)")!
    return await engine.addInstrument(
        kind: descriptor.kind, sourceIdentifier: descriptor.sourceIdentifier, configJSON: descriptor.makeInitialConfigJSON(), sessionID: session.id)!

}

@MainActor
func batching(engine: Engine, pid: UInt) async throws {
    let device = await engine.deviceManager.currentDevices().first { $0.id == "local" }!
    let process = try await device.enumerateProcesses(pids: [pid], scope: .full).first!
    let session = engine.prepareAttachSession(device: device, process: process)
    _ = try await engine.attach(device: device, process: process, session: session)
    let def = engine.createCustomInstrument(name: "Batched")
    try engine.writeCustomInstrumentFile(defID: def.id, path: def.entrypoint, content: """
        export const instrument: CustomInstrument = {
            create(ctx) {
                const log = ctx.widget("log");
                const rows = ctx.widget("rows");
                const count = ctx.widget("count");
                const large = new Uint8Array(1024 * 1024);
                for (let i = 0; i < large.length; i++) large[i] = i & 0xff;
                ctx.widget("a").setHex({ bytes: [1, 2, 3] });
                ctx.emit({ step: 1 });
                ctx.widget("b").setHex({ bytes: [9, 8] });
                ctx.widget("empty").setHex({ bytes: [] });
                ctx.widget("large").setHex({ bytes: large.buffer });
                log.appendOutput("one");
                ctx.emit({ step: 2 });
                log.appendOutput("two");
                rows.upsertRow({ id: "r1", cells: { v: "1" } });
                rows.upsertRow({ id: "r2", cells: { v: "a" } });
                rows.upsertRow({ id: "r1", cells: { v: "2" } });
                rows.upsertRow({ id: "r3", cells: { v: "x" } });
                rows.removeRow("r3");
                rows.upsertRow({ id: "r3", cells: { v: "y" } });
                count.setCounter({ value: 1 });
                count.clear();
                count.setCounter({ value: 2 });
                const kids = ctx.children("kid");
                kids.add("x", { title: "first" }).widget("count").setCounter({ value: 1 });
                kids.remove("x");
                kids.add("x", { title: "again" }).widget("count").setCounter({ value: 7 });
                const self = (ctx as any).instanceId;
                send({ type: "instrument-batch", instance_id: self, items: [
                    { type: "widget-hex-set", instance_id: self, widget: "bad", hex: { base_address: "0x0" }, blob_offset: 100, blob_size: 5 },
                    { type: "widget-hex-set", instance_id: self, widget: "bad", hex: { base_address: "0x0" }, blob_offset: -1, blob_size: 1 },
                    { type: "widget-hex-set", instance_id: self, widget: "bad", hex: { base_address: "0x0" }, blob_offset: 0 },
                    { type: "widget-counter-set", instance_id: self, widget: "after", counter: { value: 5 } },
                ] }, null);
                return {
                    onAction() {
                        log.appendOutput("pressed");
                    },
                };
            },
        };
        """)
    var laidOut = try engine.store.fetchCustomInstrumentDef(id: def.id)!
    laidOut.widgets = [
        InstrumentWidget(id: "log", name: "Log", kind: .console(.init()), actions: [.init(id: "press", name: "Press")]),
        InstrumentWidget(id: "rows", name: "Rows", kind: .table(.init(columns: [.init(id: "v", name: "V")]))),
        InstrumentWidget(id: "count", name: "Count", kind: .counter(.init())),
        InstrumentWidget(id: "a", name: "A", kind: .hex(.init())),
        InstrumentWidget(id: "b", name: "B", kind: .hex(.init())),
        InstrumentWidget(id: "empty", name: "Empty", kind: .hex(.init())),
        InstrumentWidget(id: "large", name: "Large", kind: .hex(.init(maxBytes: 2 * 1024 * 1024))),
        InstrumentWidget(id: "bad", name: "Bad", kind: .hex(.init())),
        InstrumentWidget(id: "after", name: "After", kind: .counter(.init())),
    ]
    laidOut.children = [InstrumentChildTemplate(id: "kid", name: "Kids", widgets: [InstrumentWidget(id: "count", name: "Count", kind: .counter(.init()))])]
    engine.updateCustomInstrument(laidOut)
    try await waitFor("the library to know the instrument") { engine.customInstruments.bundle(forDefID: def.id)?.def.widgets.count == 9 }
    await engine.awaitCustomInstrumentReload(defID: def.id)
    let descriptor = engine.descriptor(withID: "custom:\(def.id.uuidString)")!
    var order: [String] = []
    let watcher = Task { @MainActor in
        for await event in engine.events {
            if case .jsValue(.object(_, let properties)) = event.payload, let step = properties.first?.value, case .number(let n) = step {
                order.append("event \(Int(n))")
            }
        }
    }
    let consoleOrder = Task { @MainActor in
        for await update in engine.widgetUpdates {
            if case .consoleAppend(let entry) = update.kind { order.append("console \(entry.text)") }
        }
    }
    let instance = await engine.addInstrument(
        kind: descriptor.kind, sourceIdentifier: descriptor.sourceIdentifier, configJSON: descriptor.makeInitialConfigJSON(), sessionID: session.id)!
    try await waitFor("the batch to arrive") { engine.widgetState(instanceID: instance.id, widget: "count").counter != nil }
    try await Task.sleep(for: .milliseconds(300))
    let state = { (widget: String) in engine.widgetState(instanceID: instance.id, widget: widget) }
    let large = state("large").hex?.bytes ?? Data()
    expect(state("a").hex?.bytes == Data([1, 2, 3]) && state("b").hex?.bytes == Data([9, 8]) && state("empty").hex?.bytes == Data()
        && large.count == 1024 * 1024 && large.enumerated().allSatisfy { $0.element == UInt8($0.offset & 0xff) },
        "binary items in one batch each get their own bytes: two small, an empty and a 1 MiB one")
    expect(order.filter { $0.hasPrefix("event") } == ["event 1", "event 2"] && order.filter { $0.hasPrefix("console") } == ["console one", "console two"],
        "events and widget calls each arrive in the order the instrument made them: \(order)")
    let rows = state("rows").tableRows.map { "\($0.id)=\($0.cells["v"] ?? "")" }
    expect(rows == ["r1=2", "r2=a", "r3=y"] && state("count").counter?.value == 2,
        "coalescing keeps the state the instrument holds: rows \(rows), counter \(state("count").counter?.value ?? -1)")
    let kid = engine.children(of: instance.id).first { $0.ref.id == "x" }
    expect(kid?.title == "again" && kid.map { state($0.widgetKey("count")).counter?.value } == 7,
        "a child removed and added again in one tick keeps the state set after it came back: \(kid?.title ?? "none"), \(kid.map { state($0.widgetKey("count")).counter?.value ?? -1 } ?? -1)")
    expect(state("bad").hex == nil && state("after").counter?.value == 5,
        "malformed batch items are dropped and the rest of the batch applies: bad \(state("bad").hex == nil ? "dropped" : "applied"), after \(state("after").counter?.value ?? -1)")
    try await waitFor("the instrument to be live") { engine.agentState(of: instance).isLive }
    await engine.invokeWidgetAction(instance: instance, widget: "log", action: "press")
    try await waitFor("the action's console entry") { state("log").consoleEntries.last?.text == "pressed" }
    expect(state("log").consoleEntries.map(\.text) == ["one", "two", "pressed"], "an action's widget updates arrive: \(state("log").consoleEntries.map(\.text))")
    watcher.cancel()
    consoleOrder.cancel()
}

@MainActor
func dumpInstrument(engine: Engine, pid: UInt, folder: String, seconds: Int, output: String) async throws {
    let device = await engine.deviceManager.currentDevices().first { $0.id == "local" }!
    let process = try await device.enumerateProcesses(pids: [pid], scope: .full).first!
    let session = engine.prepareAttachSession(device: device, process: process)
    _ = try await engine.attach(device: device, process: process, session: session)
    let def = try engine.linkInstrumentFolder(at: URL(fileURLWithPath: folder, isDirectory: true))
    await engine.awaitCustomInstrumentReload(defID: def.id)
    let descriptor = engine.descriptor(withID: "custom:\(def.id.uuidString)")!
    let instance = await engine.addInstrument(
        kind: descriptor.kind, sourceIdentifier: descriptor.sourceIdentifier, configJSON: descriptor.makeInitialConfigJSON(), sessionID: session.id)!
    try await Task.sleep(for: .seconds(2))
    engine.instrumentViews.allow(instance: instance.id)
    try await Task.sleep(for: .seconds(seconds))
    let custom = engine.customInstruments.def(withId: def.id)!
    let slots = custom.widgets.map(\.id) + engine.children(of: instance.id).flatMap { child in
        (custom.children.first { $0.id == child.ref.template }?.widgets ?? []).map { child.widgetKey($0.id) }
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    var dump: [String: String] = [:]
    for slot in slots {
        var state = engine.widgetState(instanceID: instance.id, widget: slot)
        state.revision = 0
        state.consoleEntries = state.consoleEntries.map { WidgetConsoleEntry(id: "", kind: $0.kind, text: $0.text, value: $0.value, image: $0.image, replyTo: $0.replyTo) }
        dump[slot] = String(decoding: try encoder.encode(state), as: UTF8.self)
    }
    dump["children"] = engine.children(of: instance.id).map { "\($0.ref.template)/\($0.ref.id) \($0.title) \($0.subtitle ?? "")" }.sorted().joined(separator: "\n")
    try String(decoding: try encoder.encode(dump), as: UTF8.self).write(toFile: output, atomically: true, encoding: .utf8)
    note("DUMPED \(slots.count) widgets, \(engine.children(of: instance.id).count) children, \(engine.eventLog.totalReceived) events")
    await engine.removeInstrument(instance)
}

@MainActor
func marker(engine: Engine, pid: UInt, rounds: Int) async throws {
    let device = await engine.deviceManager.currentDevices().first { $0.id == "local" }!
    let process = try await device.enumerateProcesses(pids: [pid], scope: .full).first!
    let session = engine.prepareAttachSession(device: device, process: process)
    _ = try await engine.attach(device: device, process: process, session: session)
    let def = engine.createCustomInstrument(name: "Marked")
    try engine.writeCustomInstrumentFile(defID: def.id, path: def.entrypoint, content: """
        export const instrument: CustomInstrument = {
            create(ctx) {
                const log = ctx.widget("log");
                ctx.widget("loads").setCounter({ value: Math.random() });
                const bulk = new Uint8Array(512 * 1024);
                const kids = ctx.children("kid");
                let presses = 0;
                return {
                    onAction(action, respond) {
                        presses++;
                        ctx.widget("bulk").setHex({ bytes: bulk.buffer });
                        for (let i = 0; i < 200; i++) {
                            ctx.emit({ press: presses, i });
                        }
                        log.appendOutput(`press ${presses}`);
                        respond.show(kids.add(`k${presses}`, { title: `kid ${presses}` }));
                    },
                    onConsoleInput(input, respond) {
                        respond.output(`echo ${input.text}`);
                    },
                    dispose() {
                        ctx.widget("bulk").setHex({ bytes: bulk.buffer });
                        log.appendOutput("bye");
                        kids.add("late", { title: "added while disposing" });
                    },
                };
            },
        };
        """)
    var laidOut = try engine.store.fetchCustomInstrumentDef(id: def.id)!
    laidOut.widgets = [
        InstrumentWidget(id: "log", name: "Log", kind: .console(.init()), actions: [.init(id: "press", name: "Press")]),
        InstrumentWidget(id: "bulk", name: "Bulk", kind: .hex(.init(maxBytes: 1024 * 1024))),
        InstrumentWidget(id: "loads", name: "Loads", kind: .counter(.init())),
    ]
    laidOut.children = [InstrumentChildTemplate(id: "kid", name: "Kids", widgets: [InstrumentWidget(id: "count", name: "Count", kind: .counter(.init()))])]
    engine.updateCustomInstrument(laidOut)
    try await waitFor("the library to know the instrument") { engine.customInstruments.bundle(forDefID: def.id)?.def.widgets.count == 3 }
    await engine.awaitCustomInstrumentReload(defID: def.id)
    let descriptor = engine.descriptor(withID: "custom:\(def.id.uuidString)")!
    let instance = await engine.addInstrument(
        kind: descriptor.kind, sourceIdentifier: descriptor.sourceIdentifier, configJSON: descriptor.makeInitialConfigJSON(), sessionID: session.id)!
    try await waitFor("the instrument to be live") { engine.agentState(of: instance).isLive }
    func loadMark() -> Double? { engine.widgetState(instanceID: instance.id, widget: "loads").counter?.value }
    var marks = [loadMark()]
    var lateActions = 0
    var unknownChildren = 0
    var lateReplies = 0
    for round in 1...rounds {
        await engine.invokeWidgetAction(instance: instance, widget: "log", action: "press")
        if engine.widgetState(instanceID: instance.id, widget: "log").consoleEntries.last?.text != "press \(round)" { lateActions += 1 }
        if !engine.children(of: instance.id).contains(where: { $0.ref.id == "k\(round)" }) { unknownChildren += 1 }
        let response = await engine.submitConsoleInputAndAwait(instance: instance, widget: "log", text: "r\(round)")
        if response.replies.map(\.text) != ["echo r\(round)"] { lateReplies += 1 }
    }
    expect(lateActions == 0 && unknownChildren == 0,
        "after each of \(rounds) actions the action's console entry and the child it showed are known when the call returns: \(lateActions) late entries, \(unknownChildren) unknown children")
    expect(lateReplies == 0, "each of \(rounds) console inputs returns with its reply: \(lateReplies) without")

    await engine.setInstrumentState(try engine.store.fetchInstrument(id: instance.id)!, state: .disabled)
    let afterDisable = engine.children(of: instance.id).count
    try await Task.sleep(for: .milliseconds(500))
    expect(afterDisable == 0 && engine.children(of: instance.id).isEmpty,
        "a transient child the instrument adds while it is disabled is gone once the disable returns, and stays gone: \(afterDisable), then \(engine.children(of: instance.id).count)")
    let disabled = try engine.store.fetchInstrument(id: instance.id)!
    await engine.setInstrumentState(disabled, state: .enabled)
    try await waitFor("the agent back") { engine.agentState(of: disabled).isLive }
    marks.append(loadMark())

    try engine.writeCustomInstrumentFile(
        defID: def.id, path: def.entrypoint, content: try engine.store.fetchCustomInstrumentFiles(defID: def.id)[0].content + "\n// edited\n")
    await engine.awaitCustomInstrumentReload(defID: def.id)
    try await waitFor("the edited agent") { engine.agentState(of: disabled).isLive && loadMark() != marks.last! }
    marks.append(loadMark())

    engine.removeNode(engine.node(forSessionID: session.id)!)
    _ = await engine.reestablishSession(id: session.id)
    try await waitFor("the re-attached agent") { engine.agentState(of: disabled).isLive && loadMark() != marks.last! }
    marks.append(loadMark())
    expect(marks.count == 4 && marks.allSatisfy { $0 != nil } && Set(marks.compactMap { $0 }).count == 4,
        "the state an agent writes as it loads arrives on a fresh add, an enable after a disable, a definition edit and a re-attach: \(marks)")

    await engine.removeInstrument(try engine.store.fetchInstrument(id: instance.id)!)
    let slotsAfterRemoval = engine.widgetSlots(of: instance.id).count
    try await Task.sleep(for: .milliseconds(500))
    expect(slotsAfterRemoval == 0 && engine.widgetSlots(of: instance.id).isEmpty && engine.children(of: instance.id).isEmpty,
        "what a removed instrument sends while disposing recreates none of its state: \(slotsAfterRemoval) slots, then \(engine.widgetSlots(of: instance.id).count) slots and \(engine.children(of: instance.id).count) children")
}
