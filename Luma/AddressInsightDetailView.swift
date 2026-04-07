import LumaCore
import SwiftUI

struct AddressInsightDetailView: View {
    let session: LumaCore.ProcessSession
    @State var insight: LumaCore.AddressInsight
    @ObservedObject var workspace: Workspace
    @Binding var selection: SidebarItemID?

    @State private var refreshDebounce: Task<Void, Never>?
    @State private var refreshTask: Task<Void, Never>?
    @State private var showRefreshSpinner = false
    @State private var spinnerTask: Task<Void, Never>?
    @State private var memoryData: Data = Data()
    @State private var disasmLines: [DisassemblyLine] = []
    @State private var errorText: AttributedString?
    @State private var isLoadingMore = false

    @Environment(\.colorScheme) private var colorScheme

    private var node: LumaCore.ProcessNode? {
        workspace.engine.node(forSessionID: session.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            if node == nil {
                SessionDetachedBanner(session: session, workspace: workspace)
            }

            Group {
                if let err = errorText {
                    Text(err)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                } else {
                    switch insight.kind {
                    case .memory:
                        ScrollView([.vertical]) {
                            HexView(data: memoryData)
                                .padding(.vertical, 2)
                        }
                    case .disassembly:
                        DisassemblyView(
                            lines: disasmLines,
                            sessionID: session.id,
                            workspace: workspace,
                            selection: $selection,
                            onNeedMore: { loadMoreDisasm() }
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(8)
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
        }
        .onAppear { refresh() }
        .onChange(of: colorScheme) { _, _ in refresh() }
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
        guard let node = node else {
            errorText = AttributedString("Session detached.")
            return
        }

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

        let kind = insight.kind
        let byteCount = insight.byteCount
        let anchor = insight.anchor

        refreshTask = Task { @MainActor in
            defer {
                spinnerTask?.cancel()
                showRefreshSpinner = false
            }

            let resolved: UInt64
            do {
                resolved = try await node.resolve(anchor)
            } catch {
                if Task.isCancelled { return }
                errorText = AttributedString(error.localizedDescription)
                return
            }

            if Task.isCancelled { return }
            insight.lastResolvedAddress = resolved

            switch kind {
            case .memory:
                do {
                    let bytes = try await node.readRemoteMemory(at: resolved, count: byteCount)
                    if Task.isCancelled { return }

                    disasmLines = []
                    memoryData = Data(bytes)
                } catch {
                    if Task.isCancelled { return }
                    errorText = AttributedString(error.localizedDescription)
                }

            case .disassembly:
                let ops = await fetchDisasm(node: node, start: resolved, count: 64)
                if Task.isCancelled { return }

                disasmLines = ops
                memoryData = Data()
            }
        }
    }

    private func loadMoreDisasm() {
        guard !isLoadingMore else { return }
        guard insight.kind == .disassembly else { return }
        guard let node else { return }
        guard let last = disasmLines.last else { return }

        isLoadingMore = true

        Task { @MainActor in
            defer { isLoadingMore = false }

            let decoded = await fetchDisasm(
                node: node,
                start: last.address,
                count: 64
            )

            guard !Task.isCancelled else { return }
            guard !decoded.isEmpty else { return }

            var page = decoded
            page.removeFirst()
            guard !page.isEmpty else { return }

            disasmLines.append(contentsOf: page)
        }
    }

    private func fetchDisasm(
        node: LumaCore.ProcessNode,
        start: UInt64,
        count: Int = 64
    ) async -> [DisassemblyLine] {
        guard let disassembler = workspace.engine.disassembler(forSessionID: session.id) else {
            return []
        }
        return await disassembler.disassemble(
            DisassemblyRequest(address: start, count: count, isDarkMode: colorScheme == .dark)
        )
    }
}

struct DisassemblyView: View {
    let lines: [DisassemblyLine]

    let sessionID: UUID
    let workspace: Workspace
    @Binding var selection: SidebarItemID?
    let onNeedMore: () -> Void

    @State private var selectedAddr: UInt64?
    @FocusState private var isFocused: Bool

    @State private var hoveredAddr: UInt64?

    @State private var pulsingAddr: UInt64?
    @State private var pulsePhase: Bool = false
    @State private var pulseTask: Task<Void, Never>?

    @State private var requestedJumpTarget: UInt64?

    let rowHeight: CGFloat = 20

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        DisasmRow(
                            line: line,
                            sessionID: sessionID,
                            workspace: workspace,
                            selection: $selection,
                            rowHeight: rowHeight,
                            isSelected: selectedAddr == line.address,
                            hoveredAddr: $hoveredAddr,
                            isPulsing: pulsingAddr == line.address,
                            pulsePhase: pulsePhase,
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
            .onKeyPress(.return) {
                jumpSelection(scrollProxy: scrollProxy)
                return .handled
            }
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
            let insight = try workspace.engine.getOrCreateInsight(
                sessionID: sessionID,
                pointer: target,
                kind: .disassembly
            )
            selection = .insight(sessionID, insight.id)
        }
    }

    private func moveSelection(_ delta: Int, scrollProxy: ScrollViewProxy) {
        guard !lines.isEmpty else { return }

        let indexByAddr = Dictionary(uniqueKeysWithValues: lines.enumerated().map { ($0.element.address, $0.offset) })

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
    let workspace: Workspace
    @Binding var selection: SidebarItemID?

    let rowHeight: CGFloat
    let isSelected: Bool
    @Binding var hoveredAddr: UInt64?
    let isPulsing: Bool
    let pulsePhase: Bool
    let onSelect: () -> Void
    let onJump: (UInt64) throws -> Void
    let requestedJumpTarget: UInt64?
    let clearRequestedJump: () -> Void

    @Environment(\.errorPresenter) private var errorPresenter

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(line.addressText.attributed)
                .lineLimit(1)
                .truncationMode(.tail)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
                .contentShape(Rectangle())
                .overlay(alignment: .leading) {
                    let decorations = workspace.engine.addressAnnotations[sessionID]?[line.address]?.decorations ?? []

                    HStack(spacing: 3) {
                        ForEach(decorations.prefix(3)) { deco in
                            Circle()
                                .frame(width: 5, height: 5)
                                .foregroundStyle(.secondary)
                                .opacity(0.45)
                                .help(deco.help ?? "")
                        }
                    }
                    .frame(width: 12, alignment: .trailing)
                    .offset(x: -19)
                }
                .contextMenu {
                    Button {
                        Platform.copyToClipboard(String(format: "0x%llx", line.address))
                    } label: {
                        Label("Copy Address", systemImage: "doc.on.doc")
                    }

                    Divider()

                    ForEach(workspace.engine.addressActions(sessionID: sessionID, address: line.address)) { action in
                        Button(role: action.role == .destructive ? .destructive : nil) {
                            Task { @MainActor in
                                if let target = await action.perform() {
                                    selection = workspace.sidebarItem(for: target)
                                }
                            }
                        } label: {
                            if let systemImage = action.systemImage {
                                Label(action.title, systemImage: systemImage)
                            } else {
                                Text(action.title)
                            }
                        }
                    }
                }

            Text(line.bytesText.attributed)
                .lineLimit(1)
                .truncationMode(.tail)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 88, alignment: .leading)

            HStack(spacing: 6) {
                Text(line.asmText.attributed)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)

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
}

private struct DisasmFlowOverlay: View {
    let lines: [DisassemblyLine]
    let rowHeight: CGFloat

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                let indexByAddr: [UInt64: Int] = Dictionary(
                    uniqueKeysWithValues: lines.enumerated().map { ($0.element.address, $0.offset) }
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

