#if canImport(AppKit)
    import AppKit
    import LumaCore

    @MainActor
    final class CodeCompletionPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var onAccept: ((LSP.CompletionItem) -> Void)?
        var describe: ((LSP.CompletionItem) async -> LSP.CompletionItem)?
        var classify: ((String) async -> [SemanticToken])?

        private let panel: NSPanel
        private let table = NSTableView()
        private let detailField = NSTextField(wrappingLabelWithString: "")
        private let documentationField = NSTextField(wrappingLabelWithString: "")
        private let detailPane = NSStackView()
        private let listWidth: CGFloat = 320
        private let rowHeight: CGFloat = 22
        private var items: [LSP.CompletionItem] = []
        private var describing: Task<Void, Never>?

        override init() {
            panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 100),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: true
            )
            super.init()
            panel.level = .floating
            panel.hasShadow = true
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hidesOnDeactivate = true

            let labelColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("label"))
            labelColumn.width = 196
            let kindColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("kind"))
            kindColumn.width = 90
            table.addTableColumn(labelColumn)
            table.addTableColumn(kindColumn)
            table.headerView = nil
            table.rowHeight = rowHeight
            table.intercellSpacing = NSSize(width: 6, height: 0)
            table.selectionHighlightStyle = .regular
            table.allowsEmptySelection = false
            table.refusesFirstResponder = true
            table.dataSource = self
            table.delegate = self
            table.target = self
            table.action = #selector(tableClicked)
            table.doubleAction = #selector(tableDoubleClicked)

            let scroll = NSScrollView()
            scroll.documentView = table
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.drawsBackground = false
            scroll.translatesAutoresizingMaskIntoConstraints = false
            scroll.widthAnchor.constraint(equalToConstant: listWidth).isActive = true

            detailField.font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            documentationField.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            documentationField.textColor = .secondaryLabelColor
            for field in [detailField, documentationField] {
                field.preferredMaxLayoutWidth = 300
                field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            }
            detailPane.orientation = .vertical
            detailPane.alignment = .leading
            detailPane.spacing = 6
            detailPane.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
            detailPane.addArrangedSubview(detailField)
            detailPane.addArrangedSubview(documentationField)
            detailPane.translatesAutoresizingMaskIntoConstraints = false
            detailPane.widthAnchor.constraint(equalToConstant: listWidth).isActive = true
            detailPane.isHidden = true

            let panes = NSStackView(views: [scroll, detailPane])
            panes.orientation = .horizontal
            panes.alignment = .top
            panes.spacing = 0
            panes.distribution = .fill

            let content = NSVisualEffectView()
            content.material = .popover
            content.state = .active
            content.wantsLayer = true
            content.layer?.cornerRadius = 8
            content.layer?.masksToBounds = true
            content.layer?.borderWidth = 1
            content.layer?.borderColor = NSColor.separatorColor.cgColor
            content.addSubview(panes)
            panes.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                panes.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                panes.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                panes.topAnchor.constraint(equalTo: content.topAnchor),
                panes.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
            panel.contentView = content
        }

        var isShown: Bool {
            panel.isVisible
        }

        var selectedItem: LSP.CompletionItem? {
            let row = table.selectedRow
            return row >= 0 && row < items.count ? items[row] : nil
        }

        func show(_ newItems: [LSP.CompletionItem], belowScreenRect anchor: NSRect, of view: NSView) {
            items = newItems
            table.reloadData()
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            table.scrollRowToVisible(0)
            layout(below: anchor, in: view)
            if !panel.isVisible {
                view.window?.addChildWindow(panel, ordered: .above)
                panel.orderFront(nil)
            }
            describeSelection()
        }

        private func layout(below anchor: NSRect, in view: NSView) {
            guard let window = view.window else { return }
            let listHeight = CGFloat(min(items.count, 8)) * rowHeight + 4
            let width = listWidth + (detailPane.isHidden ? 0 : listWidth)
            var origin = NSPoint(x: anchor.minX, y: anchor.minY - listHeight - 4)
            if let screen = window.screen {
                origin.x = min(origin.x, screen.visibleFrame.maxX - width)
                if origin.y < screen.visibleFrame.minY {
                    origin.y = anchor.maxY + 4
                }
            }
            panel.setFrame(NSRect(x: origin.x, y: origin.y, width: width, height: listHeight), display: true)
        }

        func moveSelection(by delta: Int) {
            guard !items.isEmpty else { return }
            var row = table.selectedRow + delta
            if row < 0 { row = items.count - 1 }
            if row >= items.count { row = 0 }
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }

        func dismiss() {
            describing?.cancel()
            guard panel.isVisible else { return }
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            detailPane.isHidden = true
            items = []
            table.reloadData()
        }

        private func describeSelection() {
            describing?.cancel()
            guard let item = selectedItem, let describe else { return }
            describing = Task { @MainActor in
                let resolved = await describe(item)
                guard !Task.isCancelled, selectedItem?.label == item.label else { return }
                let detail = resolved.detail ?? ""
                let documentation = resolved.documentation?.text ?? ""
                let tokens = detail.isEmpty ? [] : (await classify?(detail) ?? [])
                guard !Task.isCancelled, selectedItem?.label == item.label else { return }
                detailField.attributedStringValue = highlighted(detail, tokens: tokens)
                detailField.isHidden = detail.isEmpty
                documentationField.stringValue = documentation
                documentationField.isHidden = documentation.isEmpty
                detailPane.isHidden = detail.isEmpty && documentation.isEmpty
                var frame = panel.frame
                frame.size.width = listWidth + (detailPane.isHidden ? 0 : listWidth)
                panel.setFrame(frame, display: true)
            }
        }

        private func highlighted(_ code: String, tokens: [SemanticToken]) -> NSAttributedString {
            let font = detailField.font ?? NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            let dark = (panel.contentView?.effectiveAppearance ?? NSApp.effectiveAppearance).bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let units = Array(code.utf16)
            let result = NSMutableAttributedString()
            for run in SourceHighlighter.runs(of: code, semanticTokens: tokens, dark: dark) {
                let piece = String(utf16CodeUnits: Array(units[run.range]), count: run.range.count)
                let color = run.color.map(NSColor.init(rgb:)) ?? NSColor.labelColor
                result.append(NSAttributedString(string: piece, attributes: [.font: font, .foregroundColor: color]))
            }
            return result
        }

        @objc private func tableClicked() {
            describeSelection()
        }

        @objc private func tableDoubleClicked() {
            if let item = selectedItem {
                onAccept?(item)
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            items.count
        }

        func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
            let item = items[row]
            if tableColumn?.identifier.rawValue == "kind" {
                return completionKindName(item.kind) ?? ""
            }
            return item.label
        }

        func tableView(_ tableView: NSTableView, willDisplayCell cell: Any, for tableColumn: NSTableColumn?, row: Int) {
            guard let cell = cell as? NSTextFieldCell else { return }
            if tableColumn?.identifier.rawValue == "kind" {
                cell.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
                cell.textColor = .secondaryLabelColor
                cell.alignment = .right
            } else {
                cell.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            describeSelection()
        }
    }

    func completionKindName(_ kind: Int?) -> String? {
        switch kind {
        case 2: return "method"
        case 3: return "function"
        case 4: return "constructor"
        case 5: return "field"
        case 6: return "variable"
        case 7: return "class"
        case 8: return "interface"
        case 9: return "module"
        case 10: return "property"
        case 13: return "enum"
        case 14: return "keyword"
        case 21: return "constant"
        case 25: return "type"
        default: return nil
        }
    }
#endif
