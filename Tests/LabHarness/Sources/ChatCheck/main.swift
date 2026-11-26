import Foundation
@testable import LumaCore
import SwiftyPharo
import Observation

Task { @MainActor in
    do {
        try await run()
    } catch {
        fail("\(error)")
    }
}

RunLoop.main.run()

@MainActor
func run() async throws {
    guard Bundle.main.bundleIdentifier == "re.frida.Luma.LabHarness" else { fail("no private bundle id") }
    let arguments = CommandLine.arguments
    let mode = arguments[1]
    let projectDirectory = URL(fileURLWithPath: arguments[2], isDirectory: true)
    if mode == "probe-open" {
        do {
            _ = try ProjectStore(path: projectDirectory.appendingPathComponent("db.sqlite").path)
            note("PROBE opened")
        } catch {
            note("PROBE refused: \(error.localizedDescription)")
        }
        exit(0)
    }
    if let member = ProcessInfo.processInfo.environment["CHAT_MEMBER"] {
        try await becomeMember(member, at: projectDirectory)
    }
    let engine = try await makeEngine(at: projectDirectory)
    let provider = ScriptedProvider()
    provider.engine = engine
    engine.llmRegistry.register(provider)
    var defaults = LumaAppState.shared.missionDefaults
    defaults.providerID = "scripted"
    defaults.modelID = "scripted-1"
    LumaAppState.shared.missionDefaults = defaults
    LumaAppState.shared.objectChatRunsWithoutAsking = false
    if mode == "firstcall" {
        let conversation = engine.objectChats.openConversation()
        do {
            let column = try await engine.objectChats.column(of: conversation.id)
            note("FIRSTCALL ok \(column.className)")
        } catch {
            note("FIRSTCALL failed \(error)")
        }
        exit(0)
    }
    if mode == "teardown-cold" {
        let chats = engine.objectChats
        let chat = ObjectChat(title: "Cold", subject: .project, editors: [])
        chats.apply(ObjectChatOp(.chatUpsert(chat)))
        let before = "\(PharoRuntime.shared.state)"
        try await chats.delete(chat.id)
        try await Task.sleep(for: .milliseconds(500))
        let after = "\(PharoRuntime.shared.state)"
        expect(try engine.store.fetchObjectChats().allSatisfy { $0.id != chat.id } && before == after && after != "running",
            "deleting a chat in a project whose image was never started does not start it (\(before) -> \(after))")
        note(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
    let runtime = try await engine.pharo.started()
    let chats = engine.objectChats

    switch mode {
    case "live":
        try await live(engine: engine, provider: provider, runtime: runtime, chats: chats, pid: UInt(arguments[3])!, gstreamer: arguments[4])
    case "reopen":
        try await reopen(engine: engine, provider: provider, runtime: runtime, chats: chats, gstreamer: arguments[3])
    case "labs":
        try await labs(engine: engine, chats: chats, second: URL(fileURLWithPath: arguments[3], isDirectory: true), wireFile: arguments[4])
    case "solo":
        try await solo(engine: engine, provider: provider, runtime: runtime, chats: chats)
    case "solo-reopen":
        try await soloReopen(engine: engine, chats: chats, wireFile: arguments[3])
    case "missions":
        try await missions(engine: engine, provider: provider, second: URL(fileURLWithPath: arguments[3], isDirectory: true))
    case "removals":
        try await removals(engine: engine, provider: provider)
    case "merge":
        try await merge(engine: engine, chats: chats)
    case "children":
        try await children(engine: engine, pid: UInt(arguments[3])!)
    case "banner":
        try await banner(engine: engine, provider: provider, pid: UInt(arguments[3])!)
    case "st-probe":
        try await stProbe(runtime: runtime, file: arguments[3])
    case "dump-instrument":
        try await dumpInstrument(engine: engine, pid: UInt(arguments[3])!, folder: arguments[4], seconds: Int(arguments[5])!, output: arguments[6])
    case "silent-portal":
        try await silentPortal(port: Int(arguments[3])!)
    case "provider-errors":
        providerErrors()
    case "delete-ops":
        try await deleteOps(engine: engine, provider: provider, runtime: runtime, chats: chats)
    case "teardown":
        try await teardown(engine: engine, provider: provider, runtime: runtime, chats: chats, pid: UInt(arguments[3])!)
    case "marker":
        try await marker(engine: engine, pid: UInt(arguments[3])!, rounds: Int(arguments[4])!)
    case "batching":
        try await batching(engine: engine, pid: UInt(arguments[3])!)
    case "refusals":
        try await refusals(engine: engine)
    case "store":
        try await storeUpdates(scratch: URL(fileURLWithPath: arguments[2], isDirectory: true))
    case "edits":
        try await edits(project: URL(fileURLWithPath: arguments[2], isDirectory: true), pid: UInt(arguments[3])!)
    case "flood":
        try await flood(engine: engine, pid: UInt(arguments[3])!, rate: Int(arguments[4])!, seconds: Int(arguments[5])!)
    case "configs":
        try await configs(engine: engine, pid: UInt(arguments[3])!)
    case "files":
        try await files(engine: engine, provider: provider, pid: UInt(arguments[3])!)
    case "members":
        try await members(engine: engine, provider: provider, chats: chats, second: URL(fileURLWithPath: arguments[3], isDirectory: true))
    default:
        fail("unknown mode \(mode)")
    }
    note(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}
