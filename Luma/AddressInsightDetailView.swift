import SwiftData
import SwiftUI
import SwiftyR2

struct AddressInsightDetailView: View {
    @Bindable var session: ProcessSession
    @Bindable var insight: AddressInsight
    @ObservedObject var workspace: Workspace
    @Binding var selection: SidebarItemID?

    @State private var refreshTask: Task<Void, Never>?
    @State private var disasmLines: [DisasmLine] = []
    @State private var output: AttributedString = AttributedString("")
    @State private var errorText: AttributedString?
    @State private var isLoadingMore = false

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

            Group {
                if let err = errorText {
                    Text(err)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                } else {
                    switch insight.kind {
                    case .memory:
                        ScrollView {
                            Text(output)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
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
            .padding()
        }
        .onAppear { refresh() }
        .onChange(of: insight.kind) { refresh() }
        .onChange(of: insight.byteCount) { refresh() }
        .onChange(of: session.phase) { refresh() }
        .task(id: colorScheme) {
            await handleThemeChange(colorScheme)
        }
        .task(id: node?.id) {
            await handleThemeChange(colorScheme)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(insight.title).font(.headline)
                Text(insight.anchor.displayString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Picker("", selection: $insight.kind) {
                Text("Memory").tag(AddressInsight.Kind.memory)
                Text("Disassembly").tag(AddressInsight.Kind.disassembly)
            }
            .pickerStyle(.segmented)
            .frame(width: 240)

            if insight.kind == .memory {
                Stepper("", value: $insight.byteCount, in: 0x40...0x4000, step: 0x40)
                    .labelsHidden()
                    .help("Change dump size")
            }

            Button {
                refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh")
            .disabled(node == nil)
        }
        .padding()
        .background(.bar)
    }

    private func refresh() {
        disasmLines = []
        errorText = nil
        output = AttributedString("")
        isLoadingMore = false

        guard node != nil else {
            errorText = AttributedString("Session detached.")
            return
        }

        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            guard let node = workspace.processNodes.first(where: { $0.sessionRecord == session }) else {
                errorText = AttributedString("Session detached.")
                return
            }

            let resolved: UInt64
            do {
                resolved = try await node.resolve(insight.anchor)
            } catch {
                if Task.isCancelled { return }
                errorText = AttributedString(error.localizedDescription)
                return
            }

            insight.lastResolvedAddress = resolved

            switch insight.kind {
            case .memory:
                let out = await node.r2Cmd("px \(insight.byteCount) @ 0x\(String(resolved, radix: 16))")
                guard !Task.isCancelled else { return }
                output = try! parseAnsi(out)

            case .disassembly:
                let ops = await fetchDisasm(node: node, start: resolved, count: 64)
                guard !Task.isCancelled else { return }
                disasmLines = ops
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
                start: last.addrValue,
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
        node: ProcessNode,
        start: UInt64,
        count: Int = 64
    ) async -> [DisasmLine] {
        let out = await node.r2Cmd("pdJ \(count) @ 0x\(String(start, radix: 16))")
        let ops = try! JSONDecoder().decode([R2DisasmOp].self, from: Data(out.utf8))
        return ops.map(DisasmLine.init)
    }

    private func handleThemeChange(_ scheme: ColorScheme) async {
        guard let node else { return }
        await node.applyR2Theme((scheme == .light) ? "iaito" : "default")
        refresh()
    }
}

struct DisassemblyView: View {
    let lines: [DisasmLine]

    let sessionID: UUID
    let workspace: Workspace
    @Binding var selection: SidebarItemID?
    let onNeedMore: () -> Void

    @State private var hoveredAddr: UInt64?

    let rowHeight: CGFloat = 20
    let topInset: CGFloat = 8

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    DisasmRow(
                        line: line,
                        sessionID: sessionID,
                        workspace: workspace,
                        selection: $selection,
                        hoveredAddr: $hoveredAddr,
                        rowHeight: rowHeight
                    )
                    .onAppear {
                        if line.id == lines.last?.id {
                            onNeedMore()
                        }
                    }
                }
            }
            .frame(maxWidth: 800, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 54)
            .padding(.trailing, 12)
            .padding(.vertical, 8)
            .overlay(alignment: .topLeading) {
                DisasmFlowOverlay(
                    lines: lines,
                    rowHeight: rowHeight,
                    topInset: topInset
                )
            }
        }
        .textSelection(.disabled)
    }
}

private struct DisasmRow: View {
    let line: DisasmLine

