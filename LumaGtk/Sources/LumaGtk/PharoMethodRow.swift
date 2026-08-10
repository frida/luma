import CGtk
import Foundation
import GLibObject
import Gtk
import GtkSource
import LumaCore
import SwiftyPharo

/// One method in the class coder: its name and tags, opening to its source in an
/// editor that saves back to the class. A class it names can be drilled from the
/// editor too. Mirrors the SwiftUI PharoMethodRow.
@MainActor
final class PharoMethodRow {
    let widget: Box

    private let method: PharoMethodInfo
    private let runtime: PharoRuntime
    private let classObject: PharoObject
    private let onSelect: (PharoObject) -> Void
    private let highlight: (GtkSource.Buffer) -> Void
    private let registerEditor: (GtkSource.View) -> Void

    private let body = Box(orientation: .vertical, spacing: 4)
    private var editor: PharoInlineMethodEditor?

    init(
        method: PharoMethodInfo,
        runtime: PharoRuntime,
        classObject: PharoObject,
        onSelect: @escaping (PharoObject) -> Void,
        highlight: @escaping (GtkSource.Buffer) -> Void,
        registerEditor: @escaping (GtkSource.View) -> Void = { _ in }
    ) {
        self.method = method
        self.runtime = runtime
        self.classObject = classObject
        self.onSelect = onSelect
        self.highlight = highlight
        self.registerEditor = registerEditor

        widget = Box(orientation: .vertical, spacing: 0)
        widget.append(child: heading())
        body.marginStart = 4
        body.marginEnd = 4
        body.marginBottom = 6
        body.visible = false
        widget.append(child: body)
    }

    private func heading() -> Button {
        let line = Box(orientation: .horizontal, spacing: 8)
        line.marginStart = 8
        line.marginEnd = 8
        line.marginTop = 6
        line.marginBottom = 6

        let selector = Label(str: method.selector)
        selector.add(cssClass: "monospace")
        selector.add(cssClass: "heading")
        selector.xalign = 0
        selector.hexpand = true
        line.append(child: selector)

        if isClassified {
            let category = tagLabel(method.category)
            category.maxWidthChars = 18
            line.append(child: category)
        }
        line.append(child: tagLabel(method.side))

        let button = Button()
        button.add(cssClass: "flat")
        button.set(child: line)
        button.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.toggle() }
        }
        return button
    }

    private func toggle() {
        if body.visible {
            body.visible = false
            return
        }
        if editor == nil {
            let editor = PharoInlineMethodEditor(
                source: method.source,
                runtime: runtime,
                highlight: highlight,
                registerEditor: registerEditor,
                onSelect: onSelect,
                onSave: { [weak self] source in await self?.save(source) })
            self.editor = editor
            body.append(child: editor.widget)
        }
        body.visible = true
    }

    private func save(_ source: String) async {
        do {
            _ = try await runtime.compileMethod(
                in: classObject, side: method.side, category: method.category, source: source)
            editor?.markSaved()
        } catch {
            editor?.showError(error.localizedDescription)
        }
    }

    /// Pharo's placeholder category is not one worth a tag of its own.
    private var isClassified: Bool {
        !method.category.isEmpty && method.category != "as yet unclassified"
    }
}

/// The source editor a method row or the add-method coder opens: highlighted
/// Smalltalk with a Save that lights up once the text drifts from what the image
/// holds, and a note where the image refuses the compile.
@MainActor
final class PharoInlineMethodEditor {
    let widget: Box

    private let buffer: GtkSource.Buffer
    private let find: PharoFindBar
    private let save = Button(label: "Save")
    private let failure = Label(str: "")
    private let onSave: (String) async -> Void
    private var savedSource: String

