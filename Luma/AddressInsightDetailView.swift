import LumaCore
import SwiftUI

struct AddressInsightDetailView: View {
    let session: LumaCore.ProcessSession
    let insightID: UUID
    let engine: Engine
    @Binding var selection: SidebarItemID?

    private var insight: LumaCore.AddressInsight? {
        engine.insightsBySession[session.id]?.first { $0.id == insightID }
    }

    @State private var refreshDebounce: Task<Void, Never>?
    @State private var refreshTask: Task<Void, Never>?
    @State private var showRefreshSpinner = false
    @State private var spinnerTask: Task<Void, Never>?
    @State private var memoryData: Data = Data()
    @State private var disasmLines: [DisassemblyLine] = []
    @State private var errorText: AttributedString?
    @State private var isLoadingMore = false
    @State private var disasmScope: DisassemblyScope = .span

    @Environment(\.colorScheme) private var colorScheme

    private var node: LumaCore.ProcessNode? {
        engine.node(forSessionID: session.id)
    }

    var body: some View {
        Group {
            if let err = errorText {
                Text(err)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            } else if let kind = insight?.kind {
                switch kind {
                case .memory:
                    ScrollView([.vertical]) {
                        HexView(data: memoryData)
                            .padding(.vertical, 2)
                    }
                case .disassembly:
                    DisassemblyView(
                        lines: disasmLines,
                        sessionID: session.id,
                        engine: engine,
                        selection: $selection,
                        onNeedMore: { loadMoreDisasm() }
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(8)
        .overlay(alignment: .topTrailing) { refreshBar }
        .overlay(alignment: .center) {
            if showRefreshSpinner {
                ProgressView()
                    .controlSize(.small)
                    .padding(8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(8)
                    .transition(.opacity)
            }
        }
        .animation(.default, value: showRefreshSpinner)
        .onAppear { refresh() }
        .onChange(of: colorScheme) { _, _ in refresh() }
        .onChange(of: node != nil) { _, attached in
            if attached { refresh() }
        }
        .onChange(of: insight?.lastResolvedAddress) { _, _ in refresh() }
    }

    @ViewBuilder private var refreshBar: some View {
        HStack(spacing: 6) {
            Button {
                rereadBytes()
            } label: {
                Label("Reread Bytes", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
            }
            .help("Drop cached bytes for this view and refetch.")
            .buttonStyle(.borderless)
            .disabled(node == nil)

            Button {
                reanalyzeModule()
            } label: {
                Label("Reanalyze Module", systemImage: "arrow.triangle.2.circlepath")
                    .labelStyle(.iconOnly)
            }
            .help("Drop disassembly analysis for this address's module.")
            .buttonStyle(.borderless)
            .disabled(node == nil || enclosingModule == nil)
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }

    private var enclosingModule: LumaCore.ProcessModule? {
        guard let insight else { return nil }
        if let resolved = insight.lastResolvedAddress,
            let module = engine.enclosingModule(at: resolved, sessionID: session.id)
        {
            return module
        }
        if case .moduleOffset(let name, _) = insight.anchor {
            return engine.modulesSnapshot(forSessionID: session.id).first { $0.name == name }
        }
        return nil
    }

    private func rereadBytes() {
        guard let insight, let resolved = insight.lastResolvedAddress else { return }
        let sessionID = session.id
        let byteCount = insight.byteCount
        Task { @MainActor in
            await engine.invalidateInsightRange(sessionID: sessionID, address: resolved, byteCount: byteCount)
            refresh()
        }
    }

    private func reanalyzeModule() {
        guard let module = enclosingModule else { return }
        engine.invalidateModule(sessionID: session.id, modulePath: module.path)
        refresh()
    }

    private func refresh() {
        refreshDebounce?.cancel()
        refreshDebounce = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000)
            if Task.isCancelled {
                return
            }
            doRefresh()
        }
    }

    private func doRefresh() {
        guard let snapshot = insight else { return }

        refreshTask?.cancel()
        spinnerTask?.cancel()
        showRefreshSpinner = false

        errorText = nil
        isLoadingMore = false

        spinnerTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
            if !(refreshTask?.isCancelled ?? true) {
                showRefreshSpinner = true
            }
        }

        let kind = snapshot.kind
        let byteCount = snapshot.byteCount
        let anchor = snapshot.anchor
        let hint = snapshot.lastResolvedAddress
        let reader = engine.memoryReader(forSessionID: session.id)

        refreshTask = Task { @MainActor in
            defer {
                spinnerTask?.cancel()
                showRefreshSpinner = false
            }

            guard let resolved = await engine.resolve(sessionID: session.id, anchor: anchor, hint: hint) else {
                if Task.isCancelled { return }
                errorText = AttributedString("Unable to resolve address while detached.")
                return
            }
            if Task.isCancelled { return }
            engine.recordInsightResolution(snapshot, resolved: resolved)

            switch kind {
            case .memory:
                do {
                    let bytes = try await reader.read(at: resolved, count: byteCount)
                    if Task.isCancelled { return }

                    disasmLines = []
                    memoryData = Data(bytes)
                } catch {
                    if Task.isCancelled { return }
                    errorText = AttributedString(error.localizedDescription)
                }

            case .disassembly:
                do {
                    _ = try await reader.read(at: resolved, count: 1)
                } catch {
                    if Task.isCancelled { return }
                    disasmLines = []
                    memoryData = Data()
                    errorText = AttributedString(error.localizedDescription)
                    return
                }

                let page = await fetchDisasmPage(start: resolved, count: 64)
                if Task.isCancelled { return }

                disasmLines = page.lines
                disasmScope = page.scope
                memoryData = Data()
            }
        }
    }

    private func loadMoreDisasm() {
        guard !isLoadingMore else { return }
        guard insight?.kind == .disassembly else { return }
        guard disasmScope == .span else { return }
        guard let last = disasmLines.last else { return }

        isLoadingMore = true

        Task { @MainActor in
            defer { isLoadingMore = false }

            let decoded = await fetchDisasmPage(start: last.address, count: 64).lines

            guard !Task.isCancelled else { return }
            guard !decoded.isEmpty else { return }

            var page = decoded
            page.removeFirst()
            guard !page.isEmpty else { return }

            disasmLines.append(contentsOf: page)
        }
    }

    private func fetchDisasmPage(
        start: UInt64,
        count: Int = 64
    ) async -> DisassemblyPage {
        guard let disassembler = engine.disassembler(forSessionID: session.id) else {
            return DisassemblyPage(lines: [], scope: .span)
        }
        return await disassembler.disassemblePage(
            DisassemblyRequest(address: start, count: count, appearance: colorScheme == .dark ? .dark : .light)
        )
    }
}

struct DisassemblyView: View {
    let lines: [DisassemblyLine]

    let sessionID: UUID
    let engine: Engine
    @Binding var selection: SidebarItemID?
    let onNeedMore: () -> Void

    @State private var selectedAddr: UInt64?
    @FocusState private var isFocused: Bool

    @State private var hoveredAddr: UInt64?

    @State private var pulsingAddr: UInt64?
    @State private var pulsePhase: Bool = false
    @State private var pulseTask: Task<Void, Never>?

    @State private var requestedJumpTarget: UInt64?
    @State private var openNotePopoverAddress: UInt64?

    let rowHeight: CGFloat = 20

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        DisasmRow(
                            line: line,
                            sessionID: sessionID,
                            engine: engine,
                            selection: $selection,
                            rowHeight: rowHeight,
                            isSelected: selectedAddr == line.address,
                            hoveredAddr: $hoveredAddr,
                            isPulsing: pulsingAddr == line.address,
                            pulsePhase: pulsePhase,
                            openNotePopoverAddress: $openNotePopoverAddress,
                            onSelect: {
                                selectedAddr = line.address
                                isFocused = true
                            },
                            onJump: { target in
                                try handleJump(target, scrollProxy: scrollProxy)
                            },
                            requestedJumpTarget: requestedJumpTarget,
                            clearRequestedJump: {
                                requestedJumpTarget = nil
                            }
                        )
                        .id(line.address)
                        .onAppear {
                            if line.id == lines.last?.id {
                                onNeedMore()
                            }
                        }
                        .errorPopoverHost()
                    }
                }
                .frame(maxWidth: 800, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 54)
                .padding(.trailing, 12)
                .overlay(alignment: .topLeading) {
                    DisasmFlowOverlay(
                        lines: lines,
                        rowHeight: rowHeight,
                    )
                }
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
                if openNotePopoverAddress != nil { return .ignored }
                moveSelection(-1, scrollProxy: scrollProxy)
                return .handled
            }
            .onKeyPress(.downArrow) {
                if openNotePopoverAddress != nil { return .ignored }
                moveSelection(1, scrollProxy: scrollProxy)
                return .handled
            }
            .onKeyPress("k") {
                if openNotePopoverAddress != nil { return .ignored }
                moveSelection(-1, scrollProxy: scrollProxy)
                return .handled
            }
            .onKeyPress("j") {
                if openNotePopoverAddress != nil { return .ignored }
                moveSelection(1, scrollProxy: scrollProxy)
                return .handled
            }
            .onKeyPress(.return) {
                if openNotePopoverAddress != nil { return .ignored }
                jumpSelection(scrollProxy: scrollProxy)
                return .handled
            }
            .onKeyPress(.pageUp) {
                if openNotePopoverAddress != nil { return .ignored }
                moveSelection(-20, scrollProxy: scrollProxy)
                return .handled
            }
            .onKeyPress(.pageDown) {
                if openNotePopoverAddress != nil { return .ignored }
                moveSelection(20, scrollProxy: scrollProxy)
                return .handled
            }
            .onKeyPress(.home) {
                if openNotePopoverAddress != nil { return .ignored }
                selectEdge(first: true, scrollProxy: scrollProxy)
                return .handled
            }
            .onKeyPress(.end) {
                if openNotePopoverAddress != nil { return .ignored }
                selectEdge(first: false, scrollProxy: scrollProxy)
                return .handled
            }
            .onAppear { selectFirstIfNeeded() }
            .onChange(of: lines.isEmpty) { _, _ in selectFirstIfNeeded() }
        }
    }

    private func handleJump(_ target: UInt64, scrollProxy: ScrollViewProxy) throws {
        if lines.contains(where: { $0.address == target }) {
            selectedAddr = target
            isFocused = true

            withAnimation(.snappy) {
                scrollProxy.scrollTo(target, anchor: .center)
            }

            pulseTask?.cancel()

            pulsingAddr = target
            pulsePhase = false

            pulseTask = Task { @MainActor in
                let myTarget = target

                defer {
                    if pulsingAddr == myTarget {
                        pulsingAddr = nil
                        pulsePhase = false
                    }
                }

                let beats = 3
                let half: Double = 0.18

                for _ in 0..<beats {
                    guard pulsingAddr == myTarget else { return }
                    withAnimation(.easeInOut(duration: half)) { pulsePhase = true }
                    try? await Task.sleep(nanoseconds: UInt64(half * 1_000_000_000))

                    guard pulsingAddr == myTarget else { return }
                    withAnimation(.easeInOut(duration: half)) { pulsePhase = false }
                    try? await Task.sleep(nanoseconds: UInt64(half * 1_000_000_000))
                }
            }
        } else {
            let insight = try engine.getOrCreateInsight(
                sessionID: sessionID,
                pointer: target,
                kind: .disassembly
            )
            selection = .insight(sessionID, insight.id)
        }
    }

    private func moveSelection(_ delta: Int, scrollProxy: ScrollViewProxy) {
        guard !lines.isEmpty else { return }

        let indexByAddr = Dictionary(
            lines.enumerated().map { ($0.element.address, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )

        let currentIndex: Int
        if let sel = selectedAddr, let i = indexByAddr[sel] {
            currentIndex = i
        } else {
            currentIndex = 0
        }

        let next = max(0, min(lines.count - 1, currentIndex + delta))
        let addr = lines[next].address

        selectedAddr = addr
        withAnimation(.snappy) {
            scrollProxy.scrollTo(addr, anchor: .center)
        }

        if next >= lines.count - 1 {
            onNeedMore()
        }
    }

    private func selectEdge(first: Bool, scrollProxy: ScrollViewProxy) {
        guard let addr = first ? lines.first?.address : lines.last?.address else { return }
        selectedAddr = addr
        withAnimation(.snappy) {
            scrollProxy.scrollTo(addr, anchor: .center)
        }
        if !first {
            onNeedMore()
        }
    }

    private func selectFirstIfNeeded() {
        if selectedAddr == nil, let first = lines.first?.address {
            selectedAddr = first
        }
    }

    private func jumpSelection(scrollProxy: ScrollViewProxy) {
        guard let sel = selectedAddr else { return }
        guard let line = lines.first(where: { $0.address == sel }) else { return }
        guard let target = line.branchTarget ?? line.callTarget else { return }
        requestedJumpTarget = target
    }
}

private struct DisasmRow: View {
    let line: DisassemblyLine

    let sessionID: UUID
    let engine: Engine
    @Binding var selection: SidebarItemID?

    let rowHeight: CGFloat
    let isSelected: Bool
    @Binding var hoveredAddr: UInt64?
    let isPulsing: Bool
    let pulsePhase: Bool
    @Binding var openNotePopoverAddress: UInt64?
    let onSelect: () -> Void
    let onJump: (UInt64) throws -> Void
    let requestedJumpTarget: UInt64?
    let clearRequestedJump: () -> Void

    @Environment(\.errorPresenter) private var errorPresenter

    var body: some View {
        let annotation = engine.addressAnnotations[sessionID]?[line.address]
        let decorations = annotation?.decorations ?? []
        let noteCount = annotation?.noteCount ?? 0

        HStack(alignment: .firstTextBaseline, spacing: 10) {
            HStack(spacing: 3) {
                ForEach(decorations.prefix(3)) { deco in
                    Circle()
                        .frame(width: 5, height: 5)
                        .foregroundStyle(.secondary)
                        .opacity(0.45)
                        .help(deco.help ?? "")
                }
                if noteCount > 0 {
                    Image(systemName: "bubble.left.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.tint)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            openNotePopoverAddress = line.address
                        }
                        .help("\(noteCount) thread\(noteCount == 1 ? "" : "s")")
                }
            }
            .frame(width: 24, alignment: .trailing)

            Text(line.addressText.attributed)
                .lineLimit(1)
                .truncationMode(.tail)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
                .contentShape(Rectangle())
                .pointerActions(
                    engine: engine,
                    sessionID: sessionID,
                    value: String(format: "0x%llx", line.address),
                    address: line.address,
                    context: AddressContext(kind: .code),
                    selection: $selection
                ) {
                    Divider()
                    Button {
                        openNotePopoverAddress = line.address
                    } label: {
                        Label("Notes & AI…", systemImage: "bubble.left.and.text.bubble.right")
                    }
                    Button {
                        Task { @MainActor in
                            await goToFunctionStart()
                        }
                    } label: {
                        Label("Go to Function Start", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                }
                .popover(
                    isPresented: Binding(
                        get: { openNotePopoverAddress == line.address },
                        set: { presented in
                            if !presented, openNotePopoverAddress == line.address {
                                openNotePopoverAddress = nil
                            }
                        }
                    ),
                    arrowEdge: .trailing
                ) {
                    AddressNotePopover(
                        engine: engine,
                        sessionID: sessionID,
                        address: line.address,
                        isPresented: Binding(
                            get: { openNotePopoverAddress == line.address },
                            set: { presented in
                                if !presented { openNotePopoverAddress = nil }
                            }
                        )
                    )
                }

            Text(line.bytesText.attributed)
                .lineLimit(1)
                .truncationMode(.tail)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 88, alignment: .leading)

            HStack(spacing: 6) {
                DisassemblyAsmText(
                    asm: line.asmText,
                    engine: engine,
                    sessionID: sessionID,
                    selection: $selection
                )

                if let target = line.branchTarget ?? line.callTarget {
                    Group {
                        if !containsPrintedTarget(line.asmText, target: target) {
                            Button {
                                jump(target)
                            } label: {
                                Text(String(format: "@0x%llx", target))
                                    .font(.system(.footnote, design: .monospaced))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.quaternary, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        } else {
                            Button {
                                jump(target)
                            } label: {
                                Image(systemName: "arrow.turn.down.right")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .opacity(0.6)
                            .help("Jump to 0x\(String(target, radix: 16))")
                        }
                    }
                }
            }
            .frame(minWidth: 240, maxWidth: .infinity, alignment: .leading)

            Text(line.commentText?.attributed ?? AttributedString(""))
                .lineLimit(1)
                .truncationMode(.tail)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(width: 320, alignment: .leading)
        }
        .frame(height: rowHeight - 4, alignment: .center)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .background {
            if isPulsing {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(pulsePhase ? 0.28 : 0.06))
            } else if hoveredAddr == line.address {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary)
            } else if isSelected {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(0.14))
            }
        }
        .onTapGesture {
            onSelect()
        }
        .onHover { isHovering in
            hoveredAddr = isHovering ? line.address : nil
        }
        .onChange(of: requestedJumpTarget) { _, newValue in
            guard isSelected else { return }
            guard let target = newValue else { return }
            clearRequestedJump()
            jump(target)
        }
    }

    func jump(_ target: UInt64) {
        do {
            try onJump(target)
        } catch {
            errorPresenter.present("Can’t jump here", error.localizedDescription)
        }
    }

    private func containsPrintedTarget(_ asm: StyledText, target: UInt64) -> Bool {
        let s = asm.plainText.lowercased()
        let hex = String(format: "0x%llx", target).lowercased()
        return s.contains(hex)
    }

    private func goToFunctionStart() async {
        guard let dis = engine.disassembler(forSessionID: sessionID) else { return }
        guard let target = await dis.findFunctionStart(containing: line.address) else {
            errorPresenter.present(
                "No enclosing function",
                "Couldn’t locate a function containing \(String(format: "0x%llx", line.address)). The binary may not have been analyzed at this address."
            )
            return
        }
        do {
            let insight = try engine.getOrCreateInsight(sessionID: sessionID, pointer: target, kind: .disassembly)
            selection = .insight(sessionID, insight.id)
        } catch {
            errorPresenter.present("Can’t open function", error.localizedDescription)
        }
    }
}

private struct DisassemblyAsmText: View {
    let asm: StyledText
    let engine: Engine
    let sessionID: UUID
    @Binding var selection: SidebarItemID?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(asm.addressSegments().enumerated()), id: \.offset) { _, segment in
                if let address = segment.address {
                    Text(segment.text.attributed)
                        .pointerActions(
                            engine: engine,
                            sessionID: sessionID,
                            value: String(format: "0x%llx", address),
                            address: address,
                            copyTitle: "Copy Address",
                            keepsTextSelectable: true,
                            selection: $selection
                        )
                } else {
                    Text(segment.text.attributed)
                }
            }
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .font(.system(.footnote, design: .monospaced))
        .foregroundStyle(.primary)
        .textSelection(.enabled)
    }
}

