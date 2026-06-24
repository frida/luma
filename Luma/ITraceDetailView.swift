import Frida
import LumaCore
import SwiftUI

struct ITraceDetailView: View {
    let trace: LumaCore.ITrace
    let session: LumaCore.ProcessSession
    let engine: Engine
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
    @State private var diffTarget: LumaCore.ITrace?

    @FocusState private var isFocused: Bool

    @Environment(\.colorScheme) private var colorScheme

    private var node: LumaCore.ProcessNode? {
        engine.node(forSessionID: session.id)
    }

    private var liveTrace: LumaCore.ITrace {
        engine.tracesBySession[session.id]?.first(where: { $0.id == trace.id }) ?? trace
    }

    @State private var lastDecodedSize: Int = -1
    @State private var redecodeTask: Task<Void, Never>?
    @State private var loadProgress: (loaded: Int, total: Int)?
    @State private var serverTotalSize: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if isLoading {
                ProgressView("Decoding trace…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if decoded == nil, liveTrace.dataSize == 0, liveTrace.isRunning {
                VStack(spacing: 8) {
                    Image(systemName: "record.circle")
                        .font(.system(size: 32))
                        .foregroundStyle(.red)
                    Text("Waiting for trace data…")
                        .foregroundStyle(.secondary)
                }
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
                            disasmProvider: disassembler.map { d in
                                { [colorScheme] addr, size in
                                    await d.disassemble(at: addr, size: size, appearance: colorScheme == .dark ? .dark : .light, withFlags: false)
                                }
                            },
                            instructionAddressesProvider: disassembler.map { d in
                                { addr, size in
                                    await d.instructionAddresses(at: addr, size: size)
                                }
                            },
                            engine: engine,
                            sessionID: session.id,
                            functionEntries: Set(decoded.functionCalls.map { decoded.entries[$0.startIndex].blockAddress }),
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
                            },
                            onNavigate: { selection = $0 }
                        )
                    } else {
                        emptyCFGState(isRecording: liveTrace.isRunning)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                emptyCFGState(isRecording: liveTrace.isRunning)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { decodeTrace() }
        .onChange(of: liveTrace.dataSize) { _, newSize in
            scheduleRedecodeIfNeeded(currentSize: newSize)
        }
        .task(id: trace.id) {
            for await invalidation in engine.traceCacheInvalidations
                where invalidation.traceID == trace.id
            {
                serverTotalSize = invalidation.knownTotalSize
                scheduleRedecodeIfNeeded(currentSize: invalidation.knownTotalSize)
            }
        }
        .onChange(of: colorScheme) { _, _ in
            disasmCache.removeAll()
        }
    }

    private func renderPrefix(snapshot: LumaCore.ITrace) async {
        do {
            let preview = try await engine.loadTraceDataPrefix(
                traceID: snapshot.id,
                sessionID: session.id,
                length: Self.firstPaintBytes
            )
            let result = try ITraceDecoder.decode(
                traceData: preview,
                metadataJSON: snapshot.metadataJSON
            )
            disassembler = TraceDisassembler(
                decoded: result,
                processInfo: session.processInfo!,
                liveNode: node
            )
            decoded = result
            isLoading = false
            rebuildCFG(decoded: result)
        } catch {
        }
    }

    private func scheduleRedecodeIfNeeded(currentSize: Int) {
        guard currentSize != lastDecodedSize else { return }
        redecodeTask?.cancel()
        redecodeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            decodeTrace()
        }
    }

    private var header: some View {
        let live = liveTrace
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(live.displayName)
                    .font(.headline)
                HStack(spacing: 12) {
                    if let decoded {
                        Text("\(decoded.entries.count) blocks")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if live.isRunning {
                        Label("recording", systemImage: "record.circle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    if live.lost > 0 {
                        Text("\(live.lost) records lost")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    if let loadProgress {
                        Text("loading \(formatBytes(loadProgress.loaded)) of \(formatBytes(loadProgress.total))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text((live.stoppedAt ?? live.startedAt).formatted(date: .abbreviated, time: .standard))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if live.isRunning, isThreadOrigin(live.origin) {
                Button {
                    Task { @MainActor in
                        await engine.stopThreadTrace(traceID: trace.id, sessionID: session.id)
                    }
                } label: {
                    Label("Stop", systemImage: "stop.circle")
                }
                .tint(.red)
            }

            Button("Compare…") {
                showDiffPicker = true
            }
            .disabled(otherTracesForSameHook.isEmpty)
            .popover(isPresented: $showDiffPicker) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Compare with:")
                        .font(.headline)
                    List(otherTracesForSameHook) { other in
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

    private func emptyCFGState(isRecording: Bool) -> some View {
        VStack(spacing: 8) {
            Image(systemName: isRecording ? "record.circle" : "square.on.square.dashed")
                .font(.system(size: 32))
                .foregroundStyle(isRecording ? .red : .secondary)
            Text(isRecording ? "Recording…" : "No control-flow data")
                .font(.headline)
            Text(isRecording
                ? "Waiting for the first executed instructions to arrive."
                : "This trace finished without capturing any executed instructions.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private var otherTracesForSameHook: [LumaCore.ITrace] {
        let traces = (try? engine.store.fetchITraces(sessionID: session.id)) ?? []
        return traces
            .filter { sameHook($0.origin, trace.origin) && $0.id != trace.id }
            .sorted(by: { $0.startedAt < $1.startedAt })
    }

    private func formatBytes(_ count: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(count))
    }

    private func isThreadOrigin(_ origin: LumaCore.ITrace.Origin) -> Bool {
        if case .thread = origin { return true }
        return false
    }

    private func sameHook(_ a: LumaCore.ITrace.Origin, _ b: LumaCore.ITrace.Origin) -> Bool {
        if case .functionCall(let aHook, _) = a, case .functionCall(let bHook, _) = b {
            return aHook == bHook
        }
        return false
    }

    @ViewBuilder
    private func diffSheet(with target: LumaCore.ITrace) -> some View {
        DiffLoader(
            engine: engine,
            sessionID: session.id,
            leftDecoded: decoded,
            target: target,
            leftName: trace.displayName,
            expectedSize: target.dataSize
        )
    }

    private static let firstPaintBytes = 256 * 1024

    private func decodeTrace() {
        let snapshot = liveTrace
        if snapshot.dataSize == 0 {
            isLoading = false
            errorText = nil
            return
        }
        let isFirstDecode = (decoded == nil)
        isLoading = isFirstDecode
        errorText = nil

        Task { @MainActor in
            if isFirstDecode, snapshot.dataSize > Self.firstPaintBytes {
                await renderPrefix(snapshot: snapshot)
            }
            defer { isLoading = false }

            do {
                let expected = max(snapshot.dataSize, serverTotalSize)
                let traceData = try await engine.loadTraceData(
                    traceID: snapshot.id,
                    sessionID: session.id,
                    expectedSize: expected,
                    onProgress: { loaded, total in
                        loadProgress = (loaded, total)
                    }
                )
                loadProgress = nil
                let result = try ITraceDecoder.decode(
                    traceData: traceData,
                    metadataJSON: snapshot.metadataJSON
                )

                disassembler = TraceDisassembler(
                    decoded: result,
                    processInfo: session.processInfo!,
                    liveNode: node
                )

                decoded = result
                lastDecodedSize = snapshot.dataSize

                if isFirstDecode {
                    if !result.functionCalls.isEmpty {
                        selectedCallIndex = 0
                    }
                    if !result.entries.isEmpty {
                        selectedEntryIndex = 0
                    }
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
                appearance: colorScheme == .dark ? .dark : .light
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

private struct DiffLoader: View {
    let engine: LumaCore.Engine
    let sessionID: UUID
    let leftDecoded: DecodedITrace?
    let target: LumaCore.ITrace
    let leftName: String
    let expectedSize: Int

    @State private var rightDecoded: DecodedITrace?
    @State private var errorText: String?

    var body: some View {
        Group {
            if let leftDecoded, let rightDecoded {
                ITraceDiffView(
                    left: leftDecoded,
                    right: rightDecoded,
                    leftName: leftName,
                    rightName: target.displayName
                )
                .frame(minWidth: 700, minHeight: 500)
            } else if let errorText {
                Text(errorText).padding()
            } else {
                ProgressView().padding()
            }
        }
        .task(id: target.id) {
            do {
                let data = try await engine.loadTraceData(
                    traceID: target.id,
                    sessionID: sessionID,
                    expectedSize: expectedSize
                )
                rightDecoded = try ITraceDecoder.decode(traceData: data, metadataJSON: target.metadataJSON)
            } catch {
                errorText = "Failed to decode: \(error.localizedDescription)"
            }
        }
    }
}
