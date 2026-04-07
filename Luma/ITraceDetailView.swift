import Frida
import LumaCore
import SwiftUI

struct ITraceDetailView: View {
    let capture: LumaCore.ITraceCaptureRecord
    let session: LumaCore.ProcessSession
    @ObservedObject var workspace: Workspace
    @Binding var selection: SidebarItemID?

    @State private var decoded: DecodedITrace?
    @State private var disassembler: TraceDisassembler?
    @State private var disasmCache: [UInt64: AttributedString] = [:]
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var selectedEntryIndex: Int?
    @State private var selectedCallIndex: Int?
    @State private var callChangeFromTimeline = false
    @State private var showRegisters = true
    @State private var cfgGraph: CFGGraph?
    @State private var cfgNodeRegisterInfo: [CFGGraph.NodeKey: NodeRegisterInfo] = [:]
    @State private var cfgSelectedNodeKey: CFGGraph.NodeKey?
    @State private var cfgWindowRange: Range<Int> = 0..<0
    @State private var showDiffPicker = false
    @State private var diffTarget: LumaCore.ITraceCaptureRecord?

    @FocusState private var isFocused: Bool

    @Environment(\.colorScheme) private var colorScheme

    private var node: LumaCore.ProcessNode? {
        workspace.engine.node(forSessionID: session.id)
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
                            nodeRegisterInfo: cfgNodeRegisterInfo,
                            registerNames: decoded.registerNames,
                            arch: session.processInfo!.arch,
                            disasmProvider: disassembler.map { d in
                                { [colorScheme] addr, size in
                                    await d.disassemble(at: addr, size: size, isDarkMode: colorScheme == .dark, withFlags: false)
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
        .onChange(of: colorScheme) { _, _ in
            disasmCache.removeAll()
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

    private var otherCapturesForSameHook: [LumaCore.ITraceCaptureRecord] {
        let captures = (try? workspace.store.fetchITraceCaptures(sessionID: session.id)) ?? []
        return captures
            .filter { $0.hookID == capture.hookID && $0.id != capture.id }
            .sorted(by: { $0.capturedAt < $1.capturedAt })
    }

    @ViewBuilder
    private func diffSheet(with target: LumaCore.ITraceCaptureRecord) -> some View {
        if let left = decoded,
            let right = try? ITraceDecoder.decode(
                traceData: target.traceData, metadataJSON: target.metadataJSON)
        {
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

    private func decodeTrace() {
        isLoading = true
        errorText = nil

        Task { @MainActor in
            defer { isLoading = false }

            do {
                let result = try ITraceDecoder.decode(
                    traceData: capture.traceData,
                    metadataJSON: capture.metadataJSON
                )

                disassembler = TraceDisassembler(
                    decoded: result,
                    processInfo: session.processInfo!,
                    liveNode: node
                )

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

    private func fetchDisasmIfNeeded(for entry: TraceEntry) {
        guard disasmCache[entry.blockAddress] == nil, let disassembler else { return }

        Task { @MainActor in
            let size = decoded?.blockBytes[entry.blockAddress]?.count ?? entry.blockSize
            let styled = await disassembler.disassemble(
                at: entry.blockAddress,
                size: size,
                isDarkMode: colorScheme == .dark
            )
            disasmCache[entry.blockAddress] = styled.attributed
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

        var infoMap: [CFGGraph.NodeKey: NodeRegisterInfo] = [:]
        for i in lo..<hi {
            let call = calls[i]
            for entryIdx in call.startIndex..<call.endIndex {
                guard entryIdx < decoded.registerStates.count else { continue }
                let key = CFGGraph.nodeKey(
                    address: decoded.entries[entryIdx].blockAddress, section: i)
                let stateBefore = entryIdx > 0
                    ? decoded.registerStates[entryIdx - 1]
                    : RegisterState(values: [:], changed: [])
                infoMap[key] = NodeRegisterInfo(
                    stateBeforeBlock: stateBefore,
                    stateAfterBlock: decoded.registerStates[entryIdx],
                    writes: decoded.entries[entryIdx].registerWrites
                )
            }
        }
        cfgNodeRegisterInfo = infoMap
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
