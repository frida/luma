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

/// A multi-line Smalltalk editor. Its marks are text attachments, so they take
/// up room in the line rather than sitting over the words after them.
struct PharoSourceEditor: NSViewRepresentable {
    let id: UUID
    @Binding var source: String
    @Binding var focused: UUID?
    let runtime: PharoRuntime
    let marks: PharoSnippetMarks
    let onToggleClass: (String) -> Void
    let onOpen: (PharoObject) -> Void
    let onOpenResult: () -> Void
    var selfClass: String? = nil
    /// Marks are attachment views, which NSTextView only builds at the level it
    /// first lays them out; an editor already sitting inside a mark cannot host
    /// marks of its own, so a nested one stays plain text.
    var resolvesReferences: Bool = true

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let view = PharoTextView()
        view.delegate = context.coordinator
        view.onFocused = { if focused != id { focused = id } }
        view.completions = runtime.completionList
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
        if focused == id, view.window?.firstResponder !== view {
            view.window?.makeFirstResponder(view)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let view = scroll.documentView as! PharoTextView
        return CGSize(width: width, height: view.height(fitting: width))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PharoSourceEditor

        init(_ parent: PharoSourceEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? PharoTextView else { return }
            parent.source = view.source
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

    private func whenRunning<Answer>(_ request: () async throws -> Answer) async throws -> Answer {
        try await runningState()
        return try await request()
    }
}

/// Marks live in the text as attachments, so the source the reader edits is the
/// text with those attachment characters taken back out.
final class PharoTextView: NSTextView {
    var completions: ((String, Int) async -> PharoCompletionList)?
    var classReferences: ((String) async -> [PharoClassReference])?
    var methodReferences: ((String) async -> [PharoMethodReference])?
    var undeclaredVariables: ((String) async -> [PharoUndeclaredVariable])?
    var onFocused: (() -> Void)?
    var onEdit: ((String) -> Void)?

    private var runtime: PharoRuntime?
    private var marks = PharoSnippetMarks()
    private var onToggleClass: ((String) -> Void)?
    private var onOpen: ((PharoObject) -> Void)?

    private var fetched: PharoCompletionList?
    private var references: [PharoClassReference] = []
    private var methodRefs: [PharoMethodReference] = []
    private var undeclared: [PharoUndeclaredVariable] = []
    private var undeclaredModels: [String: PharoUndeclaredMarkModel] = [:]
    private var newClassHeights: [String: CGFloat] = [:]
    private var referencedSource: String?
    private var isApplyingMarks = false
    private var attachments: [PharoMarkContent: PharoMarkAttachment] = [:]
    private var classModels: [String: PharoClassMarkModel] = [:]
    private var methodModels: [String: PharoMethodMarkModel] = [:]
    private var methodBodyHeights: [String: CGFloat] = [:]
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

    /// A class opening or closing is a change to the mark already in the text,
    /// not a new one: the same view swaps between the toggle alone and the
    /// toggle above the class, and the attachment grows or shrinks to match.
    /// Reinserting it would leave a fresh attachment blank, because NSTextView
    /// only builds an attachment's view where it first laid the attachment out.
    private func expandOpenedClasses() {
        for (name, model) in classModels {
            let opened = marks.openedClasses[name]
            guard model.opened?.handle != opened?.handle else { continue }
            // apply() runs while SwiftUI is updating, and a mark's state is
            // published, so it changes once that pass has finished.
            DispatchQueue.main.async {
                model.opened = opened
                self.resizeClassBody(name)
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

    private func resizeClassBody(_ name: String) {
        guard let attachment = attachments[.classBody(name)] else { return }
        let wanted = bounds(for: .classBody(name))
        guard attachment.bounds != wanted else { return }
        attachment.resize(to: wanted)
        textLayoutManager.map { $0.invalidateLayout(for: $0.documentRange) }
    }

    override func layout() {
        super.layout()
        for name in classModels.keys where classModels[name]?.opened != nil {
            resizeClassBody(name)
        }
        for key in methodModels.keys where methodModels[key]?.opened == true {
            resizeMethodBody(key)
        }
        for key in undeclaredModels.keys where undeclaredModels[key]?.isDefining == true {
            resizeNewClassBody(key)
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
        guard referencedSource != source else { return reconcileMarks() }

        referencedSource = source
        Task { @MainActor in
            let classes = await classReferences?(source) ?? []
            let methods = await methodReferences?(source) ?? []
            let undeclaredNames = await undeclaredVariables?(source) ?? []
            guard self.source == source else { return }
            references = classes
            methodRefs = methods
            undeclared = undeclaredNames
            reconcileMarks()
        }
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
            wanted.append(PharoPlacedMark(sourceOffset: reference.stop, content: .classBody(reference.name)))
        }

        for reference in methodRefs {
            wanted.append(PharoPlacedMark(sourceOffset: reference.stop, content: .methodTriangle(reference.id)))
            wanted.append(PharoPlacedMark(sourceOffset: reference.stop, content: .methodBody(reference.id)))
        }

        for variable in undeclared {
            wanted.append(PharoPlacedMark(sourceOffset: variable.stop, content: .undeclaredWrench(variable.id)))
            wanted.append(PharoPlacedMark(sourceOffset: variable.stop, content: .newClassBody(variable.id)))
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

    /// Marks keep their attachment across a move, so an opened class does not
    /// lose which of its views the reader was looking at.
    private func attachment(for content: PharoMarkContent) -> PharoMarkAttachment {
        if let known = attachments[content] {
            return known
        }

        let made = PharoMarkAttachment(content: content, markView: markView(for: content))
        made.resize(to: bounds(for: content))
        attachments[content] = made
        return made
    }

    /// A triangle or dot is as tall as a capital letter, which keeps it inside
    /// the ascent so showing one never makes the line taller. A class's body
    /// takes the full width when open, so it lands on a line of its own, and
    /// takes no room at all when closed.
    private func bounds(for content: PharoMarkContent) -> CGRect {
        switch content {
        case .classBody(let name):
            // A truly empty rect reads as "unset" and the line grows to the
            // hosting view instead; a hair of size keeps the closed body from
            // taking any the reader can see.
            return classModels[name]?.opened != nil
                ? CGRect(x: 0, y: 0, width: openedWidth, height: openedHeight)
                : CGRect(x: 0, y: 0, width: 0.01, height: 0.01)
        case .methodBody(let key):
            return methodModels[key]?.opened == true
                ? CGRect(x: 0, y: 0, width: openedWidth, height: methodBodyHeights[key] ?? openedHeight)
                : CGRect(x: 0, y: 0, width: 0.01, height: 0.01)
        case .newClassBody(let key):
            return undeclaredModels[key]?.isDefining == true
                ? CGRect(x: 0, y: 0, width: openedWidth, height: newClassHeights[key] ?? openedHeight)
                : CGRect(x: 0, y: 0, width: 0.01, height: 0.01)
        case .result where !resultModel.hasResult:
            return CGRect(x: 0, y: 0, width: 0.01, height: 0.01)
        case .classTriangle, .methodTriangle, .undeclaredWrench, .result:
            let side = (font ?? .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular))
                .capHeight.rounded()
            return CGRect(x: 0, y: 0, width: side + 3, height: side)
        }
    }

    private var openedWidth: CGFloat {
        (enclosingScrollView?.contentSize.width ?? bounds.width) - 2 * textContainerInset.width
    }

    private let openedHeight: CGFloat = 260
    private let newClassMaxHeight: CGFloat = 460

    private func markView(for content: PharoMarkContent) -> NSView {
        switch content {
        case .classTriangle(let name):
            PharoMarkHostingView(content: PharoClassTriangle(model: classModel(name)))
        case .classBody(let name):
            NSHostingView(rootView: PharoClassBody(model: classModel(name)))
        case .methodTriangle(let key):
            PharoMarkHostingView(content: PharoMethodTriangle(model: methodModel(key)))
        case .methodBody(let key):
            NSHostingView(rootView: PharoMethodBody(model: methodModel(key)))
        case .undeclaredWrench(let key):
            PharoMarkHostingView(content: PharoUndeclaredWrench(model: undeclaredModel(key)))
        case .newClassBody(let key):
            NSHostingView(rootView: PharoNewClassBody(model: undeclaredModel(key)))
        case .result:
            PharoMarkHostingView(content: PharoResultDot(model: resultModel))
        }
    }

    private func classModel(_ name: String) -> PharoClassMarkModel {
        if let existing = classModels[name] {
            return existing
        }

        let model = PharoClassMarkModel(
            runtime: runtime!,
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
        model.onHeight = { [weak self] in self?.noteMethodBodyHeight(key, $0) }
        methodModels[key] = model
        return model
    }

    private func toggleMethod(_ key: String) {
        guard let model = methodModels[key] else { return }
        model.opened.toggle()
        resizeMethodBody(key)
    }

    private func noteMethodBodyHeight(_ key: String, _ height: CGFloat) {
        let bounded = min(height, openedHeight)
        guard methodBodyHeights[key] != bounded else { return }
        methodBodyHeights[key] = bounded
        resizeMethodBody(key)
    }

    private func resizeMethodBody(_ key: String) {
        guard let attachment = attachments[.methodBody(key)] else { return }
        let wanted = bounds(for: .methodBody(key))
        guard attachment.bounds != wanted else { return }
        attachment.resize(to: wanted)
        textLayoutManager.map { $0.invalidateLayout(for: $0.documentRange) }
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

    /// The marks are invisible to the caret: crossing a class name's marks, and
    /// the space they push ahead of the next word, takes one press, not one per
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

    private func undeclaredModel(_ key: String) -> PharoUndeclaredMarkModel {
        if let existing = undeclaredModels[key] {
            return existing
        }

        let variable = undeclared.first { $0.id == key }!
        let model = PharoUndeclaredMarkModel(variable: variable)
        model.onReplace = { [weak self] name in self?.replace(variable, with: name) }
        model.onConfirm = { [weak self, weak model] in model.map { self?.defineClass($0) } }
        model.onNeedsResize = { [weak self] in self?.resizeNewClassBody(key) }
        model.onHeight = { [weak self] in self?.noteNewClassHeight(key, $0) }
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

    private func noteNewClassHeight(_ key: String, _ height: CGFloat) {
        let bounded = min(height, newClassMaxHeight)
        guard newClassHeights[key] != bounded else { return }
        newClassHeights[key] = bounded
        resizeNewClassBody(key)
    }

    private func resizeNewClassBody(_ key: String) {
        guard let attachment = attachments[.newClassBody(key)] else { return }
        let wanted = bounds(for: .newClassBody(key))
        guard attachment.bounds != wanted else { return }
        attachment.resize(to: wanted)
        textLayoutManager.map { $0.invalidateLayout(for: $0.documentRange) }
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
        guard let typed = string as? String, typed.allSatisfy(\.isLetter) else { return }
        complete(nil)
    }

    func height(fitting width: CGFloat) -> CGFloat {
        guard let layout = textLayoutManager else { return 0 }
        layout.ensureLayout(for: layout.documentRange)
        return layout.usageBoundsForTextContainer.height + 2 * textContainerInset.height
    }
}

/// What a snippet marks. A class's triangle and its opened body are separate
/// marks, so the triangle keeps its place in the line while the body lands on
/// the next.
enum PharoMarkContent {
    case classTriangle(String)
    case classBody(String)
    case methodTriangle(String)
    case methodBody(String)
    case undeclaredWrench(String)
    case newClassBody(String)
    case result

    /// Where two marks share a source position, the lower order comes first in
    /// the text, so a triangle sits ahead of its body.
    var insertionOrder: Int {
        switch self {
        case .classTriangle: 0
        case .classBody: 1
        case .methodTriangle: 0
        case .methodBody: 1
        case .undeclaredWrench: 0
        case .newClassBody: 1
        case .result: 2
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

/// A class mark's state, which the view in the text observes.
/// What the snippet last produced, which the dot in the text watches.
final class PharoResultMarkModel: ObservableObject {
    @Published var hasResult = false
    var open: () -> Void = {}
}

final class PharoClassMarkModel: ObservableObject {
    let runtime: PharoRuntime
    let onToggle: () -> Void
    let onOpen: (PharoObject) -> Void
    @Published var opened: PharoObject?

    init(
        runtime: PharoRuntime,
        opened: PharoObject?,
        onToggle: @escaping () -> Void,
        onOpen: @escaping (PharoObject) -> Void
    ) {
        self.runtime = runtime
        self.opened = opened
        self.onToggle = onToggle
        self.onOpen = onOpen
    }
}

/// A method a send resolves to, opened in place below the send. Its source
/// comes with the reference, so opening one asks the image for nothing.
final class PharoMethodMarkModel: ObservableObject {
    let runtime: PharoRuntime
    let reference: PharoMethodReference
    let onToggle: () -> Void
    let onOpen: (PharoObject) -> Void
    var onHeight: (CGFloat) -> Void = { _ in }
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
    var onNeedsResize: () -> Void = {}
    var onHeight: (CGFloat) -> Void = { _ in }

    init(variable: PharoUndeclaredVariable) {
        self.variable = variable
        self.name = variable.name
    }

    func startDefining() {
        isDefining = true
        onNeedsResize()
    }

    func cancel() {
        isDefining = false
        onNeedsResize()
    }
}

/// The wrench GT puts after an undeclared name, opening its fixes on a click.
private struct PharoUndeclaredWrench: View {
    @ObservedObject var model: PharoUndeclaredMarkModel

    @State private var isShowingMenu = false
    @State private var isPointedAt = false

    var body: some View {
        Button { isShowingMenu.toggle() } label: {
            Image(systemName: "wrench.adjustable")
                .font(.system(size: 10))
                .foregroundStyle(isPointedAt || isShowingMenu ? Color.fridaBrand : .secondary)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { isPointedAt = $0 }
        .help("Fix")
        .popover(isPresented: $isShowingMenu, arrowEdge: .bottom) {
            PharoQuickFixMenu(
                variable: model.variable,
                onCreateClass: model.startDefining,
                onReplace: model.onReplace,
                onDismiss: { isShowingMenu = false })
        }
    }
}

/// The class-definition form GT opens for "Create class": the same fields the
/// coder shows, confirmed to install the class or cancelled to drop it.
private struct PharoNewClassBody: View {
    @ObservedObject var model: PharoUndeclaredMarkModel

    var body: some View {
        if model.isDefining {
            PharoNewClassForm(model: model)
                .pharoPane()
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { model.onHeight($0) }
                .frame(maxHeight: .infinity, alignment: .top)
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

/// The sent method's source, editable and saved back to its class, opened below
/// the send the way the class body opens below a class name.
private struct PharoMethodBody: View {
    @ObservedObject var model: PharoMethodMarkModel

    var body: some View {
        if model.opened {
            PharoMethodEditor(
                reference: model.reference,
                runtime: model.runtime,
                onSelect: model.onOpen)
            .pharoPane()
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { model.onHeight($0) }
            .frame(maxHeight: .infinity, alignment: .top)
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

/// The class itself, opened on the line below its triangle: a browser of its
/// place and methods rather than the generic inspector.
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

/// The fixes GT offers under an undeclared name: make it a class, or correct it
/// to one that already exists.
private struct PharoQuickFixMenu: View {
    let variable: PharoUndeclaredVariable
    let onCreateClass: () -> Void
    let onReplace: (String) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Variable is undeclared.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()
            fix("Create class \(variable.name)", action: onCreateClass)
            ForEach(variable.suggestions, id: \.self) { name in
                fix("Use \(name) instead of \(variable.name)") { onReplace(name) }
            }
        }
        .frame(width: 260)
    }

    private func fix(_ title: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            onDismiss()
        } label: {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
        case (.classBody(let a), .classBody(let b)):
            a == b
        case (.methodTriangle(let a), .methodTriangle(let b)):
            a == b
        case (.methodBody(let a), .methodBody(let b)):
            a == b
        case (.undeclaredWrench(let a), .undeclaredWrench(let b)):
            a == b
        case (.newClassBody(let a), .newClassBody(let b)):
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
        case .classBody(let name):
            hasher.combine(1)
            hasher.combine(name)
        case .methodTriangle(let key):
            hasher.combine(3)
            hasher.combine(key)
        case .methodBody(let key):
            hasher.combine(4)
            hasher.combine(key)
        case .undeclaredWrench(let key):
            hasher.combine(5)
            hasher.combine(key)
        case .newClassBody(let key):
            hasher.combine(6)
            hasher.combine(key)
        case .result:
            hasher.combine(2)
        }
    }
}
