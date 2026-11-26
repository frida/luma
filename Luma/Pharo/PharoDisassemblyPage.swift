import LumaCore
import SwiftUI
import SwiftyPharo

struct PharoDisassemblyPage: View {
    let reference: String
    let engine: Engine
    let onSelect: (PharoObject) -> Void

    @State private var lines: [DisassemblyLine] = []
    @State private var pendingJump: UInt64?
    @State private var scope: DisassemblyScope = .span
    @State private var unreadable: String?
    @State private var isLoadingMore = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.errorPresenter) private var errorPresenter

    var body: some View {
        if let place = PharoDisassemblyReference(reference) {
            content(place)
                .task(id: "\(reference) \(engine.presence(ofSession: place.sessionID)) \(colorScheme)") {
                    await load(place)
                }
        } else {
            ContentUnavailableView("This instruction could not be read", systemImage: "square.dashed")
        }
    }

    @ViewBuilder
    private func content(_ place: PharoDisassemblyReference) -> some View {
        if engine.presence(ofSession: place.sessionID) == .unknown {
            ContentUnavailableView(
                "Not in This Project", systemImage: "square.dashed",
                description: Text("The session this instruction is in is not in this project."))
        } else if let unreadable {
            ContentUnavailableView("Memory Not Readable", systemImage: "square.dashed", description: Text(unreadable))
        } else {
            DisassemblyView(
                lines: lines,
                sessionID: place.sessionID,
                engine: engine,
                selection: Binding(get: { engine.selectedSidebarItem }, set: { engine.selectedSidebarItem = $0 }),
                onNeedMore: { loadMore(place) },
                jumpRequest: pendingJump,
                onJumpTaken: { pendingJump = nil },
                onChat: { address, chatID in
                    open { try await engine.chatColumn(chatID, aboutInstructionAt: address, in: place.sessionID) }
                },
                onActivate: { address in open { try await engine.instruction(at: address, in: place.sessionID, runtime: .shared) } })
        }
    }

    private func load(_ place: PharoDisassemblyReference) async {
        guard engine.presence(ofSession: place.sessionID) != .unknown else { return }
        if let reason = await engine.disassemblyUnavailableReason(sessionID: place.sessionID, address: place.address) {
            lines = []
            unreadable = reason
            return
        }
        let start = await engine.disassembler(forSessionID: place.sessionID)?.findFunctionStart(containing: place.address) ?? place.address
        let count = min(Int((place.address - start) / 2) + 64, 4096)
        let page = await engine.disassemblyPage(sessionID: place.sessionID, start: start, count: count, colorScheme: colorScheme)
        unreadable = nil
        lines = page.lines
        scope = page.scope
        pendingJump = place.address
    }

    private func open(_ object: @escaping @MainActor () async throws -> PharoObject) {
        Task { @MainActor in
            do {
                onSelect(try await object())
            } catch {
                errorPresenter.present("Can’t open this instruction", error.localizedDescription)
            }
        }
    }

    private func loadMore(_ place: PharoDisassemblyReference) {
        guard !isLoadingMore, scope == .span, let last = lines.last else { return }
        isLoadingMore = true
        Task { @MainActor in
            defer { isLoadingMore = false }
            lines.append(contentsOf: await engine.disassemblyLines(sessionID: place.sessionID, after: last, colorScheme: colorScheme))
        }
    }
}

extension Engine {
    func disassemblyPage(sessionID: UUID, start: UInt64, count: Int = 64, colorScheme: ColorScheme) async -> DisassemblyPage {
        guard let disassembler = disassembler(forSessionID: sessionID) else {
            return DisassemblyPage(lines: [], scope: .span)
        }
        return await disassembler.disassemblePage(
            DisassemblyRequest(address: start, count: count, appearance: colorScheme == .dark ? .dark : .light))
    }

    func disassemblyLines(sessionID: UUID, after last: DisassemblyLine, colorScheme: ColorScheme) async -> [DisassemblyLine] {
        Array(await disassemblyPage(sessionID: sessionID, start: last.address, colorScheme: colorScheme).lines.dropFirst())
    }
}
