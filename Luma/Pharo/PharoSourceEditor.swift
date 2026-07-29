import AppKit
import SwiftUI
import Combine
import SwiftyPharo

/// What the snippet shows alongside its text.
struct PharoSnippetMarks: Equatable {
    var openedClasses: [String: PharoObject] = [:]
    var hasResult: Bool = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.hasResult == rhs.hasResult
            && lhs.openedClasses.mapValues(\.handle) == rhs.openedClasses.mapValues(\.handle)
    }
}

/// The bodies a snippet's marks have opened, in source order, rendered below the
/// text rather than inside it: an attachment cannot both size to its content and
/// let long lines scroll instead of wrap, so the bodies leave the text flow.
final class PharoOpenBodies: ObservableObject {
    @Published var items: [PharoBodyItem] = []
}

enum PharoBodyItem: Identifiable {
    case classBody(PharoClassMarkModel)
    case methodBody(PharoMethodMarkModel)
    case newClass(PharoUndeclaredMarkModel)

    var id: String {
        switch self {
        case .classBody(let model): "class:\(model.name)"
        case .methodBody(let model): "method:\(model.reference.id)"
        case .newClass(let model): "newclass:\(model.variable.id)"
        }
    }
}

/// A multi-line Smalltalk editor: the source scrolls rather than wraps, its
/// marks sit inline as triangles, and the bodies they open stack below it.
struct PharoSourceEditor: View {
    let id: UUID
    @Binding var source: String
    @Binding var focused: UUID?
    let runtime: PharoRuntime
    let marks: PharoSnippetMarks
    let onToggleClass: (String) -> Void
    let onOpen: (PharoObject) -> Void
    let onOpenResult: () -> Void
    var selfClass: String? = nil
    var resolvesReferences: Bool = true
    var isMethod: Bool = false

    @StateObject private var bodies = PharoOpenBodies()

    init(
        id: UUID,
        source: Binding<String>,
        focused: Binding<UUID?>,
        runtime: PharoRuntime,
        marks: PharoSnippetMarks,
        onToggleClass: @escaping (String) -> Void,
        onOpen: @escaping (PharoObject) -> Void,
        onOpenResult: @escaping () -> Void,
        selfClass: String? = nil,
        resolvesReferences: Bool = true,
        isMethod: Bool = false
    ) {
        self.id = id
        _source = source
        _focused = focused
        self.runtime = runtime
        self.marks = marks
        self.onToggleClass = onToggleClass
        self.onOpen = onOpen
        self.onOpenResult = onOpenResult
        self.selfClass = selfClass
        self.resolvesReferences = resolvesReferences
        self.isMethod = isMethod
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PharoTextEditor(
                id: id,
                source: $source,
                focused: $focused,
                runtime: runtime,
                marks: marks,
                onToggleClass: onToggleClass,
                onOpen: onOpen,
                onOpenResult: onOpenResult,
                selfClass: selfClass,
                resolvesReferences: resolvesReferences,
                isMethod: isMethod,
                bodies: bodies)
            PharoOpenBodiesView(bodies: bodies)
        }
    }
}

private struct PharoOpenBodiesView: View {
    @ObservedObject var bodies: PharoOpenBodies

    var body: some View {
        if !bodies.items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(bodies.items) { item in
                    body(of: item)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func body(of item: PharoBodyItem) -> some View {
        switch item {
        case .classBody(let model):
            PharoClassBody(model: model)
        case .methodBody(let model):
            PharoMethodBody(model: model)
        case .newClass(let model):
            PharoNewClassBody(model: model)
        }
    }
}

/// The text itself: an NSTextView whose container never wraps, in a scroll view
/// so long lines run off the side, with the inline mark triangles as attachments.
struct PharoTextEditor: NSViewRepresentable {
    let id: UUID
    @Binding var source: String
    @Binding var focused: UUID?
    let runtime: PharoRuntime
    let marks: PharoSnippetMarks
    let onToggleClass: (String) -> Void
    let onOpen: (PharoObject) -> Void
    let onOpenResult: () -> Void
    var selfClass: String?
    var resolvesReferences: Bool
    var isMethod: Bool
    let bodies: PharoOpenBodies

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let view = PharoTextView()
        view.delegate = context.coordinator
        view.bodies = bodies
        view.onFocused = { if focused != id { focused = id } }
        view.completions = runtime.completionList
        view.styleSpans = { source in await runtime.styles(in: source, isMethod: isMethod) }
        if resolvesReferences {
            view.classReferences = runtime.namedClasses(in:)
            view.methodReferences = { source in await runtime.methods(in: source, selfClass: selfClass) }
            view.undeclaredVariables = runtime.undeclared(in:)
        }
        view.onEdit = { source = $0 }
        view.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        view.isRichText = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 4, height: 6)
        view.isHorizontallyResizable = true
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.apply(runtime: runtime, marks: marks, onToggleClass: onToggleClass, onOpen: onOpen, onOpenResult: onOpenResult)
        view.setSource(source)

        let scroll = NSScrollView()
        scroll.documentView = view
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.verticalScrollElasticity = .none
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let view = scroll.documentView as! PharoTextView
        context.coordinator.parent = self
        view.onFocused = { if focused != id { focused = id } }
        view.onEdit = { source = $0 }
        view.apply(runtime: runtime, marks: marks, onToggleClass: onToggleClass, onOpen: onOpen, onOpenResult: onOpenResult)
        if view.source != source {
            view.setSource(source)
        }
        context.coordinator.reconcileFocus(id: id, focused: focused, view: view)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, let view = scroll.documentView as? PharoTextView else { return nil }
        return CGSize(width: width, height: view.height())
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PharoTextEditor
        private var appliedFocused: UUID?

        init(_ parent: PharoTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? PharoTextView else { return }
            parent.source = view.source
        }

        /// Takes first responder only as focus arrives, not on every update: a
        /// body opened below the editor is a separate responder, and reclaiming
        /// focus each pass would snatch it back from there mid-edit.
        func reconcileFocus(id: UUID, focused: UUID?, view: PharoTextView) {
            guard focused == id else { appliedFocused = nil; return }
            guard appliedFocused != id else { return }
            appliedFocused = id
            guard view.window?.firstResponder !== view else { return }
            DispatchQueue.main.async {
                guard view.window?.firstResponder !== view else { return }
                view.window?.makeFirstResponder(view)
            }
        }
    }
}