    init(
        source: String,
        runtime: PharoRuntime,
        highlight: @escaping (GtkSource.Buffer) -> Void,
        registerEditor: @escaping (GtkSource.View) -> Void = { _ in },
        onSelect: @escaping (PharoObject) -> Void,
        onSave: @escaping (String) async -> Void
    ) {
        self.onSave = onSave
        savedSource = source

        buffer = GtkSource.Buffer(table: Gtk.TextTagTable?.none)
        buffer.set(text: source, len: source.utf8.count)
        highlight(buffer)

        let view = GtkSource.View(buffer: buffer)
        view.monospace = true
        view.leftMargin = 8
        view.topMargin = 6
        view.bottomMargin = 6
        registerEditor(view)
        find = PharoFindBar(editor: view, buffer: buffer)

        let scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.setPolicy(hscrollbarPolicy: .automatic, vscrollbarPolicy: .never)
        scroll.propagateNaturalHeight = true
        scroll.maxContentHeight = 220
        scroll.set(child: view)

        failure.xalign = 0
        failure.wrap = true
        failure.add(cssClass: "error")
        failure.add(cssClass: "caption")
        failure.visible = false

        save.add(cssClass: "suggested-action")
        save.halign = .end
        save.visible = false

        let actions = Box(orientation: .horizontal, spacing: 8)
        actions.append(child: failure)
        let spacer = Box(orientation: .horizontal, spacing: 0)
        spacer.hexpand = true
        actions.append(child: spacer)
        actions.append(child: save)

        widget = Box(orientation: .vertical, spacing: 4)
        widget.append(child: find.widget)
        widget.append(child: scroll)
        widget.append(child: actions)

        buffer.onChanged { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDirty() }
        }
        save.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let edited = self.buffer.text
                Task { @MainActor in await self.onSave(edited) }
            }
        }
    }

    func markSaved() {
        savedSource = buffer.text
        failure.visible = false
        refreshDirty()
    }

    func showError(_ message: String) {
        failure.setText(str: message)
        failure.visible = true
    }

    private func refreshDirty() {
        save.visible = buffer.text != savedSource
    }
}

/// The coder GT opens from the Methods view's "+": a template method whose
/// source, side and category the reader sets before it is compiled in. Mirrors
/// the SwiftUI PharoNewMethodEditor.
@MainActor
final class PharoNewMethodEditor {
    let widget: Box

    private let runtime: PharoRuntime
    private let classObject: PharoObject
    private let buffer: GtkSource.Buffer
    private let category = Entry()
    private let side: DropDown
    private let failure = Label(str: "")
    private let onSaved: () -> Void

    init(
        runtime: PharoRuntime,
        classObject: PharoObject,
        highlight: @escaping (GtkSource.Buffer) -> Void,
        registerEditor: @escaping (GtkSource.View) -> Void = { _ in },
        onSaved: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.runtime = runtime
        self.classObject = classObject
        self.onSaved = onSaved
        side = PharoNewMethodEditor.sideDropdown()

        buffer = GtkSource.Buffer(table: Gtk.TextTagTable?.none)
        buffer.set(text: "newMethod", len: "newMethod".utf8.count)
        highlight(buffer)

        let view = GtkSource.View(buffer: buffer)
        view.monospace = true
        view.leftMargin = 8
        view.topMargin = 6
        view.bottomMargin = 6
        registerEditor(view)

        let scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.setPolicy(hscrollbarPolicy: .automatic, vscrollbarPolicy: .never)
        scroll.propagateNaturalHeight = true
        scroll.maxContentHeight = 160
        scroll.set(child: view)

        category.placeholderText = "category"
        category.hexpand = true

        failure.add(cssClass: "error")
        failure.add(cssClass: "caption")
        failure.visible = false

        let compile = Button(iconName: "emblem-ok-symbolic")
        compile.add(cssClass: "suggested-action")
        compile.tooltipText = "Compile"
        let discard = Button(iconName: "user-trash-symbolic")
        discard.tooltipText = "Discard"

        let actions = Box(orientation: .horizontal, spacing: 6)
        actions.append(child: compile)
        actions.append(child: discard)
        actions.append(child: failure)
        actions.append(child: category)
        actions.append(child: side)

        widget = Box(orientation: .vertical, spacing: 6)
        widget.append(child: scroll)
        widget.append(child: actions)

        compile.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.compile() }
        }
        discard.onClicked { _ in
            MainActor.assumeIsolated { onCancel() }
        }
    }

    private func compile() {
        let source = buffer.text
        let chosen = side.selected == 1 ? "class" : "instance"
        let typed = category.text ?? ""
        let group = typed.isEmpty ? "as yet unclassified" : typed
        Task { @MainActor in
            do {
                _ = try await runtime.compileMethod(in: classObject, side: chosen, category: group, source: source)
                onSaved()
            } catch {
                failure.setText(str: error.localizedDescription)
                failure.visible = true
            }
        }
    }

    private static func sideDropdown() -> DropDown {
        let labels = ["instance", "class"]
        let cStrings = labels.map { strdup($0) }
        defer { cStrings.forEach { free($0) } }
        var ptrs = cStrings.map { UnsafePointer($0) as UnsafePointer<CChar>? }
        ptrs.append(nil)
        let widgetPtr = ptrs.withUnsafeBufferPointer { gtk_drop_down_new_from_strings($0.baseAddress) }!
        g_object_ref_sink(UnsafeMutableRawPointer(widgetPtr))
        return DropDown(raw: UnsafeMutableRawPointer(widgetPtr))
    }
}
