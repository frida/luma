import CCairo
import CGtk
import Cairo
import Foundation
import Gdk
import Gtk
import GtkSource
import LumaCore
import SwiftyPharo

/// The expandable marks Glamorous Toolkit puts beside a reference: a triangle
/// after each class or method a snippet names. Clicking one breaks the line and
/// drops its body -- an inspector for a class, an editor for a method -- onto a
/// line of its own, with the rest of the code carried below it. The marks and
/// bodies live in the buffer as child anchors, so the source the reader edits is
/// the text with those anchor characters and body lines taken back out.
@MainActor
final class PharoInlineMarks {
    /// The object replacement character a child anchor occupies.
    private static let anchorScalar: Character = "\u{FFFC}"

    var isApplying: Bool { applying }

    private let editor: GtkSource.View
    private let buffer: GtkSource.Buffer
    private let runtime: PharoRuntime
    private let selfClass: String?
    private let highlight: (GtkSource.Buffer) -> Void

    private enum Kind {
        case classReference(String)
        case methodReference(PharoMethodReference)
    }

    private final class Mark {
        let id: String
        let kind: Kind
        let area: DrawingArea
        let anchor: TextChildAnchor
        var body: Body?
        var hovered = false

        init(id: String, kind: Kind, area: DrawingArea, anchor: TextChildAnchor) {
            self.id = id
            self.kind = kind
            self.area = area
            self.anchor = anchor
        }
    }

    private final class Body {
        let widget: Box
        let anchor: TextChildAnchor

        init(widget: Box, anchor: TextChildAnchor) {
            self.widget = widget
            self.anchor = anchor
        }
    }

    private var marks: [String: Mark] = [:]
    private var referencedSource: String?
    private var pending: Task<Void, Never>?
    private var applying = false

    init(
        editor: GtkSource.View,
        buffer: GtkSource.Buffer,
        runtime: PharoRuntime,
        selfClass: String?,
        highlight: @escaping (GtkSource.Buffer) -> Void
    ) {
        self.editor = editor
        self.buffer = buffer
        self.runtime = runtime
        self.selfClass = selfClass
        self.highlight = highlight
    }

    // MARK: - Source the reader sees, without the carried characters

    var source: String {
        let carried = carriedOffsets()
        let characters = Array(bufferText())
        var kept: [Character] = []
        for (offset, character) in characters.enumerated() where !carried.contains(offset) {
            kept.append(character)
        }
        return String(kept)
    }

    /// The buffer's text with the anchor characters kept, since their offsets are
    /// the ones the iters count; plain get-text drops them and throws the offsets
    /// out of step with the marks.
    private func bufferText() -> String {
        withIters { start, end in
            buffer.getBounds(start: start, end: end)
            return buffer.getSlice(start: start, end: end, includeHiddenChars: true) ?? ""
        }
    }

    func sourceCursor() -> Int {
        let cursor = cursorOffset()
        return cursor - carriedOffsets().filter { $0 < cursor }.count
    }

    /// Every buffer offset the source does not count: each mark anchor, each body
    /// anchor, and the newline standing on either side of a body.
    private func carriedOffsets() -> Set<Int> {
        var carried: Set<Int> = []
        for mark in marks.values {
            if let offset = offset(of: mark.anchor) {
                carried.insert(offset)
            }
            if let body = mark.body, let offset = offset(of: body.anchor) {
                carried.insert(offset - 1)
                carried.insert(offset)
                carried.insert(offset + 1)
            }
        }
        return carried
    }

    // MARK: - Reconciling marks with the references the snippet names

