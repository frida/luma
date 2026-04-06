import Frida
import LumaCore
import SwiftUI

struct ITraceDiffView: View {
    let left: DecodedITrace
    let right: DecodedITrace
    let leftName: String
    let rightName: String

    @State private var diffResult: [DiffEntry] = []
    @State private var firstDivergenceIndex: Int?

    enum Side {
        case both
        case leftOnly
        case rightOnly
    }

    struct DiffEntry: Identifiable {
        let id = UUID()
        let side: Side
        let leftEntry: TraceEntry?
        let rightEntry: TraceEntry?
        let registerDiffs: [RegisterDiff]
    }

    struct RegisterDiff {
        let registerName: String
        let leftValue: UInt64?
        let rightValue: UInt64?
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if diffResult.isEmpty {
                Text("Traces are identical.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { scrollProxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(diffResult.enumerated()), id: \.element.id) { index, entry in
                                DiffRow(entry: entry)
                                    .id(index)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                    }
                    .onAppear {
                        if let idx = firstDivergenceIndex {
                            scrollProxy.scrollTo(idx, anchor: .center)
                        }
                    }
                }
            }
        }
        .onAppear { computeDiff() }
    }

    private var header: some View {
        HStack {
            Text("Diff: \(leftName) vs \(rightName)")
                .font(.headline)
            Spacer()
            if let idx = firstDivergenceIndex {
                Text("First divergence at entry \(idx)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func computeDiff() {
        let leftAddrs = left.entries.map(\.blockAddress)
        let rightAddrs = right.entries.map(\.blockAddress)

        let lcs = longestCommonSubsequence(leftAddrs, rightAddrs)

        var result: [DiffEntry] = []
        var li = 0, ri = 0, ci = 0
        var foundDivergence: Int?

        while li < left.entries.count || ri < right.entries.count {
            if ci < lcs.count,
                li < left.entries.count,
                ri < right.entries.count,
                left.entries[li].blockAddress == lcs[ci],
                right.entries[ri].blockAddress == lcs[ci]
            {
                let regDiffs = compareRegisters(
                    left.entries[li], right.entries[ri])
                let entry = DiffEntry(
                    side: .both,
                    leftEntry: left.entries[li],
                    rightEntry: right.entries[ri],
                    registerDiffs: regDiffs
                )
                if !regDiffs.isEmpty && foundDivergence == nil {
                    foundDivergence = result.count
                }
                result.append(entry)
                li += 1
                ri += 1
                ci += 1
            } else if li < left.entries.count
                && (ci >= lcs.count || left.entries[li].blockAddress != lcs[ci])
            {
                if foundDivergence == nil {
                    foundDivergence = result.count
                }
                result.append(DiffEntry(
                    side: .leftOnly,
                    leftEntry: left.entries[li],
                    rightEntry: nil,
                    registerDiffs: []
                ))
                li += 1
            } else if ri < right.entries.count
                && (ci >= lcs.count || right.entries[ri].blockAddress != lcs[ci])
            {
                if foundDivergence == nil {
                    foundDivergence = result.count
                }
                result.append(DiffEntry(
                    side: .rightOnly,
                    leftEntry: nil,
                    rightEntry: right.entries[ri],
                    registerDiffs: []
                ))
                ri += 1
            } else {
                break
            }
        }

        diffResult = result
        firstDivergenceIndex = foundDivergence
    }

    private func compareRegisters(
        _ a: TraceEntry, _ b: TraceEntry
    ) -> [RegisterDiff] {
        var diffs: [RegisterDiff] = []

        var aByIndex: [Int: RegisterWrite] = [:]
        for w in a.registerWrites { aByIndex[w.registerIndex] = w }
        var bByIndex: [Int: RegisterWrite] = [:]
        for w in b.registerWrites { bByIndex[w.registerIndex] = w }

        let allIndices = Set(aByIndex.keys).union(bByIndex.keys).sorted()

        for idx in allIndices {
            let aVal = aByIndex[idx]?.value
            let bVal = bByIndex[idx]?.value

            if aVal != bVal {
                let name = aByIndex[idx]?.registerName
                    ?? bByIndex[idx]?.registerName ?? "r\(idx)"
                diffs.append(RegisterDiff(
                    registerName: name,
                    leftValue: aVal,
                    rightValue: bVal
                ))
            }
        }

        return diffs
    }
}

private struct DiffRow: View {
    let entry: ITraceDiffView.DiffEntry

    var body: some View {
        HStack(spacing: 8) {
            sideIndicator

            let name = entry.leftEntry?.blockName
                ?? entry.rightEntry?.blockName ?? ""
            Text(name)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.cyan)

            if !entry.registerDiffs.isEmpty {
                HStack(spacing: 6) {
                    ForEach(
                        entry.registerDiffs.prefix(3),
                        id: \.registerName
                    ) { diff in
                        registerDiffText(diff)
                    }
                    if entry.registerDiffs.count > 3 {
                        Text("+\(entry.registerDiffs.count - 3)")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backgroundColor)
    }

    @ViewBuilder
    private var sideIndicator: some View {
        switch entry.side {
        case .both:
            Text(" ")
                .font(.system(.caption, design: .monospaced))
                .frame(width: 12)
        case .leftOnly:
            Text("-")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.red)
                .frame(width: 12)
        case .rightOnly:
            Text("+")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.green)
                .frame(width: 12)
        }
    }

    private var backgroundColor: Color {
        switch entry.side {
        case .both:
            if entry.registerDiffs.isEmpty {
                return .clear
            }
            return .yellow.opacity(0.1)
        case .leftOnly:
            return .red.opacity(0.1)
        case .rightOnly:
            return .green.opacity(0.1)
        }
    }

    private func registerDiffText(_ diff: ITraceDiffView.RegisterDiff) -> some View {
        HStack(spacing: 2) {
            Text(diff.registerName)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
            if let l = diff.leftValue {
                Text(String(format: "0x%llx", l))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.red)
            }
            Text("→")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
            if let r = diff.rightValue {
                Text(String(format: "0x%llx", r))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.green)
            }
        }
    }
}

private func longestCommonSubsequence(
    _ a: [UInt64], _ b: [UInt64]
) -> [UInt64] {
    let m = a.count, n = b.count
    guard m > 0, n > 0 else { return [] }

    var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)

    for i in 1...m {
        for j in 1...n {
            if a[i - 1] == b[j - 1] {
                dp[i][j] = dp[i - 1][j - 1] + 1
            } else {
                dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
            }
        }
    }

    var result: [UInt64] = []
    var i = m, j = n
    while i > 0, j > 0 {
        if a[i - 1] == b[j - 1] {
            result.append(a[i - 1])
            i -= 1
            j -= 1
        } else if dp[i - 1][j] > dp[i][j - 1] {
            i -= 1
        } else {
            j -= 1
        }
    }

    return result.reversed()
}
