import Adw
import Foundation
import Gtk
import LumaCore

@MainActor
final class ITraceDiffView {
    let widget: Box

    private let left: ITraceCaptureRecord
    private let right: ITraceCaptureRecord
    private let bodyContainer: Box
    private var divergenceLabel: Label?

    init(left: ITraceCaptureRecord, right: ITraceCaptureRecord) {
        self.left = left
        self.right = right

        widget = Box(orientation: .vertical, spacing: 0)
        widget.hexpand = true
        widget.vexpand = true
        widget.marginStart = 16
        widget.marginEnd = 16
        widget.marginTop = 12
        widget.marginBottom = 12

        let headerRow = Box(orientation: .horizontal, spacing: 8)
        headerRow.hexpand = true
        let titleLabel = Label(str: "Diff: \(left.displayName) vs \(right.displayName)")
        titleLabel.halign = .start
        titleLabel.hexpand = true
        titleLabel.add(cssClass: "title-3")
        headerRow.append(child: titleLabel)
        divergenceLabel = Label(str: "")
        divergenceLabel!.halign = .end
        divergenceLabel!.add(cssClass: "dim-label")
        divergenceLabel!.add(cssClass: "caption")
        divergenceLabel!.visible = false
        headerRow.append(child: divergenceLabel!)
        widget.append(child: headerRow)

        bodyContainer = Box(orientation: .vertical, spacing: 0)
        bodyContainer.hexpand = true
        bodyContainer.vexpand = true
        bodyContainer.marginTop = 8
        widget.append(child: bodyContainer)

        let spinner = Gtk.Spinner()
        spinner.start()
        let loading = Box(orientation: .horizontal, spacing: 8)
        loading.halign = .center
        loading.marginTop = 24
        loading.append(child: spinner)
        loading.append(child: Label(str: "Decoding captures\u{2026}"))
        bodyContainer.append(child: loading)

        let leftData = left.traceData
        let leftMeta = left.metadataJSON
        let rightData = right.traceData
        let rightMeta = right.metadataJSON
        Task { @MainActor [weak self] in
            await Task.yield()
            let result: Result<(DecodedITrace, DecodedITrace), Error>
            do {
                let l = try ITraceDecoder.decode(traceData: leftData, metadataJSON: leftMeta)
                let r = try ITraceDecoder.decode(traceData: rightData, metadataJSON: rightMeta)
                result = .success((l, r))
            } catch {
                result = .failure(error)
            }
            self?.applyDecodeResult(result)
        }
    }