/// The candidates for a cursor, and how far back they reach.
struct PharoCompletionList: Sendable {
    let tokenStart: Int
    let candidates: [String]

    static let none = PharoCompletionList(tokenStart: 0, candidates: [])
}

extension PharoRuntime {
    /// A page that cannot reach the image simply does not complete. Waiting for
    /// the image to answer is done here rather than in the request itself,
    /// which would park a thread on one still starting up.
    func completionList(for source: String, at position: Int) async -> PharoCompletionList {
        guard let answer = try? await whenRunning({ try await completions(for: source, at: position) })
        else { return .none }
        return PharoCompletionList(tokenStart: answer.tokenStart, candidates: answer.completions)
    }

    /// Nor does a page that cannot reach the image name any classes.
    func namedClasses(in source: String) async -> [PharoClassReference] {
        (try? await whenRunning { try await classReferences(in: source) }) ?? []
    }

    /// Nor the methods it sends.
    func methods(in source: String, selfClass: String?) async -> [PharoMethodReference] {
        (try? await whenRunning { try await methodReferences(in: source, selfClass: selfClass) }) ?? []
    }

    /// Nor the names it leaves undeclared.
    func undeclared(in source: String) async -> [PharoUndeclaredVariable] {
        (try? await whenRunning { try await undeclaredVariables(in: source) }) ?? []
    }

    /// Nor colours any of it.
    func styles(in source: String, isMethod: Bool) async -> [PharoStyleSpan] {
        (try? await whenRunning { try await styleSpans(in: source, isMethod: isMethod) }) ?? []
    }

    private func whenRunning<Answer>(_ request: () async throws -> Answer) async throws -> Answer {
        try await runningState()
        return try await request()
    }
}

/// Marks live in the text as attachments, so the source the reader edits is the
/// text with those attachment characters taken back out. The bodies they open
/// are published to the editor below rather than kept in the text.
final class PharoTextView: NSTextView {
    var completions: ((String, Int) async -> PharoCompletionList)?
    var classReferences: ((String) async -> [PharoClassReference])?
    var methodReferences: ((String) async -> [PharoMethodReference])?
    var undeclaredVariables: ((String) async -> [PharoUndeclaredVariable])?
    var styleSpans: ((String) async -> [PharoStyleSpan])?
    var onFocused: (() -> Void)?
    var onEdit: ((String) -> Void)?
    var bodies: PharoOpenBodies?

    private var runtime: PharoRuntime?
    private var marks = PharoSnippetMarks()
    private var onToggleClass: ((String) -> Void)?
    private var onOpen: ((PharoObject) -> Void)?

    private var fetched: PharoCompletionList?
    private var references: [PharoClassReference] = []
    private var methodRefs: [PharoMethodReference] = []
    private var undeclared: [PharoUndeclaredVariable] = []
    private var spans: [PharoStyleSpan] = []
    private var referencedSource: String?
    private var isApplyingMarks = false
    private var attachments: [PharoMarkContent: PharoMarkAttachment] = [:]
    private var classModels: [String: PharoClassMarkModel] = [:]
    private var methodModels: [String: PharoMethodMarkModel] = [:]
    private var undeclaredModels: [String: PharoUndeclaredMarkModel] = [:]
    private let resultModel = PharoResultMarkModel()

    var source: String {
        string.replacingOccurrences(of: "\u{FFFC}", with: "")
    }

    func setSource(_ newSource: String) {
        replaceText(with: NSAttributedString(string: newSource, attributes: sourceAttributes))
        markUp()
    }

    func apply(
        runtime: PharoRuntime,
        marks: PharoSnippetMarks,
        onToggleClass: @escaping (String) -> Void,
        onOpen: @escaping (PharoObject) -> Void,
        onOpenResult: @escaping () -> Void
    ) {
        self.runtime = runtime
        self.onToggleClass = onToggleClass
        self.onOpen = onOpen
        resultModel.open = onOpenResult
        guard self.marks != marks else { return }
        self.marks = marks
        expandOpenedClasses()
        showResult()
        markUp()
    }

    /// The host owns which classes are open, so a change there opens or closes a
    /// class body below the editor.
    private func expandOpenedClasses() {
        for (name, model) in classModels {
            let opened = marks.openedClasses[name]
            guard model.opened?.handle != opened?.handle else { continue }
            // apply() runs while SwiftUI is updating, and a body's state is
            // published, so it changes once that pass has finished.
            DispatchQueue.main.async {
                model.opened = opened
                self.refreshOpenBodies()
            }
        }
    }

