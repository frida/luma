import CGtk
import Foundation
import Gdk
import Gtk
import GtkSource
import LumaCore

@MainActor
final class CodeSignatureHelp {
    var document: TypeScriptDocument?

    private let editor: GtkSource.View
    private let buffer: GtkSource.Buffer
    private var popover: Popover?
    private var signatureLabel: Label?
    private var documentationLabel: Label?
    private var generation: UInt = 0
    private var pending: Task<Void, Never>?

    init(editor: GtkSource.View, buffer: GtkSource.Buffer) {
        self.editor = editor
        self.buffer = buffer
        installTriggers()
    }

    private func installTriggers() {
        buffer.onInsertText { [weak self] _, _, text, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if text == "(" || text == "," || self.isActive {
                    self.scheduleRequest()
                }
            }
        }
        buffer.onDeleteRange { [weak self] _, _, _ in
            MainActor.assumeIsolated {
                guard let self, self.isActive else { return }
                self.scheduleRequest()
            }
        }
    }

    private func scheduleRequest() {
        Task { @MainActor in self.request() }
    }

    var isActive: Bool { popover != nil }

    func request() {
        guard let document else { return }
        let text = buffer.text
        let cursorUTF16 = CharacterOffsets(text: text).utf16Offset(ofCharacter: cursorOffset())
        let position = LineMap(text: text).position(ofUTF16Offset: cursorUTF16)
        generation &+= 1
        let generationAtRequest = generation
        pending?.cancel()
        pending = Task { @MainActor in
            let answer = try? await document.signatureHelp(at: position)
            guard generation == generationAtRequest else { return }
            guard let help = answer, !help.signatures.isEmpty else {
                dismiss()
                return
            }
            show(help)
        }
    }

    func handleKey(_ keyval: UInt) -> Bool {
        guard isActive, Int32(keyval) == Gdk.keyEscape else { return false }
        dismiss()
        return true
    }

    private func show(_ help: LSP.SignatureHelp) {
        let signature = help.signatures[min(help.activeSignature ?? 0, help.signatures.count - 1)]
        let activeParameter = signature.activeParameter ?? help.activeParameter ?? 0
        if popover == nil {
            build()
        }
        signatureLabel?.setMarkup(str: markup(for: signature, activeParameter: activeParameter))
        let documentation = (signature.parameters ?? [])[safe: activeParameter]?.documentation?.text
            ?? signature.documentation?.text
        documentationLabel?.text = documentation ?? ""
        documentationLabel?.visible = !(documentation ?? "").isEmpty
        if let popover {
            pointAtCaret(popover)
            if !popover.visible {
                popover.popup()
            }
        }
    }

    private func build() {
        let popover = Popover()
        popover.autohide = false
        popover.canFocus = false
        popover.position = .top

        let signature = Label(str: "")
        signature.add(cssClass: "monospace")
        signature.useMarkup = true
        signature.halign = .start
        signature.xalign = 0
        signature.wrap = true
        signature.maxWidthChars = 80

        let documentation = Label(str: "")
        documentation.add(cssClass: "dim-label")
        documentation.halign = .start
        documentation.xalign = 0
        documentation.wrap = true
        documentation.maxWidthChars = 80

        let column = Box(orientation: .vertical, spacing: 4)
        column.marginStart = 10
        column.marginEnd = 10
        column.marginTop = 6
        column.marginBottom = 6
        column.append(child: signature)
        column.append(child: documentation)
        popover.set(child: column)
        popover.set(parent: editor)

        self.popover = popover
        signatureLabel = signature
        documentationLabel = documentation
    }

    private func markup(for signature: LSP.SignatureInformation, activeParameter: Int) -> String {
        let label = signature.label
        guard let parameter = (signature.parameters ?? [])[safe: activeParameter],
            let range = parameterRange(parameter, in: label)
        else { return escaped(label) }
        return escaped(label.utf16Substring(0..<range.lowerBound))
            + "<b>" + escaped(label.utf16Substring(range)) + "</b>"
            + escaped(label.utf16Substring(range.upperBound..<label.utf16.count))
    }

    private func parameterRange(_ parameter: LSP.ParameterInformation, in label: String) -> Swift.Range<Int>? {
        switch parameter.label {
        case .offsets(let start, let end):
            return start..<min(end, label.utf16.count)
        case .text(let text):
            guard let found = label.range(of: text) else { return nil }
            let start = label.utf16.distance(from: label.utf16.startIndex, to: found.lowerBound)
            return start..<(start + text.utf16.count)
        }
    }

    private func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func pointAtCaret(_ popover: Popover) {
        var strong = GdkRectangle(x: 0, y: 0, width: 0, height: 0)
        let textView = UnsafeMutablePointer<GtkTextView>(OpaquePointer(editor.view_ptr))
        withUnsafeMutablePointer(to: &strong) { gtk_text_view_get_cursor_locations(textView, nil, $0, nil) }
        var windowX: gint = 0
        var windowY: gint = 0
        editor.bufferToWindowCoords(
            win: .widget,
            bufferX: Int(strong.x),
            bufferY: Int(strong.y),
            windowX: &windowX,
            windowY: &windowY
        )
        var rect = GdkRectangle(x: windowX, y: windowY, width: 1, height: strong.height)
        withUnsafeMutablePointer(to: &rect) { gtk_popover_set_pointing_to(popover.popover_ptr, $0) }
    }

    func dismiss() {
        generation &+= 1
        pending?.cancel()
        pending = nil
        popover?.popdown()
        popover?.unparent()
        popover = nil
        signatureLabel = nil
        documentationLabel = nil
    }

    private func cursorOffset() -> Int {
        let storage = UnsafeMutablePointer<GtkTextIter>.allocate(capacity: 1)
        defer { storage.deallocate() }
        let iter = TextIter(storage)
        buffer.getIterAtMark(iter: iter, mark: buffer.getInsert())
        return Int(iter.offset)
    }
}