    private func applyDecodeResult(_ result: Result<(DecodedITrace, DecodedITrace), Error>) {
        while let child = bodyContainer.firstChild {
            bodyContainer.remove(child: child)
        }

        switch result {
        case .failure(let error):
            let errorLabel = Label(str: "Failed to decode captures: \(error)")
            errorLabel.halign = .start
            errorLabel.wrap = true
            errorLabel.add(cssClass: "error")
            bodyContainer.append(child: errorLabel)

        case .success(let (l, r)):
            let (rows, firstDivergence) = computeDiff(left: l.entries, right: r.entries)

            if let idx = firstDivergence {
                divergenceLabel?.label = "First divergence at entry \(idx)"
                divergenceLabel?.visible = true
            }

            if rows.isEmpty {
                let empty = Label(str: "Traces are identical.")
                empty.halign = .center
                empty.add(cssClass: "dim-label")
                bodyContainer.append(child: empty)
                return
            }

            let listBox = Box(orientation: .vertical, spacing: 0)
            listBox.hexpand = true

            for (index, row) in rows.enumerated() {
                let rowBox = Box(orientation: .horizontal, spacing: 8)
                rowBox.add(cssClass: row.cssClass)
                rowBox.marginStart = 4
                rowBox.marginEnd = 4

                let indexLabel = Label(str: String(format: "%4d", index))
                indexLabel.add(cssClass: "monospace")
                indexLabel.add(cssClass: "caption")
                indexLabel.add(cssClass: "dim-label")
                rowBox.append(child: indexLabel)

                let indicator = Label(str: row.indicator)
                indicator.add(cssClass: "monospace")
                indicator.add(cssClass: "caption")
                if row.indicatorCssClass != nil {
                    indicator.add(cssClass: row.indicatorCssClass!)
                }
                indicator.setSizeRequest(width: 12, height: -1)
                rowBox.append(child: indicator)

                let name = Label(str: row.blockName)
                name.halign = .start
                name.add(cssClass: "monospace")
                name.add(cssClass: "caption")
                name.add(cssClass: "luma-diff-block-name")
                rowBox.append(child: name)

                for diff in row.registerDiffs.prefix(3) {
                    let diffBox = Box(orientation: .horizontal, spacing: 2)
                    let regName = Label(str: diff.registerName)
                    regName.add(cssClass: "monospace")
                    regName.add(cssClass: "caption")
                    regName.add(cssClass: "dim-label")
                    diffBox.append(child: regName)

                    if let lv = diff.leftValue {
                        let lbl = Label(str: String(format: "0x%llx", lv))
                        lbl.add(cssClass: "monospace")
                        lbl.add(cssClass: "caption")
                        lbl.add(cssClass: "luma-diff-val-left")
                        diffBox.append(child: lbl)
                    }

                    let arrow = Label(str: "\u{2192}")
                    arrow.add(cssClass: "caption")
                    arrow.add(cssClass: "dim-label")
                    diffBox.append(child: arrow)

                    if let rv = diff.rightValue {
                        let lbl = Label(str: String(format: "0x%llx", rv))
                        lbl.add(cssClass: "monospace")
                        lbl.add(cssClass: "caption")
                        lbl.add(cssClass: "luma-diff-val-right")
                        diffBox.append(child: lbl)
                    }

                    rowBox.append(child: diffBox)
                }

                if row.registerDiffs.count > 3 {
                    let overflow = Label(str: "+\(row.registerDiffs.count - 3)")
                    overflow.add(cssClass: "monospace")
                    overflow.add(cssClass: "caption")
                    overflow.add(cssClass: "dim-label")
                    rowBox.append(child: overflow)
                }

                listBox.append(child: rowBox)
            }

            let scroll = ScrolledWindow()
            scroll.hexpand = true
            scroll.vexpand = true
            scroll.set(child: listBox)
            bodyContainer.append(child: scroll)

            if let divIdx = firstDivergence {
                Task { @MainActor in
                    await Task.yield()
                    await Task.yield()
                    guard let adj = scroll.vadjustment else { return }
                    let totalRows = Double(rows.count)
                    guard totalRows > 0 else { return }
                    let fraction = Double(divIdx) / totalRows
                    let target = fraction * adj.upper - adj.pageSize / 2
                    adj.value = max(0, min(target, adj.upper - adj.pageSize))
                }
            }
        }
    }

    // MARK: - Diff computation

    private struct RegisterDiff {
        let registerName: String
        let leftValue: UInt64?
        let rightValue: UInt64?
    }

    private struct DiffRow {
        let indicator: String
        let indicatorCssClass: String?
        let blockName: String
        let registerDiffs: [RegisterDiff]
        let cssClass: String
    }

