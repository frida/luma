import Foundation
import Gtk
import LumaCore

@MainActor
final class SwiftTypePane {
    let widget: Box

    private weak var engine: Engine?
    private let sessionID: UUID
    private let module: LumaCore.ProcessModule
    private let type: SwiftTypeSummary
    private let inheritanceLabel: Label
    private let sections: Box

    private var loadTask: Task<Void, Never>?

    init(engine: Engine, sessionID: UUID, module: LumaCore.ProcessModule, type: SwiftTypeSummary) {
        self.engine = engine
        self.sessionID = sessionID
        self.module = module
        self.type = type

        widget = Box(orientation: .vertical, spacing: 6)
        widget.marginStart = 12
        widget.marginEnd = 12
        widget.marginTop = 12
        widget.marginBottom = 12

        let titleLabel = Label(str: "\(type.kind.rawValue) \(type.displayName(inModule: module.name))")
        titleLabel.halign = .start
        titleLabel.add(cssClass: "heading")
        titleLabel.selectable = true

        inheritanceLabel = Label(str: "")
        inheritanceLabel.halign = .start
        inheritanceLabel.wrap = true
        inheritanceLabel.selectable = true
        inheritanceLabel.add(cssClass: "dim-label")
        inheritanceLabel.visible = false

        sections = Box(orientation: .vertical, spacing: 12)
        sections.marginTop = 6
        sections.append(child: makeMessage("Loading\u{2026}"))

        let scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.vexpand = true
        scroll.set(child: sections)

        widget.append(child: titleLabel)
        widget.append(child: inheritanceLabel)
        widget.append(child: scroll)

        load()
    }

    deinit {
        loadTask?.cancel()
    }

    private func load() {
        guard let node = engine?.node(forSessionID: sessionID) else {
            showOnly(makeMessage("Process detached"))
            return
        }
        let moduleName = module.name
        let type = type
        loadTask = Task { @MainActor [weak self] in
            do {
                let description = try await node.describeSwiftType(module: moduleName, type: type)
                guard let self, !Task.isCancelled else { return }
                self.render(description)
            } catch {
                guard let self else { return }
                self.showOnly(self.makeMessage(error.localizedDescription))
            }
        }
    }

    private func render(_ description: SwiftTypeDescription) {
        if !description.inheritance.isEmpty {
            inheritanceLabel.setText(str: description.inheritance.joined(separator: ", "))
            inheritanceLabel.visible = true
        }
        showOnly(nil)
        if !description.members.isEmpty {
            appendSection("Members", rows: description.members.map(makeMemberRow))
        }
        if !description.conformers.isEmpty {
            appendSection("Conforming Types", rows: description.conformers.map { makeTextRow($0, detail: nil) })
        }
        appendSection("Functions", rows: description.functions.map(makeFunctionRow))
    }

    private func showOnly(_ content: Widget?) {
        while let child = sections.firstChild {
            sections.remove(child: child)
        }
        if let content {
            sections.append(child: content)
        }
    }

    private func appendSection(_ title: String, rows: [ListBoxRow]) {
        let heading = Label(str: title)
        heading.halign = .start
        heading.add(cssClass: "caption-heading")
        heading.add(cssClass: "dim-label")

        let list = ListBox()
        list.selectionMode = .none
        list.add(cssClass: "boxed-list")
        for row in rows {
            list.append(child: row)
        }
        if rows.isEmpty {
            list.append(child: makeTextRow("None", detail: nil))
        }

        sections.append(child: heading)
        sections.append(child: list)
    }

    private func makeMemberRow(_ member: SwiftTypeDescription.Member) -> ListBoxRow {
        let title = member.typeName.map { "\(member.name): \($0)" } ?? member.name
        return makeTextRow(title, detail: member.role.title)
    }

    private func makeFunctionRow(_ function: SwiftTypeDescription.Function) -> ListBoxRow {
        let row = makeTextRow(function.name, detail: String(format: "0x%llx", function.address), monospacedDetail: true)
        row.tooltipText = function.name
        let context = AddressContext(kind: .function, anchorHint: function.anchor)

        let click = GestureClick()
        click.set(button: 1)
        click.onPressed { [weak self] _, nPress, _, _ in
            MainActor.assumeIsolated {
                guard Int(nPress) == 2, let self, let engine = self.engine else { return }
                AddressActionMenu.openInsight(
                    engine: engine,
                    sessionID: self.sessionID,
                    address: function.address,
                    kind: .disassembly,
                    preferredAnchor: function.anchor,
                    failureLabel: "Can\u{2019}t open"
                )
            }
        }
        row.add(controller: click)

        let menu = GestureClick()
        menu.set(button: 3)
        menu.propagationPhase = .capture
        menu.onPressed { [weak self] gesture, _, x, y in
            MainActor.assumeIsolated {
                guard let self, let engine = self.engine else { return }
                _ = gesture.set(state: .claimed)
                AddressActionMenu.present(
                    at: gesture.widget!, x: x, y: y, engine: engine, sessionID: self.sessionID,
                    address: function.address, value: String(format: "0x%llx", function.address),
                    copyLabel: "Copy Address", context: context)
            }
        }
        row.add(controller: menu)

        return row
    }

    private func makeTextRow(_ title: String, detail: String?, monospacedDetail: Bool = false) -> ListBoxRow {
        let box = Box(orientation: .horizontal, spacing: 12)
        box.marginStart = 12
        box.marginEnd = 12
        box.marginTop = 6
        box.marginBottom = 6

        let titleLabel = Label(str: title)
        titleLabel.halign = .start
        titleLabel.hexpand = true
        titleLabel.xalign = 0
        titleLabel.ellipsize = .middle
        box.append(child: titleLabel)

        if let detail {
            let detailLabel = Label(str: detail)
            detailLabel.halign = .end
            detailLabel.add(cssClass: "dim-label")
            detailLabel.add(cssClass: monospacedDetail ? "monospace" : "caption")
            box.append(child: detailLabel)
        }

        let row = ListBoxRow()
        row.set(child: box)
        return row
    }

    private func makeMessage(_ text: String) -> Widget {
        let label = Label(str: text)
        label.add(cssClass: "dim-label")
        label.halign = .start
        label.wrap = true
        return label
    }
}