    /// The dot is already in the text, empty, so a result only has to fill it
    /// in: inserting it now would leave a mark NSTextView never builds a view
    /// for, and it would show as a placeholder until something forced a pass.
    private func showResult() {
        guard resultModel.hasResult != marks.hasResult else { return }

        let hasResult = marks.hasResult
        DispatchQueue.main.async {
            self.resultModel.hasResult = hasResult
            guard let attachment = self.attachments[.result] else { return }
            let wanted = self.bounds(for: .result)
            guard attachment.bounds != wanted else { return }
            attachment.resize(to: wanted)
            self.textLayoutManager.map { $0.invalidateLayout(for: $0.documentRange) }
        }
    }

    override func didChangeText() {
        super.didChangeText()
        guard !isApplyingMarks else { return }
        markUp()
    }

    /// Ask the image which classes the snippet names, then lay the marks back
    /// into the text. Typing invalidates the answer, so it is fetched afresh
    /// whenever the source has moved on.
    private func markUp() {
        let source = self.source
        guard referencedSource != source else {
            reconcileMarks()
            refreshOpenBodies()
            return
        }

        referencedSource = source
        Task { @MainActor in
            let classes = await classReferences?(source) ?? []
            let methods = await methodReferences?(source) ?? []
            let undeclaredNames = await undeclaredVariables?(source) ?? []
            let spans = await styleSpans?(source) ?? []
            guard self.source == source else { return }
            references = classes
            methodRefs = methods
            undeclared = undeclaredNames
            self.spans = spans
            reconcileMarks()
            refreshOpenBodies()
            applyStyle()
        }
    }

