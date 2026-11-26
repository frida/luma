import LumaCore
import SwiftUI
import SwiftyPharo

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

    @State private var columnPath = PharoColumnPath(includesPage: true)

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.errorPresenter) private var errorPresenter

    private var node: LumaCore.ProcessNode? {
        engine.node(forSessionID: session.id)
    }

    var body: some View {
        Group {
            if let err = errorText {
                Text(err)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            } else if let insight {
                switch insight.kind {
                case .memory:
                    PatternDecodeView(
                        data: memoryData,
                        baseAddress: insight.lastResolvedAddress,
                        sessionID: session.id,
                        engine: engine,
                        placements: Binding(
                            get: { insight.placements },
                            set: { engine.setPlacements($0, forInsight: insight) }
                        ),
                        sizing: .fill,
                        memoryWriter: memoryWriter(of: insight),
                        onTruncated: readMoreMemory
                    )
                    .padding(.vertical, 2)
                case .disassembly:
                    disassemblyColumns
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.vertical, 8)
        .detailPaneInset()
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
        .onChange(of: insight.flatMap { engine.insightRefreshGenerations[$0.id] }) { _, _ in refresh() }
    }

    private var disassemblyColumns: some View {
        VStack(spacing: 0) {
            if !columnPath.objects.isEmpty {
                PharoOverviewStrip(path: columnPath, pageName: "Disassembly")
                Divider()
            }
            GeometryReader { scroller in
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        DisassemblyView(
                            lines: disasmLines,
                            sessionID: session.id,
                            engine: engine,
                            selection: $selection,
                            onNeedMore: { loadMoreDisasm() },
                            jumpRequest: DisassemblyJumpRequests.shared.target(in: insightID),
                            onJumpTaken: { DisassemblyJumpRequests.shared.clear(in: insightID) },
                            onChat: openChat
                        )
                        .frame(width: pageWidth(fitting: scroller.size.width))
                        .pharoColumnExtent(PharoColumnPath.pageID, in: columnPath)
                        .id(PharoColumnPath.pageID)
                        if !columnPath.objects.isEmpty {
                            if !columnPath.isFirstColumnCollapsed {
                                PharoDrillArrow()
                            }
                            pharoColumns(
                                runtime: PharoRuntime.shared,
                                path: columnPath,
                                width: pharoColumnWidth(fitting: scroller.size.width),
                                onCloseAll: columnPath.clear)
                        }
                    }
                    .frame(height: scroller.size.height - 2 * columnMargin)
                    .coordinateSpace(.named(PharoColumnPath.coordinateSpace))
                    .scrollTargetLayout()
                }
                .contentMargins(columnMargin, for: .scrollContent)
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                .pharoColumnScrolling(columnPath)
            }
        }
        .pharoMaximizedPane(runtime: PharoRuntime.shared, path: columnPath, onCloseAll: columnPath.clear)
        .environment(\.engine, engine)
    }

    private func pageWidth(fitting available: CGFloat) -> CGFloat {
        guard !columnPath.objects.isEmpty else { return available }
        return max(pharoPreferredColumnWidth, available - pharoColumnWidth(fitting: available) - 4 * pharoColumnMargin)
    }

    private var columnMargin: CGFloat {
        columnPath.objects.isEmpty ? 0 : pharoColumnMargin
    }

    private func openChat(about address: UInt64, chatID: UUID?) {
        let sessionID = session.id
        Task { @MainActor in
            do {
                columnPath.startOver(at: try await engine.chatColumn(chatID, aboutInstructionAt: address, in: sessionID))
            } catch {
                errorPresenter.present("Can’t open the chat", error.localizedDescription)
            }
        }
    }

    private func memoryWriter(of insight: LumaCore.AddressInsight) -> ((_ bytes: [UInt8], _ address: UInt64) async throws -> Void)? {
        guard node != nil else { return nil }
        return { bytes, address in try await engine.writeMemory(bytes, at: address, of: insight) }
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

    private func readMoreMemory() {
        guard let insight, insight.kind == .memory, let resolved = insight.lastResolvedAddress,
            memoryData.count < Engine.largestPatternRead
        else { return }
        let byteCount = min(max(memoryData.count, insight.byteCount) * 2, Engine.largestPatternRead)
        let reader = engine.memoryReader(forSessionID: session.id)
        Task { @MainActor in
            guard let bytes = try? await reader.read(at: resolved, count: byteCount) else { return }
            memoryData = Data(bytes)
            engine.setByteCount(byteCount, forInsight: insight)
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

            let page = await engine.disassemblyLines(sessionID: session.id, after: last, colorScheme: colorScheme)

            guard !Task.isCancelled else { return }

            disasmLines.append(contentsOf: page)
        }
    }

    private func fetchDisasmPage(start: UInt64, count: Int = 64) async -> DisassemblyPage {
        await engine.disassemblyPage(sessionID: session.id, start: start, count: count, colorScheme: colorScheme)
    }
}

