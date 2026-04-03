import Frida
import SwiftData
import SwiftUI
import SwiftyR2

struct ITraceDetailView: View {
    let capture: ITraceCapture
    @Bindable var session: ProcessSession
    @ObservedObject var workspace: Workspace
    @Binding var selection: SidebarItemID?

    @State private var decoded: DecodedITrace?
    @State private var r2: R2Core?
    @State private var disasmCache: [UInt64: AttributedString] = [:]
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var selectedEntryIndex: Int?
    @State private var selectedCallIndex: Int?
    @State private var callChangeFromTimeline = false
    @State private var showRegisters = true
    @State private var cfgGraph: CFGGraph?
    @State private var cfgSelectedNodeKey: CFGGraph.NodeKey?
    @State private var cfgWindowRange: Range<Int> = 0..<0
    @State private var showDiffPicker = false
    @State private var diffTarget: ITraceCapture?

    @FocusState private var isFocused: Bool

    @Environment(\.colorScheme) private var colorScheme

    private var node: ProcessNode? {
        workspace.processNodes.first { $0.sessionRecord == session }
    }

    var body: some View {
        VStack(spacing: 0) {
            if node == nil {
                SessionDetachedBanner(session: session, workspace: workspace)
            }

            header
            Divider()

            if isLoading {
                ProgressView("Decoding trace…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorText {
                Text(errorText)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.red)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if let decoded {
                VStack(spacing: 0) {
                    if !decoded.functionCalls.isEmpty {
                        ITraceTimeline(
                            functionCalls: decoded.functionCalls,
                            totalEntryCount: decoded.entries.count,
                            selectedCallIndex: Binding(
                                get: { selectedCallIndex },
                                set: { newValue in
                                    callChangeFromTimeline = true
                                    selectedCallIndex = newValue
                                }
                            )
                        )
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .onChange(of: selectedCallIndex) { _, newIdx in
                            if callChangeFromTimeline {
                                syncEntrySelectionFromCall(newIdx, decoded: decoded)
                                callChangeFromTimeline = false
                            }
                            rebuildCFGIfNeeded(decoded: decoded)
                        }
                    }

                    if let cfgGraph {
                        ITraceCFGView(
                            graph: cfgGraph,
                            currentSection: selectedCallIndex ?? 0,
                            blockBytes: decoded.blockBytes,
                            disasmProvider: r2.map { r2 in
                                { addr, size in
                                    await r2.config.set("asm.flags", bool: false)
                                    let result = await r2.cmd("pD \(size) @ 0x\(String(addr, radix: 16))")
                                    await r2.config.set("asm.flags", bool: true)
                                    return result
                                }
                            },
                            selectedNodeKey: $cfgSelectedNodeKey,
                            onNavigateFunction: { direction in
                                let newIdx = (selectedCallIndex ?? 0) + direction
                                guard newIdx >= 0, newIdx < decoded.functionCalls.count else { return }
                                selectedCallIndex = newIdx
                            },
                            onJumpToFunction: { index in
                                let target = index < 0 ? decoded.functionCalls.count - 1 : index
                                guard target >= 0, target < decoded.functionCalls.count else { return }
                                selectedCallIndex = target
                            }
                        )
                    }
                }
            }
        }
        .onAppear { decodeTrace() }
        .task(id: colorScheme) {
            guard let r2 else { return }
            let theme = (colorScheme == .light) ? "iaito" : "default"
            await r2.applyTheme(theme)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(capture.displayName)
                    .font(.headline)
                HStack(spacing: 12) {
                    if let decoded {
                        Text("\(decoded.entries.count) blocks")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if capture.lost > 0 {
                        Text("\(capture.lost) records lost")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    Text(capture.capturedAt.formatted(date: .abbreviated, time: .standard))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button("Compare…") {
                showDiffPicker = true
            }
            .disabled(otherCapturesForSameHook.isEmpty)
            .popover(isPresented: $showDiffPicker) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Compare with:")
                        .font(.headline)
                    List(otherCapturesForSameHook) { other in
                        Button(other.displayName) {
                            diffTarget = other
                            showDiffPicker = false
                        }
                    }
                    .frame(minWidth: 250, minHeight: 150)
                }
                .padding(12)
            }
            .sheet(item: $diffTarget) { target in
                diffSheet(with: target)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func instructionList(_ decoded: DecodedITrace) -> some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(decoded.entries.enumerated()), id: \.offset) { index, entry in
                        ITraceEntryRow(
                            entry: entry,
                            disasm: disasmCache[entry.blockAddress],
                            isSelected: selectedEntryIndex == index
                        )
                        .id(index)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedEntryIndex = index
                            isFocused = true
                        }
                        .onAppear {
                            fetchDisasmIfNeeded(for: entry)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
            .focusable(true)
            .focused($isFocused)
            .focusEffectDisabled(true)
            .textSelection(.disabled)
            .contentShape(Rectangle())
            .onTapGesture {
                isFocused = true
            }
            .onKeyPress(.upArrow) {
                moveSelection(-1, scrollProxy: scrollProxy)
                return .handled
            }
            .onKeyPress(.downArrow) {
                moveSelection(1, scrollProxy: scrollProxy)
                return .handled
            }
            .onKeyPress("k") {
                moveSelection(-1, scrollProxy: scrollProxy)
                return .handled
            }
            .onKeyPress("j") {
                moveSelection(1, scrollProxy: scrollProxy)
                return .handled
            }
            .onKeyPress(.home) {
                jumpTo(0, scrollProxy: scrollProxy)
                return .handled
            }
            .onKeyPress(.end) {
                jumpTo(decoded.entries.count - 1, scrollProxy: scrollProxy)
                return .handled
            }
            .onKeyPress(.pageUp) {
                moveSelection(-20, scrollProxy: scrollProxy)
                return .handled
            }
            .onKeyPress(.pageDown) {
                moveSelection(20, scrollProxy: scrollProxy)
                return .handled
            }
            .onChange(of: selectedEntryIndex) { _, newIdx in
                syncCallSelectionFromEntry(newIdx, decoded: decoded)
                if let newIdx {
                    withAnimation {
                        scrollProxy.scrollTo(newIdx, anchor: .center)
                    }
                }
            }
        }
    }

    private func jumpTo(_ index: Int, scrollProxy: ScrollViewProxy) {
        guard let decoded, !decoded.entries.isEmpty else { return }
        let clamped = max(0, min(decoded.entries.count - 1, index))
        selectedEntryIndex = clamped
        scrollProxy.scrollTo(clamped, anchor: .center)
    }

    private func moveSelection(_ delta: Int, scrollProxy: ScrollViewProxy) {
        guard let decoded else { return }
        let current = selectedEntryIndex ?? 0
        let next = max(0, min(decoded.entries.count - 1, current + delta))
        selectedEntryIndex = next
        scrollProxy.scrollTo(next, anchor: .center)
    }

    private func registerPanel(_ entry: TraceEntry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                Text("Registers")
                    .font(.headline)
                    .padding(.bottom, 4)

                ForEach(Array(entry.registerWrites.enumerated()), id: \.offset) { _, write in
                    HStack {
                        Text(write.registerName)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 50, alignment: .trailing)
                        Text(String(format: "0x%llx", write.value))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(12)
        }
        .frame(minWidth: 200, idealWidth: 250, maxWidth: 300)
    }

    private var otherCapturesForSameHook: [ITraceCapture] {
        session.itraceCaptures
            .filter { $0.hookID == capture.hookID && $0.id != capture.id }
            .sorted(by: { $0.capturedAt < $1.capturedAt })
    }

    @ViewBuilder
    private func diffSheet(with target: ITraceCapture) -> some View {
        if let left = decoded,
            var right = try? ITraceDecoder.decode(
                traceData: target.traceData, metadataJSON: target.metadataJSON)
        {
            let _ = applySymbolicatedNames(from: left, to: &right)
            ITraceDiffView(
                left: left,
                right: right,
                leftName: capture.displayName,
                rightName: target.displayName
            )
            .frame(minWidth: 700, minHeight: 500)
        } else {
            Text("Failed to decode one or both traces.")
                .padding()
        }
    }

    private func applySymbolicatedNames(from source: DecodedITrace, to target: inout DecodedITrace) {
        var nameByAddress: [UInt64: String] = [:]
        for entry in source.entries {
            nameByAddress[entry.blockAddress] = entry.blockName
        }
        for i in target.entries.indices {
            if let name = nameByAddress[target.entries[i].blockAddress] {
                target.entries[i].blockName = name
            }
        }
    }

    private func decodeTrace() {
        isLoading = true
        errorText = nil

        Task { @MainActor in
            defer { isLoading = false }

            do {
                var result = try ITraceDecoder.decode(
                    traceData: capture.traceData,
                    metadataJSON: capture.metadataJSON
                )

                if let node {
                    let didUpdate = await symbolicateAll(&result, using: node)
                    if didUpdate {
                        persistSymbolicatedNames(result)
                    }
                }

                let r2 = await setupR2(blockBytes: result.blockBytes)
                await registerR2Flags(r2, from: result)
                self.r2 = r2

                decoded = result

                if !result.functionCalls.isEmpty {
                    selectedCallIndex = 0
                }
                if !result.entries.isEmpty {
                    selectedEntryIndex = 0
                }

                rebuildCFG(decoded: result)
            } catch {
                errorText = "Failed to decode trace: \(error.localizedDescription)"
            }
        }
    }

    private func setupR2(blockBytes: [UInt64: Data]) async -> R2Core {
        let r2 = await R2Core.create()

        let provider = ITraceIOProvider(blockBytes: blockBytes, processNode: node)
        await r2.registerIOPlugin(asyncProvider: provider, uriSchemes: ["itrace://"])

        await r2.setColorLimit(.mode16M)

        await r2.config.set("scr.utf8", bool: true)
        await r2.config.set("scr.color", colorMode: .mode16M)
        await r2.config.set("cfg.json.num", string: "hex")
        await r2.config.set("asm.lines", bool: false)
        await r2.config.set("asm.emu", bool: true)
        await r2.config.set("emu.str", bool: true)

        let info = session.processInfo!
        await r2.config.set("asm.os", string: info.platform)
        await r2.config.set("asm.arch", string: ProcessNode.r2Arch(fromFridaArch: info.arch))
        await r2.config.set("asm.bits", int: info.pointerSize * 8)
        await r2.config.set("anal.cc", string: "cdecl")

        let uri = "itrace://0x0"
        await r2.openFile(uri: uri)
        await r2.cmd("=!")
        await r2.binLoad(uri: uri)

        let theme = (colorScheme == .light) ? "iaito" : "default"
        await r2.applyTheme(theme)

        return r2
    }

    private func registerR2Flags(_ r2: R2Core, from trace: DecodedITrace) async {
        var seen = Set<UInt64>()
        var usedNames = Set<String>()

        for entry in trace.entries {
            guard seen.insert(entry.blockAddress).inserted else { continue }
            guard let bangIdx = entry.blockName.firstIndex(of: "!") else { continue }

            var symbol = String(entry.blockName[entry.blockName.index(after: bangIdx)...])
            symbol = symbol.replacingOccurrences(of: "0x", with: "")
            var name = sanitizeR2FlagName(symbol)
            guard !name.isEmpty else { continue }

            if usedNames.contains(name) {
                var i = 2
                while usedNames.contains("\(name)_\(i)") { i += 1 }
                name = "\(name)_\(i)"
            }
            usedNames.insert(name)

            _ = await r2.cmd("f \(name) @ 0x\(String(entry.blockAddress, radix: 16))")
        }
    }

    private func sanitizeR2FlagName(_ name: String) -> String {
        var result = ""
        for ch in name {
            if ch.isLetter || ch.isNumber || ch == "_" || ch == "." {
                result.append(ch)
            } else {
                result.append("_")
            }
        }
        return result
    }

    private func fetchDisasmIfNeeded(for entry: TraceEntry) {
        guard disasmCache[entry.blockAddress] == nil, let r2 else { return }

        Task { @MainActor in
            let addr = String(entry.blockAddress, radix: 16)
            let size = decoded?.blockBytes[entry.blockAddress]?.count ?? entry.blockSize
            var raw = await r2.cmd("pD \(size) @ 0x\(addr)")
            while raw.hasSuffix("\n") { raw.removeLast() }
            let attributed = (try? parseAnsi(raw)) ?? AttributedString(raw)
            disasmCache[entry.blockAddress] = attributed
        }
    }

    @discardableResult
    private func symbolicateAll(_ trace: inout DecodedITrace, using node: ProcessNode) async -> Bool {
        let uniqueAddresses = Array(Set(trace.entries.map(\.blockAddress)))
        guard !uniqueAddresses.isEmpty else { return false }

        guard let results = try? await node.symbolicate(addresses: uniqueAddresses) else { return false }

        var nameByAddress: [UInt64: String] = [:]
        for (address, result) in zip(uniqueAddresses, results) {
            let name: String?
            switch result {
            case .module(let moduleName, let n):
                name = "\(moduleName)!\(n)"
            case .file(let moduleName, let n, _, _):
                name = "\(moduleName)!\(n)"
            case .fileColumn(let moduleName, let n, _, _, _):
                name = "\(moduleName)!\(n)"
            case .failure:
                name = nil
            }
            if let name {
                nameByAddress[address] = name
            }
        }

        var didUpdate = false
        for i in trace.entries.indices {
            if let name = nameByAddress[trace.entries[i].blockAddress],
                name != trace.entries[i].blockName
            {
                trace.entries[i].blockName = name
                didUpdate = true
            }
        }

        return didUpdate
    }

    private func persistSymbolicatedNames(_ trace: DecodedITrace) {
        guard var metadata = try? JSONDecoder().decode(ITraceMetadata.self, from: capture.metadataJSON) else { return }

        var nameByAddress: [String: String] = [:]
        for entry in trace.entries {
            nameByAddress[String(format: "0x%llx", entry.blockAddress)] = entry.blockName
        }

        var didChange = false
        for i in metadata.blocks.indices {
            if let name = nameByAddress[metadata.blocks[i].address], name != metadata.blocks[i].name {
                metadata.blocks[i].name = name
                didChange = true
            }
        }

        if didChange, let data = try? JSONEncoder().encode(metadata) {
            capture.metadataJSON = data
        }
    }

    private func syncEntrySelectionFromCall(_ callIdx: Int?, decoded: DecodedITrace) {
        guard let callIdx, callIdx < decoded.functionCalls.count else { return }
        let call = decoded.functionCalls[callIdx]
        selectedEntryIndex = call.startIndex
        cfgSelectedNodeKey = CFGGraph.nodeKey(address: decoded.entries[call.startIndex].blockAddress, section: callIdx)
    }

    private func syncCallSelectionFromEntry(_ entryIdx: Int?, decoded: DecodedITrace) {
        guard let entryIdx else { return }
        for (i, call) in decoded.functionCalls.enumerated() {
            if entryIdx >= call.startIndex && entryIdx < call.endIndex {
                if selectedCallIndex != i {
                    selectedCallIndex = i
                }
                return
            }
        }
    }

    private func rebuildCFGIfNeeded(decoded: DecodedITrace) {
        guard let callIdx = selectedCallIndex else { return }
        // Rebuild if the current selection is within 3 of the window edge,
        // or if no graph exists yet.
        let margin = 3
        if cfgGraph != nil
            && callIdx >= cfgWindowRange.lowerBound + margin
            && callIdx < cfgWindowRange.upperBound - margin
        {
            return
        }
        rebuildCFG(decoded: decoded)
    }

    private func rebuildCFG(decoded: DecodedITrace) {
        guard let callIdx = selectedCallIndex,
            callIdx < decoded.functionCalls.count
        else {
            cfgGraph = nil
            return
        }

        let calls = decoded.functionCalls
        let windowSize = 10
        let lo = max(0, callIdx - windowSize)
        let hi = min(calls.count, callIdx + windowSize + 1)

        cfgWindowRange = lo..<hi

        var sections: [(entries: ArraySlice<TraceEntry>, section: Int)] = []
        for i in lo..<hi {
            let entries = decoded.entries[calls[i].startIndex..<calls[i].endIndex]
            sections.append((entries: entries, section: i))
        }

        cfgGraph = CFGGraph.buildAllFunctions(sections: sections, currentSection: callIdx)
    }
}

private struct ITraceEntryRow: View {
    let entry: TraceEntry
    let disasm: AttributedString?
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let disasm {
                Text(disasm)
                    .font(.system(.caption, design: .monospaced))
            } else {
                Text("…")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
    }
}
