import Foundation
import Gtk
import LumaCore

@MainActor
final class ITraceDiffView {
    let widget: Box

    private let left: ITraceCaptureRecord
    private let right: ITraceCaptureRecord
    private let bodyContainer: Box

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

        let titleLabel = Label(str: "Diff")
        titleLabel.halign = .start
        titleLabel.add(cssClass: "title-3")
        widget.append(child: titleLabel)

        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium

        let header = Box(orientation: .horizontal, spacing: 12)
        header.marginTop = 6
        header.marginBottom = 6

        let leftCol = Box(orientation: .vertical, spacing: 0)
        leftCol.hexpand = true
        let leftName = Label(str: left.displayName)
        leftName.halign = .start
        leftName.add(cssClass: "heading")
        leftCol.append(child: leftName)
        let leftDate = Label(str: formatter.string(from: left.capturedAt))
        leftDate.halign = .start
        leftDate.add(cssClass: "dim-label")
        leftDate.add(cssClass: "caption")
        leftCol.append(child: leftDate)
        header.append(child: leftCol)

        let arrow = Label(str: "\u{2194}")
        arrow.add(cssClass: "dim-label")
        header.append(child: arrow)

        let rightCol = Box(orientation: .vertical, spacing: 0)
        rightCol.hexpand = true
        let rightName = Label(str: right.displayName)
        rightName.halign = .start
        rightName.add(cssClass: "heading")
        rightCol.append(child: rightName)
        let rightDate = Label(str: formatter.string(from: right.capturedAt))
        rightDate.halign = .start
        rightDate.add(cssClass: "dim-label")
        rightDate.add(cssClass: "caption")
        rightCol.append(child: rightDate)
        header.append(child: rightCol)

        widget.append(child: header)

        bodyContainer = Box(orientation: .vertical, spacing: 8)
        bodyContainer.hexpand = true
        bodyContainer.vexpand = true
        bodyContainer.marginTop = 8
        widget.append(child: bodyContainer)

        let spinner = Spinner()
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
        var child = bodyContainer.firstChild
        while let current = child {
            child = current.nextSibling
            bodyContainer.remove(child: current)
        }

        switch result {
        case .failure(let error):
            let errorLabel = Label(str: "Failed to decode captures: \(error)")
            errorLabel.halign = .start
            errorLabel.wrap = true
            errorLabel.add(cssClass: "error")
            bodyContainer.append(child: errorLabel)

        case .success(let (l, r)):
            let rows = computeDiff(left: l.entries, right: r.entries)
            let listBox = Box(orientation: .vertical, spacing: 0)
            listBox.hexpand = true

            if rows.isEmpty {
                let empty = Label(str: "Both captures are empty.")
                empty.halign = .center
                empty.add(cssClass: "dim-label")
                listBox.append(child: empty)
            } else {
                for row in rows {
                    let label = Label(str: row.text)
                    label.halign = .start
                    label.add(cssClass: "monospace")
                    label.add(cssClass: row.cssClass)
                    label.marginStart = 8
                    label.marginEnd = 8
                    label.marginTop = 1
                    label.marginBottom = 1
                    label.selectable = true
                    listBox.append(child: label)
                }
            }

            let scroll = ScrolledWindow()
            scroll.hexpand = true
            scroll.vexpand = true
            scroll.set(child: listBox)
            bodyContainer.append(child: scroll)
        }
    }

    private struct DiffRow {
        let text: String
        let cssClass: String
    }

    private func computeDiff(left: [TraceEntry], right: [TraceEntry]) -> [DiffRow] {
        let m = left.count
        let n = right.count

        guard m > 0 || n > 0 else { return [] }

        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        if m > 0 && n > 0 {
            for i in 1...m {
                for j in 1...n {
                    if left[i - 1].blockAddress == right[j - 1].blockAddress
                        && left[i - 1].blockSize == right[j - 1].blockSize
                    {
                        dp[i][j] = dp[i - 1][j - 1] + 1
                    } else {
                        dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                    }
                }
            }
        }

        var rowsReversed: [DiffRow] = []
        var i = m
        var j = n
        while i > 0 && j > 0 {
            let a = left[i - 1]
            let b = right[j - 1]
            if a.blockAddress == b.blockAddress && a.blockSize == b.blockSize {
                if registerWritesEqual(a.registerWrites, b.registerWrites) {
                    rowsReversed.append(DiffRow(
                        text: String(format: "=  0x%016llx  %@", a.blockAddress, a.blockName),
                        cssClass: "luma-diff-same"
                    ))
                } else {
                    rowsReversed.append(DiffRow(
                        text: String(format: "~  0x%016llx  %@  [reg writes differ]", a.blockAddress, a.blockName),
                        cssClass: "luma-diff-changed"
                    ))
                }
                i -= 1
                j -= 1
            } else if dp[i - 1][j] >= dp[i][j - 1] {
                rowsReversed.append(DiffRow(
                    text: String(format: "-  0x%016llx  %@  (left only)", a.blockAddress, a.blockName),
                    cssClass: "luma-diff-removed"
                ))
                i -= 1
            } else {
                rowsReversed.append(DiffRow(
                    text: String(format: "+  0x%016llx  %@  (right only)", b.blockAddress, b.blockName),
                    cssClass: "luma-diff-added"
                ))
                j -= 1
            }
        }
        while i > 0 {
            let a = left[i - 1]
            rowsReversed.append(DiffRow(
                text: String(format: "-  0x%016llx  %@  (left only)", a.blockAddress, a.blockName),
                cssClass: "luma-diff-removed"
            ))
            i -= 1
        }
        while j > 0 {
            let b = right[j - 1]
            rowsReversed.append(DiffRow(
                text: String(format: "+  0x%016llx  %@  (right only)", b.blockAddress, b.blockName),
                cssClass: "luma-diff-added"
            ))
            j -= 1
        }

        return rowsReversed.reversed()
    }

    private func registerWritesEqual(_ a: [RegisterWrite], _ b: [RegisterWrite]) -> Bool {
        guard a.count == b.count else { return false }
        for (lw, rw) in zip(a, b) {
            if lw.registerIndex != rw.registerIndex || lw.value != rw.value {
                return false
            }
        }
        return true
    }

    static func present(from anchor: Widget, left: ITraceCaptureRecord, right: ITraceCaptureRecord) {
        let view = ITraceDiffView(left: left, right: right)

        let window = Window()
        window.title = "ITrace Diff"
        window.setDefaultSize(width: 900, height: 600)
        window.modal = false
        window.destroyWithParent = true

        if let rootPtr = anchor.root?.ptr {
            window.setTransientFor(parent: WindowRef(raw: rootPtr))
        }

        let header = HeaderBar()
        let closeButton = Button(label: "Close")
        closeButton.onClicked { [weak window] _ in
            MainActor.assumeIsolated { window?.destroy() }
        }
        header.packEnd(child: closeButton)
        window.set(titlebar: WidgetRef(header))

        window.set(child: view.widget)

        Self.retain(view: view, window: window)

        window.present()
    }

    private static var retained: [ObjectIdentifier: ITraceDiffView] = [:]

    private static func retain(view: ITraceDiffView, window: Window) {
        let key = ObjectIdentifier(window)
        retained[key] = view
        let handler: (WindowRef) -> Bool = { _ in
            MainActor.assumeIsolated {
                _ = retained.removeValue(forKey: key)
            }
            return false
        }
        window.onCloseRequest(handler: handler)
    }
}