struct DisassemblyView: View {
    let lines: [DisassemblyLine]

    let sessionID: UUID
    let engine: Engine
    @Binding var selection: SidebarItemID?
    let onNeedMore: () -> Void
    var jumpRequest: UInt64?
    var onJumpTaken: () -> Void = {}
    var onChat: ((UInt64, UUID?) -> Void)?
    var onActivate: ((UInt64) -> Void)?

    @State private var selectedAddr: UInt64?
    @FocusState private var isFocused: Bool

    @State private var hoveredAddr: UInt64?

    @State private var pulsingAddr: UInt64?
    @State private var pulsePhase: Bool = false
    @State private var pulseTask: Task<Void, Never>?

    @State private var followRequest: FollowRequest?
    @Environment(\.errorPresenter) private var errorPresenter

    let rowHeight: CGFloat = 20

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView(.vertical) {
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
                            onChat: onChat.map { open in { open(line.address, $0) } },
                            onActivate: onActivate.map { activate in { activate(line.address) } },
                            onSelect: {
                                selectedAddr = line.address
                                isFocused = true
                            },
                            onJump: { target in
                                try handleJump(target, scrollProxy: scrollProxy)
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
                .background { activationCatcher }
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
            .onKeyPress(.pageUp) {
                moveSelection(-20, scrollProxy: scrollProxy)
                return .handled
            }
            .onKeyPress(.pageDown) {
                moveSelection(20, scrollProxy: scrollProxy)
                return .handled
            }
            .onKeyPress(.home) {
                selectEdge(first: true, scrollProxy: scrollProxy)
                return .handled
            }
            .onKeyPress(.end) {
                selectEdge(first: false, scrollProxy: scrollProxy)
                return .handled
            }
            .onAppear { selectFirstIfNeeded() }
            .onChange(of: lines.isEmpty) { _, _ in selectFirstIfNeeded() }
            .onChange(of: pendingJump, initial: true) { _, request in
                guard let target = request.target, request.isLoaded else { return }
                onJumpTaken()
                try? handleJump(target, scrollProxy: scrollProxy)
            }
            .onChange(of: followRequest) { _, request in
                guard let request else { return }
                followRequest = nil
                do {
                    try handleJump(request.target, scrollProxy: scrollProxy)
                } catch {
                    errorPresenter.present("Can\u{2019}t jump here", error.localizedDescription)
                }
            }
        }
    }

    private var pendingJump: JumpRequest {
        JumpRequest(target: jumpRequest, isLoaded: jumpRequest.map { target in lines.contains { $0.address == target } } ?? false)
    }

    private struct JumpRequest: Equatable {
        let target: UInt64?
        let isLoaded: Bool
    }

    private struct FollowRequest: Equatable {
        let target: UInt64
        let id = UUID()
    }

    @ViewBuilder
    private var activationCatcher: some View {
        #if canImport(AppKit)
            PharoDoubleClickCatcher(row: lineIndex) { index in
                let line = lines[index]
                selectedAddr = line.address
                if let onActivate {
                    onActivate(line.address)
                } else {
                    follow(line)
                }
            }
        #endif
    }