    /// Paint the coloured runs GT would over the source, mapped past the mark
    /// characters, on a plain label-coloured ground. Each run's colour resolves
    /// the light or dark shade itself, so a theme flip redraws without another
    /// attribute pass -- which would relayout and unsettle the marks.
    private func applyStyle() {
        guard let storage = textStorage else { return }
        let plain = font ?? .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let bold = NSFont.monospacedSystemFont(ofSize: plain.pointSize, weight: .bold)
        let whole = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: whole)
        storage.addAttribute(.font, value: plain, range: whole)
        for span in spans {
            let start = storageOffset(forSource: span.start - 1)
            let end = storageOffset(forSource: span.stop)
            guard end > start, end <= storage.length else { continue }
            let range = NSRange(location: start, length: end - start)
            if let color = NSColor(lightHex: span.light, darkHex: span.dark) {
                storage.addAttribute(.foregroundColor, value: color, range: range)
            }
            if span.bold {
                storage.addAttribute(.font, value: bold, range: range)
            }
        }
        storage.endEditing()
    }

    /// Bring the marks in the text into line with the ones the snippet wants,
    /// touching only what differs. A mark that has not moved is left alone, so
    /// typing beside one disturbs neither it nor the cursor.
    private func reconcileMarks() {
        guard let storage = textStorage else { return }

        let wanted = wantedMarks()
        let present = presentMarks()
        let stale = present.filter { !wanted.contains($0.mark) }
        let missing = wanted.filter { mark in !present.contains { $0.mark == mark } }
        guard !stale.isEmpty || !missing.isEmpty else { return }

        isApplyingMarks = true
        let cursor = sourceCursor
        storage.beginEditing()
        for placed in stale.sorted(by: { $0.storageOffset > $1.storageOffset }) {
            storage.deleteCharacters(in: NSRange(location: placed.storageOffset, length: 1))
        }
        let ordered = missing.sorted {
            ($0.sourceOffset, $0.content.insertionOrder) > ($1.sourceOffset, $1.content.insertionOrder)
        }
        for mark in ordered {
            storage.insert(
                NSAttributedString(attachment: attachment(for: mark.content)),
                at: storageOffset(forSource: mark.sourceOffset))
        }
        storage.endEditing()
        setSelectedRange(NSRange(location: storageOffset(forSource: cursor), length: 0))
        isApplyingMarks = false
    }

    private func wantedMarks() -> [PharoPlacedMark] {
        var wanted: [PharoPlacedMark] = []

        for reference in references {
            wanted.append(PharoPlacedMark(sourceOffset: reference.stop, content: .classTriangle(reference.name)))
        }
        for reference in methodRefs {
            wanted.append(PharoPlacedMark(sourceOffset: reference.stop, content: .methodTriangle(reference.id)))
        }
        for variable in undeclared {
            wanted.append(PharoPlacedMark(sourceOffset: variable.stop, content: .undeclaredWrench(variable.id)))
        }
        wanted.append(PharoPlacedMark(sourceOffset: source.utf16.count, content: .result))

        return wanted
    }

    private func presentMarks() -> [(mark: PharoPlacedMark, storageOffset: Int)] {
        var present: [(mark: PharoPlacedMark, storageOffset: Int)] = []
        textStorage?.enumerateAttribute(.attachment, in: NSRange(location: 0, length: string.utf16.count)) {
            value, range, _ in
            guard let attachment = value as? PharoMarkAttachment else { return }
            present.append((
                PharoPlacedMark(
                    sourceOffset: sourceOffset(ofStorage: range.location),
                    content: attachment.content),
                range.location))
        }
        return present
    }

    /// Marks keep their attachment across a move, so a triangle does not lose the
    /// model whose body the reader has open.
    private func attachment(for content: PharoMarkContent) -> PharoMarkAttachment {
        if let known = attachments[content] {
            return known
        }

        let made = PharoMarkAttachment(content: content, markView: markView(for: content))
        made.resize(to: bounds(for: content))
        attachments[content] = made
        return made
    }

    /// A triangle, wrench or dot is as tall as a capital letter, which keeps it
    /// inside the ascent so showing one never makes the line taller.
    private func bounds(for content: PharoMarkContent) -> CGRect {
        switch content {
        case .result where !resultModel.hasResult:
            return CGRect(x: 0, y: 0, width: 0.01, height: 0.01)
        case .classTriangle, .methodTriangle, .undeclaredWrench, .result:
            let side = (font ?? .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular))
                .capHeight.rounded()
            return CGRect(x: 0, y: 0, width: side + 3, height: side)
        }
    }

    private func markView(for content: PharoMarkContent) -> NSView {
        switch content {
        case .classTriangle(let name):
            PharoMarkHostingView(content: PharoClassTriangle(model: classModel(name)))
        case .methodTriangle(let key):
            PharoMarkHostingView(content: PharoMethodTriangle(model: methodModel(key)))
        case .undeclaredWrench(let key):
            PharoMarkHostingView(content: PharoUndeclaredWrench(model: undeclaredModel(key)))
        case .result:
            PharoMarkHostingView(content: PharoResultDot(model: resultModel))
        }
    }

    /// The bodies the marks have open, in the order their marks fall in the
    /// source, handed to the editor below to draw.
    private func refreshOpenBodies() {
        var ordered: [(offset: Int, item: PharoBodyItem)] = []
        for reference in references {
            if let model = classModels[reference.name], model.opened != nil {
                ordered.append((reference.stop, .classBody(model)))
            }
        }
        for reference in methodRefs {
            if let model = methodModels[reference.id], model.opened {
                ordered.append((reference.stop, .methodBody(model)))
            }
        }
        for variable in undeclared {
            if let model = undeclaredModels[variable.id], model.isDefining {
                ordered.append((variable.stop, .newClass(model)))
            }
        }

        let items = ordered.sorted { $0.offset < $1.offset }.map(\.item)
        guard items.map(\.id) != (bodies?.items.map(\.id) ?? []) else { return }
        // markUp() reaches here from apply() during a SwiftUI update, so the
        // published change waits for the pass to finish.
        DispatchQueue.main.async { [weak self] in
            self?.bodies?.items = items
        }
    }

    private func classModel(_ name: String) -> PharoClassMarkModel {
        if let existing = classModels[name] {
            return existing
        }

        let model = PharoClassMarkModel(
            runtime: runtime!,
            name: name,
            opened: marks.openedClasses[name],
            onToggle: { [weak self] in self?.onToggleClass?(name) },
            onOpen: { [weak self] in self?.onOpen?($0) })
        classModels[name] = model
        return model
    }

    private func methodModel(_ key: String) -> PharoMethodMarkModel {
        if let existing = methodModels[key] {
            return existing
        }

        let reference = methodRefs.first { $0.id == key }!
        let model = PharoMethodMarkModel(
            runtime: runtime!,
            reference: reference,
            onToggle: { [weak self] in self?.toggleMethod(key) },
            onOpen: { [weak self] in self?.onOpen?($0) })
        methodModels[key] = model
        return model
    }

    private func toggleMethod(_ key: String) {
        guard let model = methodModels[key] else { return }
        model.opened.toggle()
        refreshOpenBodies()
    }

    private func undeclaredModel(_ key: String) -> PharoUndeclaredMarkModel {
        if let existing = undeclaredModels[key] {
            return existing
        }

        let variable = undeclared.first { $0.id == key }!
        let model = PharoUndeclaredMarkModel(variable: variable)
        model.onReplace = { [weak self] name in self?.replace(variable, with: name) }
        model.onConfirm = { [weak self, weak model] in model.map { self?.defineClass($0) } }
        model.onChanged = { [weak self] in self?.refreshOpenBodies() }
        undeclaredModels[key] = model
        return model
    }

    private func defineClass(_ model: PharoUndeclaredMarkModel) {
        guard let runtime else { return }
        Task { @MainActor in
            _ = try? await runtime.defineClass(
                name: model.name,
                superclass: model.superclassName,
                package: model.package,
                tag: model.tag,
                instanceVariables: model.instanceVariables,
                classVariables: model.classVariables,
                classInstanceVariables: model.classInstanceVariables)
            model.isDefining = false
            referencedSource = nil
            markUp()
        }
    }

    private func replace(_ variable: PharoUndeclaredVariable, with name: String) {
        var characters = Array(source)
        characters.replaceSubrange((variable.start - 1)..<variable.stop, with: name)
        onEdit?(String(characters))
    }

    /// A source the reader did not type, so the text is replaced outright.
    private func replaceText(with attributed: NSAttributedString) {
        guard !isApplyingMarks, let storage = textStorage else { return }
        guard !storage.isEqual(to: attributed) else { return }

        isApplyingMarks = true
        storage.setAttributedString(attributed)
        isApplyingMarks = false
    }

    private var sourceCursor: Int {
        string.utf16.prefix(selectedRange().location).count { $0 != markCharacter }
    }

    private func storageOffset(forSource cursor: Int) -> Int {
        let units = Array(string.utf16)
        var counted = 0
        var offset = 0
        while offset < units.count, counted < cursor {
            if units[offset] != markCharacter {
                counted += 1
            }
            offset += 1
        }
        return offset
    }

    private func sourceOffset(ofStorage offset: Int) -> Int {
        string.utf16.prefix(offset).count { $0 != markCharacter }
    }

    private let markCharacter: UTF16.CodeUnit = 0xFFFC

    private var sourceAttributes: [NSAttributedString.Key: Any] {
        [
            .font: font ?? .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ]
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocused?() }
        return became
    }

    /// The marks are invisible to the caret: crossing a class name's mark, and
    /// the space it pushes ahead of the next word, takes one press, not one per
    /// hidden character.
    override func moveRight(_ sender: Any?) {
        super.moveRight(sender)
        skipMarksFromCaret(forward: true)
    }

    override func moveLeft(_ sender: Any?) {
        super.moveLeft(sender)
        skipMarksFromCaret(forward: false)
    }

    private func skipMarksFromCaret(forward: Bool) {
        let selection = selectedRange()
        guard selection.length == 0 else { return }

        let units = Array(string.utf16)
        var caret = selection.location
        while caret > 0, caret <= units.count, units[caret - 1] == markCharacter {
            caret += forward ? 1 : -1
            guard caret >= 0, caret <= units.count else { break }
        }
        setSelectedRange(NSRange(location: max(0, min(caret, units.count)), length: 0))
    }

    /// The text view reasserts the I-beam as the pointer travels, so anything
    /// else asking for the hand only wins between moves and the two flicker.
    /// It has to be the one to decide, for the marks as well as for the text.
    override func cursorUpdate(with event: NSEvent) {
        guard isOverMark(event) else { return super.cursorUpdate(with: event) }
        NSCursor.pointingHand.set()
    }

    override func mouseMoved(with event: NSEvent) {
        guard isOverMark(event) else { return super.mouseMoved(with: event) }
        NSCursor.pointingHand.set()
    }

    private func isOverMark(_ event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        return marksIn(self).contains { $0.convert($0.bounds, to: self).contains(point) }
    }

    private func marksIn(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { subview -> [NSView] in
            subview is PharoMarkHostingView ? [subview] : marksIn(subview)
        }
    }

    override func complete(_ sender: Any?) {
        if let fetched {
            self.fetched = nil
            guard !fetched.candidates.isEmpty else { return }
            return super.complete(sender)
        }

        let source = self.source
        let cursor = sourceCursor
        Task { @MainActor in
            guard let list = await completions?(source, cursor), self.source == source else { return }
            fetched = list
            super.complete(sender)
        }
    }

    override func completions(
        forPartialWordRange charRange: NSRange,
        indexOfSelectedItem index: UnsafeMutablePointer<Int>?
    ) -> [String]? {
        fetched?.candidates
    }

    /// The image counts the token from one, and in the source it was given,
    /// which the marks in the text have since shifted along.
    override var rangeForUserCompletion: NSRange {
        guard let fetched else { return super.rangeForUserCompletion }
        let cursor = selectedRange().location
        let start = min(storageOffset(forSource: fetched.tokenStart - 1), cursor)
        return NSRange(location: start, length: cursor - start)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        guard let typed = string as? String else { return }
        if typed.count == 1, let unit = typed.utf16.first, unit == 41 || unit == 93 || unit == 125 {
            dedentCloserLine()
        } else if typed.allSatisfy(\.isLetter) {
            complete(nil)
        }
    }

    /// A closer typed as the first thing on its line drops back to line up under
    /// the line that opened it.
    private func dedentCloserLine() {
        guard let storage = textStorage else { return }
        let text = string as NSString
        let closer = selectedRange().location - 1
        guard closer >= 0 else { return }

        let line = text.lineRange(for: NSRange(location: closer, length: 0))
        let leading = NSRange(location: line.location, length: closer - line.location)
        let indent = text.substring(with: leading)
        guard indent.allSatisfy({ $0 == " " || $0 == "\t" }) else { return }
        guard let opener = matchingOpenerOffset(before: closer) else { return }

        let openerLine = text.lineRange(for: NSRange(location: opener, length: 0))
        let openerIndent = String(text.substring(with: openerLine).prefix { $0 == " " || $0 == "\t" })
        guard openerIndent != indent else { return }

        storage.replaceCharacters(in: leading, with: NSAttributedString(string: openerIndent, attributes: sourceAttributes))
        setSelectedRange(NSRange(location: line.location + (openerIndent as NSString).length + 1, length: 0))
    }

    /// The offset of the bracket that a closer at `closerOffset` matches, found
    /// by lexing forward with the same blindness to strings, comments and
    /// character literals as the indenter.
    private func matchingOpenerOffset(before closerOffset: Int) -> Int? {
        let units = Array(string.utf16)
        let end = min(closerOffset, units.count)
        var openers: [Int] = []
        var index = 0
        while index < end {
            switch units[index] {
            case 39:
                index = endOfQuotedUnit(units, after: index, terminator: 39)
            case 34:
                index = endOfQuotedUnit(units, after: index, terminator: 34)
            case 36:
                index += 1
            case 40, 91, 123:
                openers.append(index)
            case 41, 93, 125 where !openers.isEmpty:
                openers.removeLast()
            default:
                break
            }
            index += 1
        }
        return openers.last
    }

    private func endOfQuotedUnit(_ units: [UTF16.CodeUnit], after open: Int, terminator: UTF16.CodeUnit) -> Int {
        var index = open + 1
        while index < units.count {
            if units[index] == terminator {
                guard index + 1 < units.count, units[index + 1] == terminator else { return index }
                index += 2
                continue
            }
            index += 1
        }
        return units.count
    }

    /// A new line follows the nesting: it keeps the indentation of the one it
    /// left and steps in once for every bracket that line opened and had not
    /// closed by the caret. Opening a bracket and pressing Enter with its closer
    /// still ahead drops the closer to its own line at the outer indent.
    override func insertNewline(_ sender: Any?) {
        let text = string as NSString
        let caret = selectedRange().location
        let line = text.lineRange(for: NSRange(location: caret, length: 0))
        let toCaret = text.substring(with: NSRange(location: line.location, length: caret - line.location))
        let base = String(toCaret.prefix { $0 == " " || $0 == "\t" })
        let depth = openDepth(in: toCaret)
        let inner = depth > 0 ? base + String(repeating: "\t", count: depth) : base
        let splitsCloser = depth > 0 && nextNonSpaceIsCloser(text, from: caret)

        super.insertNewline(sender)
        if !inner.isEmpty {
            super.insertText(inner, replacementRange: selectedRange())
        }
        guard splitsCloser else { return }
        let caretAfterInner = selectedRange()
        super.insertText("\n" + base, replacementRange: caretAfterInner)
        setSelectedRange(caretAfterInner)
    }

    /// The brackets a stretch of source leaves open, blind to those inside a
    /// string, a comment or a character literal, where they are not grammar.
    private func openDepth(in source: String) -> Int {
        let characters = Array(source)
        var depth = 0
        var index = 0
        while index < characters.count {
            switch characters[index] {
            case "'":
                index = endOfQuoted(characters, after: index, terminator: "'")
            case "\"":
                index = endOfQuoted(characters, after: index, terminator: "\"")
            case "$":
                index += 1
            case "(", "[", "{":
                depth += 1
            case ")", "]", "}" where depth > 0:
                depth -= 1
            default:
                break
            }
            index += 1
        }
        return depth
    }

    /// The index of a quote's or comment's closing mark, treating a doubled mark
    /// as an escaped one that stays inside.
    private func endOfQuoted(_ characters: [Character], after open: Int, terminator: Character) -> Int {
        var index = open + 1
        while index < characters.count {
            if characters[index] == terminator {
                guard index + 1 < characters.count, characters[index + 1] == terminator else { return index }
                index += 2
                continue
            }
            index += 1
        }
        return characters.count
    }

    private func nextNonSpaceIsCloser(_ text: NSString, from caret: Int) -> Bool {
        var index = caret
        while index < text.length {
            let unit = text.character(at: index)
            if unit == 32 || unit == 9 { index += 1; continue }
            return unit == 41 || unit == 93 || unit == 125
        }
        return false
    }

    /// Tab indents: it steps in every line a selection touches, and is a plain
    /// tab when nothing is selected. Shift-tab always steps a line back out.
    override func insertTab(_ sender: Any?) {
        guard selectedRange().length > 0 else { return super.insertText("\t", replacementRange: selectedRange()) }
        shiftSelectedLines(indenting: true)
    }

    override func insertBacktab(_ sender: Any?) {
        shiftSelectedLines(indenting: false)
    }

    /// Backspace in space indentation clears a whole level back to the previous
    /// tab stop, not one space; a real tab already deletes as one.
    override func deleteBackward(_ sender: Any?) {
        let caret = selectedRange()
        guard caret.length == 0, caret.location > 0 else { return super.deleteBackward(sender) }

        let text = string as NSString
        let line = text.lineRange(for: NSRange(location: caret.location, length: 0))
        let lead = text.substring(with: NSRange(location: line.location, length: caret.location - line.location))
        guard !lead.isEmpty, lead.allSatisfy({ $0 == " " }) else { return super.deleteBackward(sender) }

        let width = 4
        let column = caret.location - line.location
        let count = column - (column - 1) / width * width
        let range = NSRange(location: caret.location - count, length: count)
        guard shouldChangeText(in: range, replacementString: "") else { return }
        textStorage?.deleteCharacters(in: range)
        didChangeText()
    }

    /// Steps every line the selection touches, adding or dropping one level at
    /// its start. Editing the starts rather than rewriting the lines leaves any
    /// marks they carry in place.
    private func shiftSelectedLines(indenting: Bool) {
        guard let storage = textStorage else { return }
        let text = string as NSString
        let block = text.lineRange(for: selectedRange())
        var starts: [Int] = []
        var location = block.location
        while location < NSMaxRange(block) {
            starts.append(location)
            location = NSMaxRange(text.lineRange(for: NSRange(location: location, length: 0)))
        }

        storage.beginEditing()
        var delta = 0
        for start in starts.reversed() {
            if indenting {
                storage.insert(NSAttributedString(string: "\t", attributes: sourceAttributes), at: start)
                delta += 1
            } else {
                let width = leadingIndentWidth(in: text, at: start)
                guard width > 0 else { continue }
                storage.deleteCharacters(in: NSRange(location: start, length: width))
                delta -= width
            }
        }
        storage.endEditing()
        didChangeText()
        setSelectedRange(NSRange(location: block.location, length: max(0, block.length + delta)))
    }

    private func leadingIndentWidth(in text: NSString, at start: Int) -> Int {
        guard start < text.length else { return 0 }
        if text.character(at: start) == 9 { return 1 }
        var spaces = 0
        while spaces < 4, start + spaces < text.length, text.character(at: start + spaces) == 32 {
            spaces += 1
        }
        return spaces
    }

    /// The height the text needs, which is the whole of it: the container never
    /// wraps, so width does not enter into it.
    func height() -> CGFloat {
        guard let layout = textLayoutManager else { return 0 }
        layout.ensureLayout(for: layout.documentRange)
        return layout.usageBoundsForTextContainer.height + 2 * textContainerInset.height
    }
}