    let sessionID: UUID
    let workspace: Workspace
    @Binding var selection: SidebarItemID?

    @Binding var hoveredAddr: UInt64?

    let rowHeight: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(line.addr)
                .lineLimit(1)
                .truncationMode(.tail)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
                .contentShape(Rectangle())
                .contextMenu {
                    Button {
                        // TODO: integrate with your “add instruction hook” flow
                        // (likely creates/opens a tracer hook editor scoped to this address)
                    } label: {
                        Label("Add Instruction Hook…", systemImage: "pin")
                    }

                    // TODO: If a hook already exists for op.addrValue:
                    // Button { selection = ... } label: { Label("Go to Hook", systemImage: "arrow.turn.down.right") }
                }

            Text(line.bytes)
                .lineLimit(1)
                .truncationMode(.tail)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 88, alignment: .leading)

            HStack(spacing: 6) {
                Text(line.asm)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)

                if let target = line.arrowValue ?? line.callValue {
                    if !containsPrintedTarget(line.asm, target: target) {
                        Button {
                            jump(to: target)
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
                            jump(to: target)
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
            .frame(minWidth: 240, maxWidth: .infinity, alignment: .leading)

            Text(line.comment ?? AttributedString(""))
                .lineLimit(1)
                .truncationMode(.tail)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(width: 320, alignment: .leading)
        }
        .frame(height: rowHeight, alignment: .center)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { isHovering in
            hoveredAddr = isHovering ? line.addrValue : nil
        }
        .background {
            if hoveredAddr == line.addrValue {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary)
            }
        }
    }

    private func jump(to target: UInt64) {
        let insight = workspace.createInsight(sessionID: sessionID, pointer: target, kind: .disassembly)
        selection = .insight(sessionID, insight.id)
    }

    private func containsPrintedTarget(_ asm: AttributedString, target: UInt64) -> Bool {
        let s = String(asm.characters).lowercased()
        let hex = String(format: "0x%llx", target).lowercased()
        return s.contains(hex)
    }
}

private struct DisasmFlowOverlay: View {
    let lines: [DisasmLine]
    let rowHeight: CGFloat
    let topInset: CGFloat

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                let indexByAddr: [UInt64: Int] = Dictionary(
                    uniqueKeysWithValues: lines.enumerated().map { ($0.element.addrValue, $0.offset) }
                )