    private func computeDiff(
        left: [TraceEntry], right: [TraceEntry]
    ) -> ([DiffRow], Int?) {
        let leftAddrs = left.map(\.blockAddress)
        let rightAddrs = right.map(\.blockAddress)
        let lcs = longestCommonSubsequence(leftAddrs, rightAddrs)

        var rows: [DiffRow] = []
        var li = 0, ri = 0, ci = 0
        var firstDivergence: Int?

        while li < left.count || ri < right.count {
            if ci < lcs.count,
                li < left.count,
                ri < right.count,
                left[li].blockAddress == lcs[ci],
                right[ri].blockAddress == lcs[ci]
            {
                let regDiffs = compareRegisters(left[li], right[ri])
                if !regDiffs.isEmpty, firstDivergence == nil {
                    firstDivergence = rows.count
                }
                rows.append(DiffRow(
                    indicator: " ",
                    indicatorCssClass: nil,
                    blockName: left[li].blockName,
                    registerDiffs: regDiffs,
                    cssClass: regDiffs.isEmpty ? "luma-diff-same" : "luma-diff-changed"
                ))
                li += 1; ri += 1; ci += 1
            } else if li < left.count
                && (ci >= lcs.count || left[li].blockAddress != lcs[ci])
            {
                if firstDivergence == nil { firstDivergence = rows.count }
                rows.append(DiffRow(
                    indicator: "\u{2212}",
                    indicatorCssClass: "luma-diff-indicator-removed",
                    blockName: left[li].blockName,
                    registerDiffs: [],
                    cssClass: "luma-diff-removed"
                ))
                li += 1
            } else if ri < right.count
                && (ci >= lcs.count || right[ri].blockAddress != lcs[ci])
            {
                if firstDivergence == nil { firstDivergence = rows.count }
                rows.append(DiffRow(
                    indicator: "+",
                    indicatorCssClass: "luma-diff-indicator-added",
                    blockName: right[ri].blockName,
                    registerDiffs: [],
                    cssClass: "luma-diff-added"
                ))
                ri += 1
            } else {
                break
            }
        }

        return (rows, firstDivergence)
    }

    private func compareRegisters(
        _ a: TraceEntry, _ b: TraceEntry
    ) -> [RegisterDiff] {
        var aByIndex: [Int: RegisterWrite] = [:]
        for w in a.registerWrites { aByIndex[w.registerIndex] = w }
        var bByIndex: [Int: RegisterWrite] = [:]
        for w in b.registerWrites { bByIndex[w.registerIndex] = w }

        var diffs: [RegisterDiff] = []
        for idx in Set(aByIndex.keys).union(bByIndex.keys).sorted() {
            let aVal = aByIndex[idx]?.value
            let bVal = bByIndex[idx]?.value
            if aVal != bVal {
                let name = aByIndex[idx]?.registerName
                    ?? bByIndex[idx]?.registerName ?? "r\(idx)"
                diffs.append(RegisterDiff(
                    registerName: name, leftValue: aVal, rightValue: bVal))
            }
        }
        return diffs
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
                i -= 1; j -= 1
            } else if dp[i - 1][j] > dp[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }
        return result.reversed()
    }

    // MARK: - Presentation

    static func present(from anchor: Widget, left: ITraceCaptureRecord, right: ITraceCaptureRecord) {
        let view = ITraceDiffView(left: left, right: right)

        let window = Adw.Window()
        applyWindowDecoration(window)
        window.title = "ITrace Diff"
        window.setDefaultSize(width: 900, height: 600)
        window.destroyWithParent = true

        if let rootPtr = anchor.root?.ptr {
            window.setTransientFor(parent: Gtk.WindowRef(raw: rootPtr))
        }

        let header = Adw.HeaderBar()

        let toolbarView = Adw.ToolbarView()
        toolbarView.addTopBar(widget: header)
        toolbarView.set(content: view.widget)
        window.set(content: toolbarView)

        Self.retain(view: view, window: window)

        installEscapeShortcut(on: window)
        window.present()
    }

    private static var retained: [ObjectIdentifier: ITraceDiffView] = [:]
    private static var retainedWindows: [ObjectIdentifier: Adw.Window] = [:]

    private static func retain(view: ITraceDiffView, window: Adw.Window) {
        let id = ObjectIdentifier(view)
        retained[id] = view
        retainedWindows[id] = window
        window.onDestroy { _ in
            MainActor.assumeIsolated {
                retained.removeValue(forKey: id)
                retainedWindows.removeValue(forKey: id)
            }
        }
    }
}
