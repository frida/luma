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
// A plain press on an already-focused body editor still lets the snippet grab
// focus back; re-asserting it once the press has unwound keeps the editor in
// hand without claiming the press, which would have suppressed its selection.
private let pharoReassertBodyFocus: @convention(c) (gpointer?) -> gboolean = { data in
    guard let data else { return 0 }
    gtk_widget_grab_focus(UnsafeMutablePointer<GtkWidget>(OpaquePointer(data)))
    return 0
}

@MainActor
final class PharoInlineMarks {
    /// The object replacement character a child anchor occupies.
    private static let anchorScalar: Character = "\u{FFFC}"

    var isApplying: Bool { applying }

    /// A method a reader expanded is holding keyboard focus, so the snippet's
    /// own key shortcuts step aside and let the method's editor keep its keys.
    private(set) var isEditingBody = false

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

        buffer.onNotifyCursorPosition { [weak self] _, _ in
            MainActor.assumeIsolated { self?.hideCaretOnBodyLines() }
        }

        // The snippet editor claims a press that lands on one of its embedded
        // body editors before its own text handling can seize focus, then hands
        // the caret and focus to that editor. Nothing else reliably wins the
        // press: a gesture on the embedded editor competes with its own native
        // one and loses.
        let bodyPress = GestureClick()
        bodyPress.propagationPhase = .capture
        bodyPress.onPressed { [weak self] gesture, _, x, y in
            MainActor.assumeIsolated { self?.claimBodyPress(gesture, x: x, y: y) }
        }
        editor.install(controller: bodyPress)
    }

    private var bodyEditors: [GtkSource.View] = []

    /// Every editable text view a body drops into the snippet -- a method a mark
    /// expands, a method the class browser opens -- registers so the snippet
    /// hands it the press and mutes itself while it holds focus.
    func registerBodyEditor(_ view: GtkSource.View) {
        bodyEditors.append(view)
        let focus = EventControllerFocus()
        focus.onEnter { [weak self] _ in
            MainActor.assumeIsolated { self?.beginEditingBody() }
        }
        focus.onLeave { [weak self] _ in
            MainActor.assumeIsolated { self?.endEditingBody() }
        }
        view.install(controller: focus)
    }

    private func claimBodyPress(_ gesture: GestureClickRef, x: Double, y: Double) {
        guard let picked = gtk_widget_pick(editor.widget_ptr, x, y, PickFlags.default.value) else { return }
        guard let view = bodyEditors.first(where: { view in
            picked == view.widget_ptr || gtk_widget_is_ancestor(picked, view.widget_ptr) != 0
        }) else { return }

        // Once the editor holds focus its own press handling owns the caret and
        // selection, so the press is left alone -- only re-asserted afterwards
        // in case a plain click let the snippet steal focus back.
        if gtk_widget_has_focus(view.widget_ptr) != 0 {
            g_idle_add(pharoReassertBodyFocus, UnsafeMutableRawPointer(view.widget_ptr))
            return
        }

        _ = gesture.set(state: .claimed)

        var source = graphene_point_t()
        source.x = Float(x)
        source.y = Float(y)
        var local = graphene_point_t()
        if gtk_widget_compute_point(editor.widget_ptr, view.widget_ptr, &source, &local) != 0 {
            placeCaret(in: view, widgetX: Double(local.x), widgetY: Double(local.y))
        }
        _ = view.grabFocus()
    }

    private func placeCaret(in view: GtkSource.View, widgetX: Double, widgetY: Double) {
        let textView = UnsafeMutablePointer<GtkTextView>(OpaquePointer(view.widget_ptr))
        var bufferX: gint = 0
        var bufferY: gint = 0
        gtk_text_view_window_to_buffer_coords(textView, TextWindowType.widget.value, gint(widgetX), gint(widgetY), &bufferX, &bufferY)
        var iter = GtkTextIter()
        gtk_text_view_get_iter_at_location(textView, &iter, bufferX, bufferY)
        gtk_text_buffer_place_cursor(gtk_text_view_get_buffer(textView), &iter)
    }

    private func beginEditingBody() {
        isEditingBody = true
        setOuterEditable(false)
    }

    private func endEditingBody() {
        isEditingBody = false
        setOuterEditable(true)
    }

    private func setOuterEditable(_ editable: Bool) {
        let textView = UnsafeMutablePointer<GtkTextView>(OpaquePointer(editor.widget_ptr))
        gtk_text_view_set_editable(textView, editable ? 1 : 0)
    }

    /// A body sits on a line as tall as the widget it holds, so the editor's
    /// caret drawn there stands the same absurd height. Blank it while the caret
    /// rests on such a line; it returns the moment the caret steps back onto the
    /// code.
    private func hideCaretOnBodyLines() {
        let caretLine = withIter { iter -> Int in
            buffer.getIterAtMark(iter: iter, mark: buffer.getInsert())
            return iter.line
        }
        let onBodyLine = marks.values.contains { mark in
            guard let body = mark.body, let offset = offset(of: body.anchor) else { return false }
            let bodyLine = withIter { iter -> Int in
                buffer.getIterAtOffset(iter: iter, charOffset: Int(offset))
                return iter.line
            }
            return bodyLine == caretLine
        }
        editor.cursorVisible = !onBodyLine
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
    /// A mark and its open body are one carried block the code caret steps over
    /// whole rather than into, so arrowing across never strands the caret on a
    /// body's tall line or between the anchors that carry it.
    func handleCursorKey(_ keyval: UInt, shift: Bool) -> Bool {
        guard !shift else { return false }
        let cursor = cursorOffset()
        let carried = carriedOffsets()
        switch keyval {
        case 0xFF53 where carried.contains(cursor):  // Right
            var at = cursor
            while carried.contains(at) { at += 1 }
            moveCursor(to: at)
            return true
        case 0xFF51 where cursor > 0 && carried.contains(cursor - 1):  // Left
            var at = cursor - 1
            while at > 0, carried.contains(at - 1) { at -= 1 }
            moveCursor(to: at)
            return true
        case 0x0020 where carried.contains(cursor):  // space
            var at = cursor
            while carried.contains(at) { at += 1 }
            moveCursor(to: at)
            return false
        default:
            return false
        }
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
        gtk_widget_set_cursor_from_name(area.widget_ptr, "pointer")
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
        let centerY = height / 2 + 2
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
        guard let content = await bodyContent(for: mark) else { return }
        guard mark.body == nil, !mark.anchor.deleted else { return }
        insertBody(content, after: mark)
    }

    private func bodyContent(for mark: Mark) async -> Box? {
        switch mark.kind {
        case .classReference(let name):
            guard let object = try? await runtime.evaluate(name) else { return nil }
            let view = PharoColumnView(
                runtime: runtime, object: object, isMaximized: false, highlight: highlight,
                registerEditor: { [weak self] editor in self?.registerBodyEditor(editor) })
            view.widget.hexpand = true
            view.widget.vexpand = true
            view.offersLayoutActions = false
            view.onClose = { [weak self, weak mark] in
                MainActor.assumeIsolated {
                    guard let self, let mark else { return }
                    self.close(mark)
                }
            }
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
        let container = Box(orientation: .vertical, spacing: 0)
        container.marginBottom = 4

        let title = Label(str: "\(reference.className) \u{203A} \(reference.selector)")
        title.xalign = 0
        title.hexpand = true
        title.ellipsize = .end
        title.add(cssClass: "caption")
        title.add(cssClass: "dim-label")

        let failure = Label(str: "")
        failure.ellipsize = .end
        failure.add(cssClass: "caption")
        failure.add(cssClass: "error")
        failure.visible = false

        // The save stands only once the text drifts from what the image holds,
        // a checkmark at the heading's trailing edge the way the SwiftUI editor
        // shows it rather than a button that waits below. A drawn glyph rather
        // than a themed icon, which the macOS icon theme does not carry, and
        // held to the line height so its arrival does not push the editor down.
        let save = Button(label: "\u{2713}")
        save.add(cssClass: "flat")
        save.add(cssClass: "luma-pharo-inline-save")
        save.tooltipText = "Save"
        save.halign = .end
        save.valign = .center
        save.visible = false

        let heading = Box(orientation: .horizontal, spacing: 6)
        heading.baselinePosition = .center
        heading.marginStart = 4
        heading.marginEnd = 4
        heading.marginTop = 7
        heading.marginBottom = 7
        heading.append(child: title)
        heading.append(child: failure)
        heading.append(child: save)

        let methodBuffer = GtkSource.Buffer(table: Gtk.TextTagTable?.none)
        methodBuffer.set(text: reference.source, len: Int(reference.source.utf8.count))
        highlight(methodBuffer)
        let methodView = GtkSource.View(buffer: methodBuffer)
        methodView.monospace = true
        methodView.add(cssClass: "luma-pharo-method-editor")
        methodView.leftMargin = 8
        methodView.topMargin = 6
        methodView.bottomMargin = 6

        registerBodyEditor(methodView)

        // A one-line method would otherwise shrink to a sliver a click keeps
        // missing, so the editor holds a floor wide and tall enough to land on.
        let scroll = ScrolledWindow()
        scroll.setPolicy(hscrollbarPolicy: .automatic, vscrollbarPolicy: .automatic)
        scroll.propagateNaturalHeight = true
        scroll.minContentWidth = 360
        scroll.minContentHeight = 64
        scroll.maxContentHeight = 220
        scroll.set(child: methodView)

        // save and failure are locals whose GTK widgets outlive this scope under
        // their parent, but their Swift wrappers would not; the closures hold
        // them so a weak grab does not find them already gone.
        var savedSource = reference.source
        methodBuffer.onChanged { [save] _ in
            MainActor.assumeIsolated { save.visible = methodBuffer.text != savedSource }
        }
        save.onClicked { [weak self, save, failure] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let edited = methodBuffer.text
                Task { @MainActor in
                    do {
                        try await self.saveMethod(reference, source: edited)
                        savedSource = edited
                        save.visible = false
                        failure.visible = false
                    } catch {
                        failure.setText(str: error.localizedDescription)
                        failure.visible = true
                    }
                }
            }
        }

        container.append(child: heading)
        container.append(child: scroll)

        // The body sits inside the snippet's text view, so without this the
        // heading and its button wear the editor's I-beam; the source area keeps
        // its own, and the button gets a pointer.
        gtk_widget_set_cursor_from_name(container.widget_ptr, "default")
        gtk_widget_set_cursor_from_name(save.widget_ptr, "pointer")
        return container
    }

    private func saveMethod(_ reference: PharoMethodReference, source: String) async throws {
        let classObject = try await runtime.evaluate(reference.className)
        _ = try await runtime.compileMethod(
            in: classObject,
            side: reference.side,
            category: reference.category,
            source: source)
    }

    /// A body sits on a line of its own right after its mark: a newline closes the
    /// code line, the anchor holds the body, and a newline carries the rest of the
    /// send down below it. Any space that followed the mark stays on the code line
    /// rather than indenting what comes back below, the way the SwiftUI editor
    /// keeps it.
    private func insertBody(_ widget: Box, after mark: Mark) {
        applying = true
        defer { applying = false }

        guard let markOffset = offset(of: mark.anchor) else { return }
        let afterMark = Int(markOffset) + 1
        let at = afterMark + leadingSpaces(from: afterMark)

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
        // The class coder brings its own frame, so it only wants a margin; a
        // method editor draws the body's own border around itself.
        switch mark.kind {
        case .classReference: widget.add(cssClass: "luma-pharo-class-body")
        case .methodReference: widget.add(cssClass: "luma-pharo-body")
        }
        sizeBody(widget, kind: mark.kind)
        editor.addChildAtAnchor(child: widget, anchor: anchor)
        mark.body = Body(widget: widget, anchor: anchor)
        mark.area.queueDraw()
    }

    private func leadingSpaces(from offset: Int) -> Int {
        withIters { cursor, end in
            buffer.getIterAtOffset(iter: cursor, charOffset: offset)
            buffer.getIterAtOffset(iter: end, charOffset: Int(buffer.getCharCount()))
            let rest = buffer.getSlice(start: cursor, end: end, includeHiddenChars: true) ?? ""
            return rest.prefix { $0 == " " || $0 == "\t" }.count
        }
    }

    /// An anchored widget keeps to its own size rather than the text's, so a body
    /// is given the editor's width. A class coder is stood tall the way it fills
    /// the page on the SwiftUI side; a method body keeps to its own height so a
    /// short method is not padded, growing with its lines until its scroller caps
    /// it. Reapplied as bodies open so a widened window carries.
    private func sizeBody(_ widget: Box, kind: Kind) {
        let width = max(editor.getWidth() - 20, 260)
        switch kind {
        case .classReference:
            widget.setSizeRequest(width: width, height: 380)
        case .methodReference:
            widget.setSizeRequest(width: width, height: -1)
        }
    }

    private func resizeBodies() {
        for mark in marks.values {
            if let body = mark.body { sizeBody(body.widget, kind: mark.kind) }
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

        bodyEditors.removeAll { gtk_widget_get_root($0.widget_ptr) == nil }
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
