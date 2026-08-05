import CGtk
import Foundation
import Gtk
import GtkSource
import LumaCore
import SwiftyPharo

/// Glamorous Toolkit's class coder: the class's heading above its methods,
/// definition and comment. A class inspected on its own shows here, and an
/// instance's Meta view is its class shown the same way. Mirrors the SwiftUI
/// PharoClassBrowser.
@MainActor
final class PharoClassBrowser {
    let widget: Box

    private let runtime: PharoRuntime
    private let classObject: PharoObject
    private let onSelect: (PharoObject) -> Void
    private let highlight: (GtkSource.Buffer) -> Void
    private let registerEditor: (GtkSource.View) -> Void

    private var methods: [PharoMethodInfo] = []
    private var methodRows: [PharoMethodRow] = []
    private let methodList = Box(orientation: .vertical, spacing: 0)
    private var addEditor: PharoNewMethodEditor?
    private let addSlot = Box(orientation: .vertical, spacing: 0)
    private var query = ""

    private let searchThreshold = 12

    init(
        runtime: PharoRuntime,
        classObject: PharoObject,
        onSelect: @escaping (PharoObject) -> Void,
        highlight: @escaping (GtkSource.Buffer) -> Void,
        registerEditor: @escaping (GtkSource.View) -> Void = { _ in }
    ) {
        self.runtime = runtime
        self.classObject = classObject
        self.onSelect = onSelect
        self.highlight = highlight
        self.registerEditor = registerEditor

        widget = Box(orientation: .vertical, spacing: 0)
        Task { @MainActor in
            guard let info = try? await runtime.classBrowser(of: classObject) else { return }
            self.build(info)
        }
    }

    private func build(_ info: PharoClassBrowserInfo) {
        methods = info.methods
        widget.append(child: header(info))

        let tabs = Notebook()
        tabs.hexpand = true
        tabs.vexpand = true
        tabs.scrollable = true
        _ = tabs.appendPage(child: methodsPage(), tabLabel: tabLabel("Methods"))
        _ = tabs.appendPage(child: sourcePage(info.definition), tabLabel: tabLabel("Definition"))
        _ = tabs.appendPage(child: sourcePage(info.comment), tabLabel: tabLabel("Comment"))
        if !info.examples.isEmpty {
            _ = tabs.appendPage(child: examplesPage(info.examples), tabLabel: tabLabel("Examples"))
        }
        widget.append(child: tabs)
    }

    private func header(_ info: PharoClassBrowserInfo) -> Box {
        let box = Box(orientation: .vertical, spacing: 4)
        box.marginStart = 10
        box.marginEnd = 10
        box.marginTop = 10
        box.marginBottom = 10

        let kind = Label(str: "Class")
        kind.xalign = 0
        kind.add(cssClass: "caption")
        kind.add(cssClass: "dim-label")

        let name = Label(str: info.name)
        name.xalign = 0
        name.add(cssClass: "title-4")

        let meta = Box(orientation: .horizontal, spacing: 16)
        meta.append(child: metaItem("Superclass", info.superclass))
        meta.append(child: metaItem("Package", info.package))
        if !info.tag.isEmpty {
            meta.append(child: metaItem("Tag", info.tag))
        }

        box.append(child: kind)
        box.append(child: name)
        box.append(child: meta)
        return box
    }

    private func metaItem(_ label: String, _ value: String) -> Box {
        let box = Box(orientation: .horizontal, spacing: 4)
        let name = Label(str: label)
        name.add(cssClass: "caption")
        name.add(cssClass: "dim-label")
        let text = Label(str: value)
        text.add(cssClass: "caption")
        text.ellipsize = .end
        box.append(child: name)
        box.append(child: text)
        return box
    }

    private func methodsPage() -> Box {
        let page = Box(orientation: .vertical, spacing: 0)
        page.append(child: methodToolbar())
        page.append(child: addSlot)

        let scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.vexpand = true
        scroll.setPolicy(hscrollbarPolicy: .never, vscrollbarPolicy: .automatic)
        scroll.set(child: methodList)
        page.append(child: scroll)

        rebuildMethodRows()
        return page
    }

