import SwiftData
import SwiftUI
import SwiftyR2

struct AddressInsightDetailView: View {
    @Bindable var session: ProcessSession
    @Bindable var insight: AddressInsight
    @ObservedObject var workspace: Workspace
    @Binding var selection: SidebarItemID?

    @State private var refreshTask: Task<Void, Never>?
    @State private var disasmOps: [R2DisasmOp] = []
    @State private var output: AttributedString = AttributedString("")
    @State private var errorText: AttributedString?

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
                            ops: disasmOps,
                            sessionID: session.id,
                            workspace: workspace,
                            selection: $selection
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
        disasmOps = []
        errorText = nil
        output = AttributedString("")

        guard let node else {
            errorText = AttributedString("Session detached.")
            return
        }

        guard let resolved = node.resolve(insight.anchor) else {
            errorText = AttributedString("Could not resolve \(insight.anchor.displayString) in the current process.")
            return
        }

        insight.lastResolvedAddress = resolved

        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            guard let node = workspace.processNodes.first(where: { $0.sessionRecord == session }) else {
                errorText = AttributedString("Session detached.")
                return
            }

            guard let resolved = node.resolve(insight.anchor) else {
                errorText = AttributedString("Could not resolve \(insight.anchor.displayString) in the current process.")
                return
            }

            insight.lastResolvedAddress = resolved

            switch insight.kind {
            case .memory:
                let out = await node.r2Cmd("px \(insight.byteCount) @ 0x\(String(resolved, radix: 16))")
                guard !Task.isCancelled else { return }
                output = try! parseAnsi(out)

            case .disassembly:
                let out = await node.r2Cmd("pdJ 64 @ 0x\(String(resolved, radix: 16))")
                guard !Task.isCancelled else { return }
                disasmOps = try! JSONDecoder().decode([R2DisasmOp].self, from: Data(out.utf8))
            }
        }
    }
}

struct DisassemblyView: View {
    let ops: [R2DisasmOp]

    let sessionID: UUID
    let workspace: Workspace
    @Binding var selection: SidebarItemID?

    @State private var hoveredAddr: UInt64?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(ops) { op in
                    DisasmRow(
                        op: op,
                        sessionID: sessionID,
                        workspace: workspace,
                        selection: $selection,
                        hoveredAddr: $hoveredAddr
                    )
                    Divider().opacity(0.25)
                }
            }
            .padding(.leading, 54)
            .padding(.trailing, 12)
            .padding(.vertical, 8)
            .overlayPreferenceValue(RowCenterPreferenceKey.self) { centers in
                DisasmFlowOverlay(ops: ops, centers: centers)
            }
        }
        .textSelection(.disabled)
    }
}

private struct DisasmRow: View {
    let op: R2DisasmOp

    let sessionID: UUID
    let workspace: Workspace
    @Binding var selection: SidebarItemID?

    @Binding var hoveredAddr: UInt64?

    var body: some View {
        let c = op.columns()

        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(c.addr)
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

            Text(c.bytes)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 88, alignment: .leading)

            HStack(spacing: 6) {
                Text(c.asm)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)

                if let target = op.arrowValue ?? op.callValue {
                    Button {
                        let insight = workspace.createInsight(
                            sessionID: sessionID,
                            pointer: target,
                            kind: .disassembly
                        )
                        selection = .insight(sessionID, insight.id)
                    } label: {
                        Text(String(format: "→ 0x%llx", target))
                            .font(.system(.footnote, design: .monospaced))
                    }
                    .buttonStyle(.link)
                }

                if let comment = c.comment {
                    Text(comment)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onHover { isHovering in
            hoveredAddr = isHovering ? op.addrValue : nil
        }
        .background(RowCenterReporter(addr: op.addrValue))
        .background {
            if hoveredAddr == op.addrValue {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary)
            }
        }
    }
}

private struct RowCenterPreferenceKey: PreferenceKey {
    static var defaultValue: [UInt64: Anchor<CGPoint>] = [:]
    static func reduce(value: inout [UInt64: Anchor<CGPoint>], nextValue: () -> [UInt64: Anchor<CGPoint>]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

private struct RowCenterReporter: View {
    let addr: UInt64
    var body: some View {
        GeometryReader { _ in
            Color.clear
                .anchorPreference(key: RowCenterPreferenceKey.self, value: .center) { [addr: $0] }
        }
    }
}

private struct DisasmFlowOverlay: View {
    let ops: [R2DisasmOp]
    let centers: [UInt64: Anchor<CGPoint>]

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                let indexByAddr: [UInt64: Int] = Dictionary(
                    uniqueKeysWithValues: ops.enumerated().map { ($0.element.addrValue, $0.offset) })

                struct Edge {
                    let src: UInt64
                    let dst: UInt64
                    let sRow: Int
                    let dRow: Int
                    let lo: Int
                    let hi: Int
                }

                var edges: [Edge] = []
                edges.reserveCapacity(ops.count)
                for op in ops {
                    guard let dst = op.arrowValue, let s = indexByAddr[op.addrValue], let d = indexByAddr[dst] else { continue }
                    edges.append(Edge(src: op.addrValue, dst: dst, sRow: s, dRow: d, lo: min(s, d), hi: max(s, d)))
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
                    guard let a1 = centers[e.src], let a2 = centers[e.dst] else { continue }
                    let p1 = proxy[a1]
                    let p2 = proxy[a2]

                    let lane = laneForEdge[i]
                    let x = elbowX(lane)

                    var path = Path()
                    path.move(to: CGPoint(x: entryX, y: p1.y))
                    path.addLine(to: CGPoint(x: x, y: p1.y))
                    path.addLine(to: CGPoint(x: x, y: p2.y))
                    path.addLine(to: CGPoint(x: entryX, y: p2.y))

                    let color = FlowPalette.light[colorForEdge[i]]

                    context.stroke(path, with: .color(color.opacity(0.9)), lineWidth: 1.25)

                    let tip = CGPoint(x: entryX, y: p2.y)
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