    func refresh() {
        let source = self.source
        guard referencedSource != source else { return }

        pending?.cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled, self.source == source else { return }
            let classes = (try? await runtime.classReferences(in: source)) ?? []
            let methods = (try? await runtime.methodReferences(in: source, selfClass: selfClass)) ?? []
            guard self.source == source else { return }
            referencedSource = source
            reconcile(classes: classes, methods: methods)
        }
    }

    private func reconcile(classes: [PharoClassReference], methods: [PharoMethodReference]) {
        var candidates: [(id: String, stop: Int, kind: Kind)] = []
        for reference in classes {
            candidates.append((markID(class: reference.name), reference.stop, .classReference(reference.name)))
        }
        for reference in methods {
            candidates.append((markID(method: reference), reference.stop, .methodReference(reference)))
        }

        // One triangle to a spot: a send the image resolves to several receivers
        // reports a reference each, all ending together, and a class over a method
        // where both land on the same character.
        var wanted: [(id: String, stop: Int, kind: Kind)] = []
        var claimed: Set<Int> = []
        for candidate in candidates where claimed.insert(candidate.stop).inserted {
            wanted.append(candidate)
        }

        let wantedIDs = Set(wanted.map(\.id))
        applying = true
        defer { applying = false }

        // The caret is held in source terms across the shuffle so it lands where
        // the reader left it -- before a mark that a completion just dropped in,
        // not behind it, where the next keystroke would edit the class name. A
        // range is left alone: a keyword template's selected placeholder must
        // survive the marks it also drops in.
        let caret = sourceCursor()
        let selecting = hasSelection()

        for (id, mark) in marks where !wantedIDs.contains(id) || mark.anchor.deleted {
            remove(mark)
            marks[id] = nil
        }

        // Place the missing marks from the back, so inserting one never shifts the
        // source offset of another still to be placed.
        let missing = wanted.filter { marks[$0.id] == nil }.sorted { $0.stop > $1.stop }
        for entry in missing {
            place(id: entry.id, kind: entry.kind, atSource: entry.stop)
        }

        if !selecting { setCaret(toSource: caret) }
    }

    private func hasSelection() -> Bool {
        withIters { start, end in
            buffer.getSelectionBounds(start: start, end: end)
        }
    }

    /// Slide over a mark's anchor so it is not an extra cursor stop, and a space
    /// typed at a token's end lands past its mark to carry the send on. Returns
    /// whether the key is spent; a space is not, so it still types once moved.
    func handleCursorKey(_ keyval: UInt, shift: Bool) -> Bool {
        let cursor = cursorOffset()
        switch keyval {
        case 0xFF53 where !shift && anchorAt(cursor + 1):  // Right
            moveCursor(to: skipForward(from: cursor + 1))
            return true
        case 0xFF51 where !shift && anchorAt(cursor - 1):  // Left
            moveCursor(to: skipBackward(from: cursor - 1))
            return true
        case 0x0020 where anchorAt(cursor):  // space
            moveCursor(to: skipForward(from: cursor))
            return false
        default:
            return false
        }
    }

    private func anchorAt(_ offset: Int) -> Bool {
        guard offset >= 0, offset < Int(buffer.getCharCount()) else { return false }
        return withIter { iter in
            buffer.getIterAtOffset(iter: iter, charOffset: offset)
            return iter.childAnchor != nil
        }
    }

    private func skipForward(from offset: Int) -> Int {
        var at = offset
        while anchorAt(at) { at += 1 }
        return at
    }

    private func skipBackward(from offset: Int) -> Int {
        var at = offset
        while at > 0, anchorAt(at) { at -= 1 }
        return at
    }

    private func moveCursor(to offset: Int) {
        withIter { iter in
            buffer.getIterAtOffset(iter: iter, charOffset: offset)
            buffer.placeCursor(where: iter)
        }
    }

    private func setCaret(toSource sourceOffset: Int) {
        let offset = bufferOffset(forSource: sourceOffset)
        withIter { iter in
            buffer.getIterAtOffset(iter: iter, charOffset: offset)
            buffer.placeCursor(where: iter)
        }
    }

    private func markID(class name: String) -> String { "class:\(name)" }
    private func markID(method reference: PharoMethodReference) -> String {
        "method:\(reference.className)>>\(reference.side)>>\(reference.selector)"
    }

    private func place(id: String, kind: Kind, atSource sourceStop: Int) {
        guard marks[id] == nil else { return }
        let bufferOffset = self.bufferOffset(forSource: sourceStop)
        let anchor: TextChildAnchor? = withIter { iter in
            buffer.getIterAtOffset(iter: iter, charOffset: Int(bufferOffset))
            guard let created = buffer.createChildAnchor(iter: iter) else { return nil }
            return TextChildAnchor(textChildAnchor: created)
        }
        guard let anchor else { return }

        let area = DrawingArea()
        area.setSizeRequest(width: 15, height: 16)
        area.valign = .center
        area.tooltipText = "Open"
        let mark = Mark(id: id, kind: kind, area: area, anchor: anchor)

        area.setDrawFunc { [weak mark] _, ctx, width, height in
            MainActor.assumeIsolated {
                guard let mark else { return }
                self.drawMark(ctx, Double(width), Double(height), open: mark.body != nil, hovered: mark.hovered)
            }
        }
        let click = GestureClick()
        click.onReleased { [weak self, weak mark] _, _, _, _ in
            MainActor.assumeIsolated {
                guard let self, let mark else { return }
                self.toggle(mark)
            }
        }
        area.install(controller: click)
        let motion = EventControllerMotion()
        motion.onEnter { [weak mark] _, _, _ in
            MainActor.assumeIsolated {
                mark?.hovered = true
                mark?.area.queueDraw()
            }
        }
        motion.onLeave { [weak mark] _ in
            MainActor.assumeIsolated {
                mark?.hovered = false
                mark?.area.queueDraw()
            }
        }
        area.install(controller: motion)

        editor.addChildAtAnchor(child: area, anchor: anchor)
        marks[id] = mark
    }

    private func remove(_ mark: Mark) {
        close(mark)
        deleteAnchorCharacter(mark.anchor)
    }

    /// The circled chevron the SwiftUI editor draws by an open reference: an
    /// outlined ring with a right chevron at rest, a filled brand ring with a
    /// down chevron once its body is open, and the brand tint under the pointer.
    private func drawMark(_ ctx: Cairo.ContextRef, _ width: Double, _ height: Double, open: Bool, hovered: Bool) {
        let palette = PharoVizColors.current
        let centerX = width / 2
        let centerY = height / 2
        let radius = 5.5
        let accent = open || hovered
        let ring = accent ? PharoVizColors.brand : palette.label
        ctx.lineWidth = 1.2

        if open {
            ctx.setSource(red: ring.r, green: ring.g, blue: ring.b, alpha: 1)
            cairo_arc(ctx.context_ptr, centerX, centerY, radius, 0, 2 * Double.pi)
            ctx.fill()
            let mark = palette.nodeFill
            ctx.setSource(red: mark.r, green: mark.g, blue: mark.b, alpha: 1)
            ctx.moveTo(centerX - 2.4, centerY - 1.2)
            ctx.lineTo(centerX, centerY + 1.6)
            ctx.lineTo(centerX + 2.4, centerY - 1.2)
            ctx.stroke()
        } else {
            ctx.setSource(red: ring.r, green: ring.g, blue: ring.b, alpha: accent ? 1 : 0.55)
            cairo_arc(ctx.context_ptr, centerX, centerY, radius, 0, 2 * Double.pi)
            ctx.stroke()
            ctx.moveTo(centerX - 1.2, centerY - 2.4)
            ctx.lineTo(centerX + 1.6, centerY)
            ctx.lineTo(centerX - 1.2, centerY + 2.4)
            ctx.stroke()
        }
    }

    // MARK: - Opening and closing a body

    private func toggle(_ mark: Mark) {
        if mark.body != nil {
            close(mark)
            return
        }
        Task { @MainActor in await open(mark) }
    }

    private func open(_ mark: Mark) async {
        guard let content = await bodyContent(for: mark.kind) else { return }
        guard mark.body == nil, !mark.anchor.deleted else { return }
        insertBody(content, after: mark)
    }

    private func bodyContent(for kind: Kind) async -> Box? {
        switch kind {
        case .classReference(let name):
            guard let object = try? await runtime.evaluate(name) else { return nil }
            let view = PharoColumnView(runtime: runtime, object: object, isMaximized: false)
            view.widget.hexpand = true
            view.widget.vexpand = true
            let frame = Box(orientation: .vertical, spacing: 0)
            frame.append(child: view.widget)
            classColumns[ObjectIdentifier(frame)] = view
            return frame
        case .methodReference(let reference):
            return methodEditor(for: reference)
        }
    }

    private var classColumns: [ObjectIdentifier: PharoColumnView] = [:]

    private func methodEditor(for reference: PharoMethodReference) -> Box {
        let container = Box(orientation: .vertical, spacing: 6)
        container.add(cssClass: "luma-pharo-method-body")
        container.marginTop = 4
        container.marginBottom = 4

        let heading = Label(str: "\(reference.className) \u{203A} \(reference.selector)")
        heading.xalign = 0
        heading.add(cssClass: "caption-heading")
        heading.add(cssClass: "dim-label")

        let methodBuffer = GtkSource.Buffer(table: Gtk.TextTagTable?.none)
        methodBuffer.set(text: reference.source, len: Int(reference.source.utf8.count))
        highlight(methodBuffer)
        let methodView = GtkSource.View(buffer: methodBuffer)
        methodView.monospace = true
        methodView.add(cssClass: "luma-pharo-method-editor")
        methodView.leftMargin = 8
        methodView.topMargin = 6
        methodView.bottomMargin = 6

        let scroll = ScrolledWindow()
        scroll.setPolicy(hscrollbarPolicy: .automatic, vscrollbarPolicy: .never)
        scroll.propagateNaturalHeight = true
        scroll.maxContentHeight = 220
        scroll.set(child: methodView)

        let save = Button(label: "Save")
        save.add(cssClass: "suggested-action")
        save.halign = .start
        save.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let edited = methodBuffer.text
                Task { @MainActor in await self.saveMethod(reference, source: edited) }
            }
        }

        container.append(child: heading)
        container.append(child: scroll)
        container.append(child: save)
        return container
    }

    private func saveMethod(_ reference: PharoMethodReference, source: String) async {
        guard let classObject = try? await runtime.evaluate(reference.className) else { return }
        _ = try? await runtime.compileMethod(
            in: classObject,
            side: reference.side,
            category: reference.category,
            source: source)
    }

    /// A body sits on a line of its own right after its mark: a newline closes the
    /// code line, the anchor holds the body, and a newline carries the rest of the
    /// send down below it.
    private func insertBody(_ widget: Box, after mark: Mark) {
        applying = true
        defer { applying = false }

        guard let markOffset = offset(of: mark.anchor) else { return }
        let at = Int(markOffset) + 1

        let anchor: TextChildAnchor? = withIter { iter in
            buffer.getIterAtOffset(iter: iter, charOffset: at)
            buffer.getInsert(iter: iter, text: "\n", len: 1)
            buffer.getIterAtOffset(iter: iter, charOffset: at + 1)
            guard let created = buffer.createChildAnchor(iter: iter) else { return nil }
            buffer.getIterAtOffset(iter: iter, charOffset: at + 2)
            buffer.getInsert(iter: iter, text: "\n", len: 1)
            return TextChildAnchor(textChildAnchor: created)
        }
        guard let anchor else { return }

        widget.hexpand = true
        widget.add(cssClass: "luma-pharo-body")
        sizeBody(widget)
        editor.addChildAtAnchor(child: widget, anchor: anchor)
        mark.body = Body(widget: widget, anchor: anchor)
        mark.area.queueDraw()
    }

    /// An anchored widget keeps to its own size rather than the text's, so a body
    /// is given the editor's width and stood tall, the way it fills the page on
    /// the SwiftUI side. Reapplied as bodies open so a widened window carries.
    private func sizeBody(_ widget: Box) {
        let width = max(editor.getWidth() - 20, 260)
        widget.setSizeRequest(width: width, height: 380)
    }

    private func resizeBodies() {
        for mark in marks.values {
            if let body = mark.body { sizeBody(body.widget) }
        }
    }

    private func close(_ mark: Mark) {
        guard let body = mark.body else { return }
        mark.body = nil
        mark.area.queueDraw()
        classColumns[ObjectIdentifier(body.widget)] = nil

        applying = true
        defer { applying = false }

        guard let anchorOffset = offset(of: body.anchor) else { return }
        // Delete the newline before, the anchor, and the newline after.
        withIters { start, end in
            buffer.getIterAtOffset(iter: start, charOffset: Int(anchorOffset) - 1)
            buffer.getIterAtOffset(iter: end, charOffset: Int(anchorOffset) + 2)
            buffer.delete(start: start, end: end)
        }
    }

    // MARK: - Offsets

    private func bufferOffset(forSource sourceOffset: Int) -> Int {
        let carried = carriedOffsets()
        var seen = 0
        var offset = 0
        let total = buffer.getCharCount()
        while offset < Int(total) {
            if seen == sourceOffset { return offset }
            if !carried.contains(offset) { seen += 1 }
            offset += 1
        }
        return Int(total)
    }

    private func offset(of anchor: TextChildAnchor) -> Int? {
        guard !anchor.deleted else { return nil }
        return withIter { iter in
            buffer.getIterAtChildAnchor(iter: iter, anchor: anchor)
            return Int(iter.offset)
        }
    }

    private func cursorOffset() -> Int {
        withIter { iter in
            buffer.getIterAtMark(iter: iter, mark: buffer.getInsert())
            return Int(iter.offset)
        }
    }

    private func deleteAnchorCharacter(_ anchor: TextChildAnchor) {
        guard let offset = offset(of: anchor) else { return }
        withIters { start, end in
            buffer.getIterAtOffset(iter: start, charOffset: offset)
            buffer.getIterAtOffset(iter: end, charOffset: offset + 1)
            buffer.delete(start: start, end: end)
        }
    }

    private func withIter<R>(_ body: (TextIter) -> R) -> R {
        let storage = UnsafeMutablePointer<GtkTextIter>.allocate(capacity: 1)
        defer { storage.deallocate() }
        return body(TextIter(storage))
    }

    private func withIters<R>(_ body: (TextIter, TextIter) -> R) -> R {
        let first = UnsafeMutablePointer<GtkTextIter>.allocate(capacity: 1)
        let second = UnsafeMutablePointer<GtkTextIter>.allocate(capacity: 1)
        defer { first.deallocate(); second.deallocate() }
        return body(TextIter(first), TextIter(second))
    }
}
