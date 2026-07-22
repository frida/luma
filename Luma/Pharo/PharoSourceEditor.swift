import AppKit
import SwiftUI
import Combine
import SwiftyPharo

/// What the snippet shows alongside its text: the classes the reader opened,
/// and the value the last evaluation produced.
struct PharoSnippetMarks: Equatable {
    var openedClasses: [String: PharoObject] = [:]
    var result: PharoObject?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.result?.handle == rhs.result?.handle
            && lhs.openedClasses.mapValues(\.handle) == rhs.openedClasses.mapValues(\.handle)
    }
}

/// A multi-line Smalltalk editor that grows with its text, completes from the
/// image, and carries its marks as text attachments so they take up room in the
/// line rather than sitting over the words after them.
struct PharoSourceEditor: NSViewRepresentable {
    let id: UUID
    @Binding var source: String
    @Binding var focused: UUID?
    let runtime: PharoRuntime
    let marks: PharoSnippetMarks
    let onToggleClass: (String) -> Void
    let onOpen: (PharoObject) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> PharoTextView {
        let view = PharoTextView()
        view.delegate = context.coordinator
        view.onFocused = { focused = id }
        view.completions = runtime.completionList
        view.classReferences = runtime.namedClasses(in:)
        view.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        view.isRichText = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 4, height: 6)
        view.apply(runtime: runtime, marks: marks, onToggleClass: onToggleClass, onOpen: onOpen)
        view.setSource(source)
        return view
    }

    func updateNSView(_ view: PharoTextView, context: Context) {
        context.coordinator.parent = self
        view.onFocused = { focused = id }
        view.apply(runtime: runtime, marks: marks, onToggleClass: onToggleClass, onOpen: onOpen)
        if view.source != source {
            view.setSource(source)
        }
        if focused == id, view.window?.firstResponder !== view {
            view.window?.makeFirstResponder(view)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PharoTextView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return CGSize(width: width, height: nsView.height(fitting: width))
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

/// What the image answers for a cursor: the candidates, and how far back they
/// reach so accepting one replaces the whole token rather than appending.
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
    var onFocused: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocused?() }
        return became
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

    private var runtime: PharoRuntime?
    private var marks = PharoSnippetMarks()
    private var onToggleClass: ((String) -> Void)?
    private var onOpen: ((PharoObject) -> Void)?

    private var fetched: PharoCompletionList?
    private var references: [PharoClassReference] = []
    private var referencedSource: String?
    private var isApplyingMarks = false
    private var attachments: [PharoMarkContent: PharoMarkAttachment] = [:]
    private var classModels: [String: PharoClassMarkModel] = [:]

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
        onOpen: @escaping (PharoObject) -> Void
    ) {
        self.runtime = runtime
        self.onToggleClass = onToggleClass
        self.onOpen = onOpen
        guard self.marks != marks else { return }
        self.marks = marks
        expandOpenedClasses()
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
            model.opened = opened
            resizeClassBody(name)
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
            guard let found = await classReferences?(source), self.source == source else { return }
            references = found
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

        if let result = marks.result {
            wanted.append(PharoPlacedMark(sourceOffset: source.utf16.count, content: .result(result)))
        }

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
        case .classTriangle, .result:
            let side = (font ?? .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular))
                .capHeight.rounded()
            return CGRect(x: 0, y: 0, width: side + 3, height: side)
        }
    }

    private var openedWidth: CGFloat {
        (textContainer?.size.width ?? bounds.width) - 2 * textContainerInset.width
    }

    private let openedHeight: CGFloat = 260

    private func markView(for content: PharoMarkContent) -> NSView {
        switch content {
        case .classTriangle(let name):
            PharoMarkHostingView(content: PharoClassTriangle(model: classModel(name)))
        case .classBody(let name):
            NSHostingView(rootView: PharoClassBody(model: classModel(name)))
        case .result(let object):
            PharoMarkHostingView(content: PharoResultDot { [onOpen] in onOpen?(object) })
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
        guard let layout = textLayoutManager, let container = textContainer else { return 0 }
        container.size = NSSize(width: width - 2 * textContainerInset.width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: layout.documentRange)
        return layout.usageBoundsForTextContainer.height + 2 * textContainerInset.height
    }
}

/// What a snippet marks: the triangle after a class it names, the class opened
/// in place below that line, and the value the snippet last produced. The
/// triangle and the opened class are separate so the triangle keeps its place
/// in the line while the class lands on the next.
enum PharoMarkContent {
    case classTriangle(String)
    case classBody(String)
    case result(PharoObject)

    /// Where two marks share a source position, the lower order comes first in
    /// the text, so a class's triangle sits ahead of its body.
    var insertionOrder: Int {
        switch self {
        case .classTriangle: 0
        case .classBody: 1
        case .result: 0
        }
    }
}

/// Holds a mark's view, and tells the text view which of its subviews are marks
/// so it can hand them the pointer.
final class PharoMarkHostingView: NSView {
    init(content: some View) {
        super.init(frame: .zero)
        let hosting = NSHostingView(rootView: content)
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
        hosting.frame = bounds
    }

    override var frame: NSRect {
        didSet { subviews.first?.frame = bounds }
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
        markView.frame = size
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

/// A class mark's state, which the view in the text observes: opening one has
/// the same view grow from the triangle alone to the triangle above the class.
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

/// The triangle GT puts after a class name. It reads as a button: the pointer
/// turns into a hand over it and it lights up, which the text view's own I-beam
/// would otherwise hide.
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
        .pointerStyle(.link)
        .onHover { isPointedAt = $0 }
        .help(model.opened != nil ? "Hide" : "Show")
    }
}

/// The class itself, opened on the line below its triangle. Drilling from here
/// goes to the pane beside the page, not deeper into the line. Nothing when
/// closed, so the line reads as if it were not there.
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

/// The dot GT appends once a snippet has produced something, so the reader can
/// go back to the value without evaluating again.
private struct PharoResultDot: View {
    let open: () -> Void

    @State private var isPointedAt = false

    var body: some View {
        Button(action: open) {
            Circle()
                .fill(isPointedAt ? Color.fridaBrand : Color.secondary)
                .frame(width: 8, height: 8)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .pointerStyle(.link)
        .onHover { isPointedAt = $0 }
        .help("Inspect the result")
    }
}


/// A mark and where in the source it belongs. Two marks are the same mark when
/// they say the same thing in the same place.
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
        case (.result(let a), .result(let b)):
            a.handle == b.handle
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
        case .result(let object):
            hasher.combine(2)
            hasher.combine(object.handle)
        }
    }
}