/// What a snippet marks inline. The body each one opens lives below the editor,
/// not in the text, so only these fixed-size triggers are attachments.
enum PharoMarkContent {
    case classTriangle(String)
    case methodTriangle(String)
    case undeclaredWrench(String)
    case result

    /// The result dot sits at the very end, after any mark sharing its spot.
    var insertionOrder: Int {
        switch self {
        case .result: 2
        default: 0
        }
    }
}

/// Holds a mark's view, and marks it as one for the text view's sake.
final class PharoMarkHostingView: NSView {
    init(content: some View) {
        super.init(frame: .zero)
        let hosting = NSHostingView(rootView: content)
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
        hosting.frame = bounds
    }

    override func layout() {
        super.layout()
        subviews.first?.frame = bounds
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PharoMarkHostingView is not loaded from a nib")
    }
}

nonisolated final class PharoMarkAttachment: NSTextAttachment, @unchecked Sendable {
    let content: PharoMarkContent
    let markView: NSView

    /// The view is given the size too, not just the attachment: left at zero it
    /// draws nothing until something else forces it to lay out.
    func resize(to size: CGRect) {
        bounds = size
        let view = markView
        MainActor.assumeIsolated { view.frame = size }
    }

    init(content: PharoMarkContent, markView: NSView) {
        self.content = content
        self.markView = markView
        super.init(data: nil, ofType: nil)
        allowsTextAttachmentView = true
    }

    override func viewProvider(
        for parentView: NSView?,
        location: any NSTextLocation,
        textContainer: NSTextContainer?
    ) -> NSTextAttachmentViewProvider? {
        PharoMarkViewProvider(
            textAttachment: self,
            parentView: parentView,
            textLayoutManager: textContainer?.textLayoutManager,
            location: location)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PharoMarkAttachment is not loaded from a nib")
    }
}

