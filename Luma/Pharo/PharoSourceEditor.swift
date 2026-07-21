import AppKit
import SwiftUI
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

        func textDidBeginEditing(_ notification: Notification) {
            parent.focused = parent.id
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

    private var runtime: PharoRuntime?
    private var marks = PharoSnippetMarks()
    private var onToggleClass: ((String) -> Void)?
    private var onOpen: ((PharoObject) -> Void)?

    private var fetched: PharoCompletionList?
    private var references: [PharoClassReference] = []
    private var referencedSource: String?
    private var isApplyingMarks = false
    private var attachments: [PharoMarkContent: PharoMarkAttachment] = [:]

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
        markUp()
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
        for mark in missing.reversed() {
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
            let opened = marks.openedClasses[reference.name]
            wanted.append(PharoPlacedMark(
                sourceOffset: reference.stop,
                content: .classToggle(reference.name, isOpen: opened != nil)))
            if let opened {
                wanted.append(PharoPlacedMark(
                    sourceOffset: reference.stop,
                    content: .opened(reference.name, opened)))
            }
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
        attachments[content] = made
        return made
    }

    private func markView(for content: PharoMarkContent) -> NSView {
        switch content {
        case .classToggle(let name, let isOpen):
            NSHostingView(rootView: PharoClassToggle(isOpen: isOpen) { [onToggleClass] in onToggleClass?(name) })
        case .opened(let name, let object):
            NSHostingView(rootView: PharoOpenedClass(
                runtime: runtime!,
                object: object,
                onSelect: { [onOpen] in onOpen?($0) },
                onClose: { [onToggleClass] in onToggleClass?(name) }))
        case .result(let object):
            NSHostingView(rootView: PharoResultDot { [onOpen] in onOpen?(object) })
        }
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
        let cursor = selectedRange().location
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

    override var rangeForUserCompletion: NSRange {
        guard let fetched else { return super.rangeForUserCompletion }
        let cursor = selectedRange().location
        let start = min(max(fetched.tokenStart - 1, 0), cursor)
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

/// The three things a snippet marks: a class it names, that class opened, and
/// the value the snippet last produced.
enum PharoMarkContent {
    case classToggle(String, isOpen: Bool)
    case opened(String, PharoObject)
    case result(PharoObject)
}

nonisolated final class PharoMarkAttachment: NSTextAttachment, @unchecked Sendable {
    /// Marks are as tall as a capital letter, which keeps them inside the
    /// ascent so showing one never makes the line taller.
    static func side(forCapHeight capHeight: CGFloat) -> CGFloat {
        capHeight.rounded()
    }

    let content: PharoMarkContent
    let markView: NSView

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
        tracksTextAttachmentViewBounds = false
        view = (textAttachment as? PharoMarkAttachment)?.markView
    }

    override func attachmentBounds(
        for attributes: [NSAttributedString.Key: Any],
        location: any NSTextLocation,
        textContainer: NSTextContainer?,
        proposedLineFragment: CGRect,
        position: CGPoint
    ) -> CGRect {
        guard let mark = textAttachment as? PharoMarkAttachment else { return .zero }

        if case .opened = mark.content {
            return CGRect(x: 0, y: 0, width: proposedLineFragment.width, height: openedHeight)
        }

        let font = attributes[.font] as? NSFont ?? .systemFont(ofSize: NSFont.systemFontSize)
        let side = PharoMarkAttachment.side(forCapHeight: font.capHeight)
        view?.frame = CGRect(x: 0, y: 0, width: side, height: side)
        return CGRect(x: 0, y: 0, width: side + 3, height: side)
    }

    private let openedHeight: CGFloat = 260
}

/// The triangle GT puts after a class name, which reads as a button because it
/// answers the pointer.
private struct PharoClassToggle: View {
    let isOpen: Bool
    let toggle: () -> Void

    @State private var isPointedAt = false

    var body: some View {
        Button(action: toggle) {
            Image(systemName: isOpen ? "chevron.down.circle.fill" : "chevron.right.circle")
                .font(.system(size: 11))
                .foregroundStyle(isPointedAt || isOpen ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .onHover { isPointedAt = $0 }
        .help(isOpen ? "Hide" : "Show")
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
                .fill(isPointedAt ? Color.accentColor : Color.secondary)
                .frame(width: 8, height: 8)
        }
        .buttonStyle(.plain)
        .onHover { isPointedAt = $0 }
        .help("Inspect the result")
    }
}

/// An opened class sits in the snippet at full width. Drilling into anything
/// here belongs in the inspection pane beside the page, not in the line.
private struct PharoOpenedClass: View {
    let runtime: PharoRuntime
    let object: PharoObject
    let onSelect: (PharoObject) -> Void
    let onClose: () -> Void

    var body: some View {
        PharoObjectColumn(runtime: runtime, object: object, onSelect: onSelect, onClose: onClose)
            .pharoPane()
            .padding(.vertical, 4)
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
        case (.classToggle(let a, let aOpen), .classToggle(let b, let bOpen)):
            a == b && aOpen == bOpen
        case (.opened(let a, let aObject), .opened(let b, let bObject)):
            a == b && aObject.handle == bObject.handle
        case (.result(let a), .result(let b)):
            a.handle == b.handle
        default:
            false
        }
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case .classToggle(let name, let isOpen):
            hasher.combine(0)
            hasher.combine(name)
            hasher.combine(isOpen)
        case .opened(let name, let object):
            hasher.combine(1)
            hasher.combine(name)
            hasher.combine(object.handle)
        case .result(let object):
            hasher.combine(2)
            hasher.combine(object.handle)
        }
    }
}