    #if canImport(AppKit)
        private func lineIndex(_ catcher: NSView, _ point: NSPoint) -> Int? {
            let local = catcher.convert(point, from: nil)
            let fromTop = catcher.isFlipped ? local.y : catcher.bounds.height - local.y
            let index = Int(fromTop / rowHeight)
            return lines.indices.contains(index) ? index : nil
        }
    #endif

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
            scrollProxy.scrollTo(addr, anchor: .leading)
        }

        if next >= lines.count - 1 {
            onNeedMore()
        }
    }

    private func selectEdge(first: Bool, scrollProxy: ScrollViewProxy) {
        guard let addr = first ? lines.first?.address : lines.last?.address else { return }
        selectedAddr = addr
        withAnimation(.snappy) {
            scrollProxy.scrollTo(addr, anchor: .leading)
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
        follow(line)
    }

    private func follow(_ line: DisassemblyLine) {
        guard let target = line.branchTarget ?? line.callTarget else { return }
        followRequest = FollowRequest(target: target)
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
    let onChat: ((UUID?) -> Void)?
    let onActivate: (() -> Void)?
    let onSelect: () -> Void
    let onJump: (UInt64) throws -> Void

    @Environment(\.errorPresenter) private var errorPresenter

    private static let instructionWidth: CGFloat = 240
    private static let commentWidth: CGFloat = 320
    private static let bytesWidth: CGFloat = 88

    var body: some View {
        let annotation = engine.addressAnnotations[sessionID]?[line.address]
        let decorations = annotation?.decorations ?? []
        let chatIDs = annotation?.chatIDs ?? []

        HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 3) {
                ForEach(decorations.prefix(3)) { deco in
                    Circle()
                        .frame(width: 5, height: 5)
                        .foregroundStyle(.secondary)
                        .opacity(0.45)
                        .help(deco.help ?? "")
                }
                if !chatIDs.isEmpty, let onChat {
                    ChatBubble(chatIDs: chatIDs, chats: engine.objectChats, onChat: onChat)
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
                    if let onChat {
                        Button {
                            onChat(nil)
                        } label: {
                            Label("Chat about This Instruction", systemImage: "bubble.left.and.text.bubble.right")
                        }
                    }
                    Button {
                        Task { @MainActor in
                            await goToFunctionStart()
                        }
                    } label: {
                        Label("Go to Function Start", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                }

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
            .frame(minWidth: 0, idealWidth: Self.instructionWidth, maxWidth: Self.instructionWidth, alignment: .leading)
            .layoutPriority(2)

            Text(line.commentText?.attributed ?? AttributedString(""))
                .lineLimit(1)
                .truncationMode(.tail)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(minWidth: 0, idealWidth: Self.commentWidth, maxWidth: Self.commentWidth, alignment: .leading)
                .layoutPriority(1)

            Text(line.bytesText.attributed)
                .lineLimit(1)
                .truncationMode(.tail)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(minWidth: 0, idealWidth: Self.bytesWidth, maxWidth: Self.bytesWidth, alignment: .leading)
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
        #if !canImport(AppKit)
            .simultaneousGesture(TapGesture(count: 2).onEnded { onActivate?() })
        #endif
        .accessibilityActions {
            if let onActivate {
                Button("Open Instruction", action: onActivate)
            }
        }
        .onHover { isHovering in
            hoveredAddr = isHovering ? line.address : nil
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

private struct ChatBubble: View {
    let chatIDs: [UUID]
    let chats: ObjectChats
    let onChat: (UUID?) -> Void

    var body: some View {
        Group {
            if let only = chatIDs.first, chatIDs.count == 1 {
                Button {
                    onChat(only)
                } label: {
                    icon
                }
                .buttonStyle(.plain)
            } else {
                Menu {
                    ForEach(chatIDs, id: \.self) { chatID in
                        Button(title(of: chatID)) { onChat(chatID) }
                    }
                    Divider()
                    Button("New Chat") { onChat(nil) }
                } label: {
                    icon
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .help(chatIDs.map(title(of:)).joined(separator: "\n"))
        .accessibilityLabel(chatIDs.count == 1 ? "Open chat" : "Chats")
    }

    private var icon: some View {
        Image(systemName: "bubble.left.fill")
            .font(.system(size: 8))
            .foregroundStyle(.tint)
            .frame(width: 14, height: 14)
            .contentShape(Rectangle())
    }

    private func title(of chatID: UUID) -> String {
        chats.chat(withID: chatID).map(chats.displayTitle(of:)) ?? ""
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

@MainActor
@Observable
final class DisassemblyJumpRequests {
    static let shared = DisassemblyJumpRequests()

    private var targets: [UUID: UInt64] = [:]

    func request(_ address: UInt64, in insightID: UUID) {
        targets[insightID] = address
    }

    func target(in insightID: UUID) -> UInt64? {
        targets[insightID]
    }

    func clear(in insightID: UUID) {
        targets[insightID] = nil
    }
}

extension Engine {
    func chatColumn(_ chatID: UUID?, aboutInstructionAt address: UInt64, in sessionID: UUID) async throws -> PharoObject {
        try await PharoRuntime.shared.startBundledImage(for: self)
        guard let chatID else {
            return try await objectChats.start(aboutInstructionAt: anchor(sessionID: sessionID, address: address), in: sessionID).column
        }
        return try await objectChats.column(of: chatID)
    }
}