nonisolated final class PharoMarkViewProvider: NSTextAttachmentViewProvider, @unchecked Sendable {
    override func loadView() {
        view = (textAttachment as? PharoMarkAttachment)?.markView
    }

    /// Left to itself the provider measures the hosting view, which pads a mark
    /// out and, when its size is zero, makes the line as tall as an empty view
    /// rather than nothing. The attachment's own bounds are the truth.
    override func attachmentBounds(
        for attributes: [NSAttributedString.Key: Any],
        location: any NSTextLocation,
        textContainer: NSTextContainer?,
        proposedLineFragment: CGRect,
        position: CGPoint
    ) -> CGRect {
        (textAttachment as? PharoMarkAttachment)?.bounds ?? .zero
    }
}

/// What the snippet last produced, which the dot in the text watches.
final class PharoResultMarkModel: ObservableObject {
    @Published var hasResult = false
    var open: () -> Void = {}
}

final class PharoClassMarkModel: ObservableObject {
    let runtime: PharoRuntime
    let name: String
    let onToggle: () -> Void
    let onOpen: (PharoObject) -> Void
    @Published var opened: PharoObject?

    init(
        runtime: PharoRuntime,
        name: String,
        opened: PharoObject?,
        onToggle: @escaping () -> Void,
        onOpen: @escaping (PharoObject) -> Void
    ) {
        self.runtime = runtime
        self.name = name
        self.opened = opened
        self.onToggle = onToggle
        self.onOpen = onOpen
    }
}