private struct DisasmFlowOverlay: View {
    let lines: [DisassemblyLine]
    let rowHeight: CGFloat

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                let indexByAddr: [UInt64: Int] = Dictionary(
                    lines.enumerated().map { ($0.element.address, $0.offset) },
                    uniquingKeysWith: { first, _ in first }
                )

                func centerY(forRow row: Int) -> CGFloat {
                    CGFloat(row) * rowHeight + rowHeight * 0.5
                }

                struct Edge {
                    let src: UInt64
                    let dst: UInt64
                    let sRow: Int
                    let dRow: Int
                    let lo: Int
                    let hi: Int
                }

                var edges: [Edge] = []
                edges.reserveCapacity(lines.count)
                for line in lines {
                    guard let dst = line.branchTarget, let s = indexByAddr[line.address], let d = indexByAddr[dst] else { continue }
                    edges.append(Edge(src: line.address, dst: dst, sRow: s, dRow: d, lo: min(s, d), hi: max(s, d)))
                }

                edges.sort { a, b in
                    if a.lo != b.lo { return a.lo < b.lo }
                    return (a.hi - a.lo) < (b.hi - b.lo)
                }

                var laneEnds: [Int] = []
                var laneForEdge: [Int] = Array(repeating: 0, count: edges.count)

                for i in edges.indices {
                    let e = edges[i]
                    var lane = 0
                    while lane < laneEnds.count {
                        if e.lo > laneEnds[lane] {
                            laneEnds[lane] = e.hi
                            break
                        }
                        lane += 1
                    }
                    if lane == laneEnds.count {
                        laneEnds.append(e.hi)
                    }
                    laneForEdge[i] = lane
                }