                func centerY(forRow row: Int) -> CGFloat {
                    topInset + CGFloat(row) * rowHeight + rowHeight * 0.5
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
                    guard let dst = line.arrowValue, let s = indexByAddr[line.addrValue], let d = indexByAddr[dst] else { continue }
                    edges.append(Edge(src: line.addrValue, dst: dst, sRow: s, dRow: d, lo: min(s, d), hi: max(s, d)))
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

struct DisasmLine: Identifiable {
    let id: UInt64

    let addrValue: UInt64
    let arrowValue: UInt64?
    let callValue: UInt64?

    let addr: AttributedString
    let bytes: AttributedString
    let asm: AttributedString
    let comment: AttributedString?

    init(op: R2DisasmOp) {
        let c = op.columns()
        self.id = op.addrValue
        self.addrValue = op.addrValue
        self.arrowValue = op.arrowValue
        self.callValue = op.callValue
        self.addr = c.addr
        self.bytes = c.bytes
        self.asm = c.asm
        self.comment = c.comment
    }
}

struct R2DisasmOp: Decodable, Identifiable {
    struct Esil: Decodable {
        let expr: String
    }

    let addr: String
    let text: String
    let arrow: String?
    let call: String?
    let esil: Esil?

    var id: UInt64 { addrValue }

    var addrValue: UInt64 {
        UInt64(addr.dropFirst(2), radix: 16) ?? 0
    }

    var arrowValue: UInt64? {
        guard let arrow else { return nil }
        return UInt64(arrow.dropFirst(2), radix: 16)
    }

    var callValue: UInt64? {
        guard let call else { return nil }
        return UInt64(call.dropFirst(2), radix: 16)
    }

    struct Columns {
        let addr: AttributedString
        let bytes: AttributedString
        let asm: AttributedString
        let comment: AttributedString?
    }

    func columns() -> Columns {
        let attributed = try! parseAnsi(text)
        let plain = String(attributed.characters)

        let addrR = plain.range(of: addr)!

        let afterAddr = plain[addrR.upperBound...]
        let afterAddrStart = plain.distance(from: plain.startIndex, to: addrR.upperBound)

        let trimmedAfterAddr = afterAddr.drop(while: { $0 == " " || $0 == "\t" })
        let bytesStartInAfter = afterAddr.distance(from: afterAddr.startIndex, to: trimmedAfterAddr.startIndex)
        let bytesStart = afterAddrStart + bytesStartInAfter

        let bytesToken = trimmedAfterAddr.prefix { $0 != " " && $0 != "\t" }
        let bytesLen = bytesToken.count
        let bytesEnd = bytesStart + bytesLen

        var remStart = bytesEnd
        while remStart < plain.count {
            let idx = plain.index(plain.startIndex, offsetBy: remStart)
            let ch = plain[idx]
            if ch == " " || ch == "\t" { remStart += 1 } else { break }
        }

        let remainder = String(plain.dropFirst(remStart))

        let asmPlain: String
        let commentPlain: String?
        if let semi = remainder.firstIndex(of: ";") {
            asmPlain = remainder[..<semi].trimmingCharacters(in: .whitespaces)
            commentPlain = remainder[semi...].trimmingCharacters(in: .whitespaces)
        } else {
            asmPlain = remainder.trimmingCharacters(in: .whitespaces)
            commentPlain = nil
        }

        let addrStart = plain.distance(from: plain.startIndex, to: addrR.lowerBound)
        let addrEnd = plain.distance(from: plain.startIndex, to: addrR.upperBound)

        let asmOffsetInRem = remainder.range(of: asmPlain)?.lowerBound ?? remainder.startIndex
        let asmStart = remStart + remainder.distance(from: remainder.startIndex, to: asmOffsetInRem)
        let asmEnd = asmStart + asmPlain.count

        let commentAS: AttributedString?
        if let commentPlain, let cr = remainder.range(of: commentPlain) {
            let cStart = remStart + remainder.distance(from: remainder.startIndex, to: cr.lowerBound)
            let cEnd = cStart + commentPlain.count
            commentAS = attributed.slice(charRange: cStart..<cEnd)
        } else {
            commentAS = nil
        }

        return Columns(
            addr: attributed.slice(charRange: addrStart..<addrEnd),
            bytes: attributed.slice(charRange: bytesStart..<bytesEnd),
            asm: attributed.slice(charRange: asmStart..<asmEnd),
            comment: commentAS
        )
    }
}

extension AttributedString {
    fileprivate func index(atCharacterOffset offset: Int) -> AttributedString.Index {
        var i = startIndex
        var remaining = offset
        while remaining > 0 && i < endIndex {
            i = characters.index(after: i)
            remaining -= 1
        }
        return i
    }

    fileprivate func slice(charRange: Range<Int>) -> AttributedString {
        let a = index(atCharacterOffset: charRange.lowerBound)
        let b = index(atCharacterOffset: charRange.upperBound)
        return AttributedString(self[a..<b])
    }
}