/// A method a send resolves to, opened below the editor. Its source comes with
/// the reference, so opening one asks the image for nothing.
final class PharoMethodMarkModel: ObservableObject {
    let runtime: PharoRuntime
    let reference: PharoMethodReference
    let onToggle: () -> Void
    let onOpen: (PharoObject) -> Void
    @Published var opened = false

    init(
        runtime: PharoRuntime,
        reference: PharoMethodReference,
        onToggle: @escaping () -> Void,
        onOpen: @escaping (PharoObject) -> Void
    ) {
        self.runtime = runtime
        self.reference = reference
        self.onToggle = onToggle
        self.onOpen = onOpen
    }
}

/// An undeclared name's fixes, offered from the wrench the coder puts after it,
/// and the fields of the class-definition form the "Create class" fix opens.
final class PharoUndeclaredMarkModel: ObservableObject {
    let variable: PharoUndeclaredVariable
    @Published var isDefining = false
    @Published var name: String
    @Published var superclassName = "Object"
    @Published var package = "Playground"
    @Published var tag = ""
    @Published var instanceVariables = ""
    @Published var classVariables = ""
    @Published var classInstanceVariables = ""
    var onReplace: (String) -> Void = { _ in }
    var onConfirm: () -> Void = {}
    var onChanged: () -> Void = {}

    init(variable: PharoUndeclaredVariable) {
        self.variable = variable
        self.name = variable.name
    }

    func startDefining() {
        isDefining = true
        onChanged()
    }

    func cancel() {
        isDefining = false
        onChanged()
    }
}

/// The wrench GT puts after an undeclared name, opening its fixes on a click.
private struct PharoUndeclaredWrench: View {
    @ObservedObject var model: PharoUndeclaredMarkModel

    @State private var isPointedAt = false