                var colorForEdge: [Int] = Array(repeating: -1, count: edges.count)

                func overlaps(_ a: Edge, _ b: Edge) -> Bool {
                    !(a.hi < b.lo || b.hi < a.lo)
                }

                for i in edges.indices {
                    var usedColors = Set<Int>()

                    for j in edges.indices {
                        guard j != i else { continue }
                        guard colorForEdge[j] >= 0 else { continue }

                        if overlaps(edges[i], edges[j]) && abs(laneForEdge[i] - laneForEdge[j]) <= 1 {
                            usedColors.insert(colorForEdge[j])
                        }
                    }

                    for c in FlowPalette.light.indices {
                        if !usedColors.contains(c) {
                            colorForEdge[i] = c
                            break
                        }
                    }

                    if colorForEdge[i] == -1 {
                        colorForEdge[i] = i % FlowPalette.light.count
                    }
                }

                let laneSpacing: CGFloat = 6
                let baseX: CGFloat = 12
                let elbowX = { (lane: Int) in baseX + CGFloat(lane) * laneSpacing }
                let entryX: CGFloat = 48

                for i in edges.indices {
                    let e = edges[i]
                    let y1 = centerY(forRow: e.sRow)
                    let y2 = centerY(forRow: e.dRow)

                    let lane = laneForEdge[i]
                    let x = elbowX(lane)

                    var path = Path()
                    path.move(to: CGPoint(x: entryX, y: y1))
                    path.addLine(to: CGPoint(x: x, y: y1))
                    path.addLine(to: CGPoint(x: x, y: y2))
                    path.addLine(to: CGPoint(x: entryX, y: y2))

                    let color = FlowPalette.light[colorForEdge[i]]

                    context.stroke(path, with: .color(color.opacity(0.9)), lineWidth: 1.25)

                    let tip = CGPoint(x: entryX, y: y2)
                    let arrowSize: CGFloat = 6
                    let left = CGPoint(x: tip.x - arrowSize, y: tip.y - arrowSize * 0.65)
                    let right = CGPoint(x: tip.x - arrowSize, y: tip.y + arrowSize * 0.65)

                    var head = Path()
                    head.move(to: tip)
                    head.addLine(to: left)
                    head.addLine(to: right)
                    head.closeSubpath()
                    context.fill(head, with: .color(color))
                }
            }
            .allowsHitTesting(false)
        }
    }
}

private enum FlowPalette {
    static let light: [Color] = [
        .red, .orange, .yellow, .green, .mint, .teal,
        .cyan, .blue, .indigo, .purple, .pink, .brown,
    ]
}