    private func methodToolbar() -> Box {
        let bar = Box(orientation: .horizontal, spacing: 6)
        bar.marginStart = 8
        bar.marginEnd = 8
        bar.marginTop = 4
        bar.marginBottom = 4

        if methods.count > searchThreshold {
            let search = SearchEntry()
            search.placeholderText = "Filter methods"
            search.hexpand = true
            search.onSearchChanged { [weak self] entry in
                MainActor.assumeIsolated {
                    self?.query = entry.text
                    self?.rebuildMethodRows()
                }
            }
            bar.append(child: search)
        } else {
            let spacer = Box(orientation: .horizontal, spacing: 0)
            spacer.hexpand = true
            bar.append(child: spacer)
        }

        let add = Button(iconName: "list-add-symbolic")
        add.add(cssClass: "flat")
        add.tooltipText = "Add a method"
        add.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.toggleAddEditor() }
        }
        bar.append(child: add)
        return bar
    }

    private func toggleAddEditor() {
        if addEditor != nil {
            clear(addSlot)
            addEditor = nil
            return
        }
        let editor = PharoNewMethodEditor(
            runtime: runtime,
            classObject: classObject,
            highlight: highlight,
            registerEditor: registerEditor,
            onSaved: { [weak self] in self?.finishAdding() },
            onCancel: { [weak self] in self?.finishAdding() })
        addEditor = editor
        addSlot.append(child: editor.widget)
        addSlot.append(child: Separator(orientation: .horizontal))
    }

    private func finishAdding() {
        clear(addSlot)
        addEditor = nil
        Task { @MainActor in
            guard let info = try? await runtime.classBrowser(of: classObject) else { return }
            methods = info.methods
            rebuildMethodRows()
        }
    }

    private func rebuildMethodRows() {
        clear(methodList)
        methodRows.removeAll()
        for method in shownMethods {
            let row = PharoMethodRow(
                method: method,
                runtime: runtime,
                classObject: classObject,
                onSelect: onSelect,
                highlight: highlight,
                registerEditor: registerEditor)
            methodRows.append(row)
            methodList.append(child: row.widget)
            methodList.append(child: Separator(orientation: .horizontal))
        }
    }

    private var shownMethods: [PharoMethodInfo] {
        guard !query.isEmpty else { return methods }
        let needle = query.lowercased()
        return methods.filter {
            $0.selector.lowercased().contains(needle) || $0.category.lowercased().contains(needle)
        }
    }

    private func examplesPage(_ examples: [PharoExampleMethod]) -> ScrolledWindow {
        let list = Box(orientation: .vertical, spacing: 0)
        for example in examples {
            list.append(child: exampleRow(example))
            list.append(child: Separator(orientation: .horizontal))
        }
        let scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.vexpand = true
        scroll.setPolicy(hscrollbarPolicy: .never, vscrollbarPolicy: .automatic)
        scroll.set(child: list)
        return scroll
    }

    private func exampleRow(_ example: PharoExampleMethod) -> Button {
        let line = Box(orientation: .horizontal, spacing: 8)
        line.marginStart = 10
        line.marginEnd = 10
        line.marginTop = 6
        line.marginBottom = 6

        let icon = Image(iconName: "media-playback-start-symbolic")
        icon.add(cssClass: "accent")
        let selector = Label(str: example.selector)
        selector.add(cssClass: "monospace")
        line.append(child: icon)
        line.append(child: selector)
        if example.side == "class" {
            line.append(child: tagLabel("class"))
        }

        let button = Button()
        button.add(cssClass: "flat")
        button.set(child: line)
        button.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { @MainActor in
                    if let produced = try? await self.runtime.runExample(example, of: self.classObject) {
                        self.onSelect(produced)
                    }
                }
            }
        }
        return button
    }

    private func sourcePage(_ text: String) -> ScrolledWindow {
        let label = Label(str: text)
        label.selectable = true
        label.wrap = true
        label.xalign = 0
        label.yalign = 0
        label.marginStart = 10
        label.marginEnd = 10
        label.marginTop = 8
        label.marginBottom = 8
        label.add(cssClass: "monospace")

        let scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.vexpand = true
        scroll.set(child: label)
        return scroll
    }

    private func tabLabel(_ title: String) -> Box {
        let box = Box(orientation: .horizontal, spacing: 0)
        box.append(child: Label(str: title))
        return box
    }

    private func clear(_ box: Box) {
        while let existing = box.getFirstChild() {
            box.remove(child: existing)
        }
    }
}

/// A tag pill for a method's side or category, the way the coder marks them.
@MainActor
func tagLabel(_ text: String) -> Label {
    let label = Label(str: text)
    label.add(cssClass: "caption")
    label.add(cssClass: "luma-pharo-tag")
    label.ellipsize = .middle
    return label
}