    var body: some View {
        Menu {
            Section("Variable is undeclared.") {
                Button("Create class \(model.variable.name)", action: model.startDefining)
                ForEach(model.variable.suggestions, id: \.self) { name in
                    Button("Use \(name) instead of \(model.variable.name)") { model.onReplace(name) }
                }
            }
        } label: {
            Image(systemName: "wrench.adjustable")
                .font(.system(size: 10))
                .foregroundStyle(isPointedAt ? Color.fridaBrand : .secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onHover { isPointedAt = $0 }
        .help("Fix")
    }
}

/// The class-definition form GT opens for "Create class": the same fields the
/// coder shows, confirmed to install the class or cancelled to drop it.
private struct PharoNewClassBody: View {
    @ObservedObject var model: PharoUndeclaredMarkModel

    var body: some View {
        if model.isDefining {
            PharoNewClassForm(model: model).pharoPane()
        }
    }
}

private struct PharoNewClassForm: View {
    @ObservedObject var model: PharoUndeclaredMarkModel

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
            field("Name", text: $model.name)
            field("Superclass", text: $model.superclassName)
            field("Package", text: $model.package)
            field("Tag", text: $model.tag)
            field("Instance-side slots", text: $model.instanceVariables)
            field("Class-side slots", text: $model.classInstanceVariables)
            field("Class vars", text: $model.classVariables)
            GridRow {
                Color.clear.frame(width: 0, height: 0)
                HStack(spacing: 6) {
                    Button(action: model.onConfirm) {
                        Image(systemName: "checkmark").frame(width: 16, height: 12)
                    }
                    .keyboardShortcut("s", modifiers: .command)
                    .help("Create")
                    Button(action: model.cancel) {
                        Image(systemName: "xmark").frame(width: 16, height: 12)
                    }
                    .help("Cancel")
                    Spacer(minLength: 0)
                }
                .controlSize(.small)
            }
        }
        .padding(10)
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        GridRow {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))
        }
    }
}

/// The triangle after a message send whose method is known.
private struct PharoMethodTriangle: View {
    @ObservedObject var model: PharoMethodMarkModel

    @State private var isPointedAt = false

    var body: some View {
        Button(action: model.onToggle) {
            Image(systemName: model.opened ? "chevron.down.circle.fill" : "chevron.right.circle")
                .font(.system(size: 11))
                .foregroundStyle(isPointedAt || model.opened ? Color.fridaBrand : .secondary)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { isPointedAt = $0 }
        .help(model.opened ? "Hide" : "Show")
    }
}

/// The sent method's source, editable and saved back to its class.
private struct PharoMethodBody: View {
    @ObservedObject var model: PharoMethodMarkModel

    var body: some View {
        if model.opened {
            PharoMethodEditor(
                reference: model.reference,
                runtime: model.runtime,
                onSelect: model.onOpen)
            .pharoPane()
        }
    }
}

/// The triangle GT puts after a class name.
private struct PharoClassTriangle: View {
    @ObservedObject var model: PharoClassMarkModel

    @State private var isPointedAt = false

    var body: some View {
        Button(action: model.onToggle) {
            Image(systemName: model.opened != nil ? "chevron.down.circle.fill" : "chevron.right.circle")
                .font(.system(size: 11))
                .foregroundStyle(isPointedAt || model.opened != nil ? Color.fridaBrand : .secondary)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { isPointedAt = $0 }
        .help(model.opened != nil ? "Hide" : "Show")
    }
}

/// The class itself: a browser of its place and methods rather than the generic
/// inspector.
private struct PharoClassBody: View {
    @ObservedObject var model: PharoClassMarkModel

    var body: some View {
        if let opened = model.opened {
            PharoObjectColumn(
                runtime: model.runtime,
                object: opened,
                onSelect: model.onOpen,
                onClose: model.onToggle)
            .pharoPane()
        }
    }
}

/// The dot GT appends once a snippet has produced something.
private struct PharoResultDot: View {
    @ObservedObject var model: PharoResultMarkModel

    @State private var isPointedAt = false

    var body: some View {
        Button(action: model.open) {
            Circle()
                .fill(isPointedAt ? Color.fridaBrand : Color.secondary)
                .frame(width: 8, height: 8)
                .opacity(model.hasResult ? 1 : 0)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { isPointedAt = $0 }
        .help("Inspect the result")
    }
}

extension NSColor {
    /// An RRGGBB run colour from the image, read in the sRGB space it named it in.
    convenience init(pharoHex hex: String) {
        let value = UInt32(hex, radix: 16) ?? 0
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1)
    }

    /// A run colour that resolves its own light or dark shade as the appearance
    /// changes, so a theme flip never has to rewrite the text's attributes.
    convenience init?(lightHex: String?, darkHex: String?) {
        guard let lightHex, let darkHex else { return nil }
        self.init(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(pharoHex: isDark ? darkHex : lightHex)
        }
    }
}

/// A mark and where in the source it belongs.
struct PharoPlacedMark: Equatable {
    let sourceOffset: Int
    let content: PharoMarkContent
}

extension PharoMarkContent: Hashable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.classTriangle(let a), .classTriangle(let b)):
            a == b
        case (.methodTriangle(let a), .methodTriangle(let b)):
            a == b
        case (.undeclaredWrench(let a), .undeclaredWrench(let b)):
            a == b
        case (.result, .result):
            true
        default:
            false
        }
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case .classTriangle(let name):
            hasher.combine(0)
            hasher.combine(name)
        case .methodTriangle(let key):
            hasher.combine(3)
            hasher.combine(key)
        case .undeclaredWrench(let key):
            hasher.combine(5)
            hasher.combine(key)
        case .result:
            hasher.combine(2)
        }
    }
}
