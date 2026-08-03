#if os(macOS)
import AppKit
import SwiftUI
import Combine
import SwiftyPharo

/// An error a snippet raised, with where in its source the image placed it --
/// 1-based, or nothing for a runtime error -- so the dot marks the spot.
struct PharoEvaluationError: Equatable {
    let message: String
    let position: Int?
}

/// What the snippet shows alongside its text.
struct PharoSnippetMarks: Equatable {
    var openedClasses: [String: PharoObject] = [:]
    var hasResult: Bool = false
    var error: PharoEvaluationError?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.hasResult == rhs.hasResult
            && lhs.error == rhs.error
            && lhs.openedClasses.mapValues(\.handle) == rhs.openedClasses.mapValues(\.handle)
    }
}

/// Bumped whenever an open body reserves or releases space in the text, so the
/// editor is re-measured and the snippet grows to fit the bodies it now holds.
final class PharoBodyMetrics: ObservableObject {
    @Published var revision = 0
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
/// marks sit inline as triangles, and the body a mark opens rides on its own
/// line just below it, as a view attachment the text lays out and reflows.
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

    @StateObject private var metrics = PharoBodyMetrics()

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
            metrics: metrics)
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
    let metrics: PharoBodyMetrics

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let view = PharoTextView()
        view.delegate = context.coordinator
        view.metrics = metrics
        view.onFocused = { if focused != id { focused = id } }
        view.completions = runtime.completionList
        view.styleSpans = { source in await runtime.styles(in: source, isMethod: isMethod) }
        if resolvesReferences {
            view.classReferences = runtime.namedClasses(in:)
            view.methodReferences = { source in await runtime.methods(in: source, selfClass: selfClass) }
            view.undeclaredVariables = runtime.undeclared(in:)
        }
        view.onEdit = { source = $0 }
        view.font = PharoTextView.sourceFont
        view.allowsUndo = true
        view.isRichText = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 4, height: 6)
        view.isHorizontallyResizable = true
        view.isVerticallyResizable = true
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textStorage?.delegate = view
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
        private let textUndoManager = UndoManager()

        init(_ parent: PharoTextEditor) {
            self.parent = parent
        }

        // Each editor undoes its own edits rather than sharing the window's
        // manager, where a snippet's undo could reach into another's.
        func undoManager(for view: NSTextView) -> UndoManager? {
            textUndoManager
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

    /// The methods a browse turns up, or nothing when the image is down or the
    /// cursor is on no selector.
    func browsing(_ kind: PharoBrowseKind, in source: String, at position: Int) async -> PharoObject? {
        (try? await whenRunning { try await browse(kind, source: source, at: position) })?.result
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

/// Marks and the bodies they open both live in the text as attachments, so the
/// source the reader edits is the text with those attachment characters -- and
/// the line separators that set a body on its own line -- taken back out.
final class PharoTextView: NSTextView, NSTextStorageDelegate {
    var completions: ((String, Int) async -> PharoCompletionList)?
    var classReferences: ((String) async -> [PharoClassReference])?
    var methodReferences: ((String) async -> [PharoMethodReference])?
    var undeclaredVariables: ((String) async -> [PharoUndeclaredVariable])?
    var styleSpans: ((String) async -> [PharoStyleSpan])?
    var onFocused: (() -> Void)?
    var onEdit: ((String) -> Void)?
    var metrics: PharoBodyMetrics?

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
    private var pendingMarkUp: DispatchWorkItem?
    private var argumentPlaceholders: [NSRange] = []
    private var isApplyingMarks = false
    private var attachments: [PharoMarkContent: PharoMarkAttachment] = [:]
    private var bodyAttachments: [String: PharoBodyAttachment] = [:]
    private var classModels: [String: PharoClassMarkModel] = [:]
    private var methodModels: [String: PharoMethodMarkModel] = [:]
    private var undeclaredModels: [String: PharoUndeclaredMarkModel] = [:]
    private let resultModel = PharoResultMarkModel()

    var source: String {
        bareText(in: NSRange(location: 0, length: string.utf16.count))
    }

    func setSource(_ newSource: String) {
        replaceText(with: NSAttributedString(string: newSource, attributes: sourceAttributes))
        markUp()
    }

    /// The reader's text within a range, with the units the text carries but the
    /// source does not -- a mark's attachment, a body's, and the newline that
    /// drops that body onto its own line -- taken back out.
    private func bareText(in range: NSRange) -> String {
        let carried = carriedOffsets()
        let units = Array(string.utf16)
        let kept = (range.location..<NSMaxRange(range)).filter { !carried.contains($0) }.map { units[$0] }
        return String(utf16CodeUnits: kept, count: kept.count)
    }

    /// The storage offsets the source does not count: every attachment, and the
    /// newline standing just before each body that sets it on its own line.
    private func carriedOffsets() -> Set<Int> {
        guard let storage = textStorage else { return [] }
        var carried: Set<Int> = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) {
            value, range, _ in
            guard value is NSTextAttachment else { return }
            carried.insert(range.location)
            if value is PharoBodyAttachment {
                carried.insert(range.location - 1)
                carried.insert(range.location + 1)
            }
        }
        return carried
    }

    /// Copy and cut hand over the source alone, with the mark characters that
    /// hold the triangles and dots taken back out, so a paste elsewhere is the
    /// text the reader sees rather than that text peppered with placeholders.
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.string]
    }

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        pboard.setString(bareText(in: selectedRange()), forType: .string)
        return true
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
    /// class body under its mark.
    private func expandOpenedClasses() {
        for (name, model) in classModels {
            let opened = marks.openedClasses[name]
            guard model.opened?.handle != opened?.handle else { continue }
            DispatchQueue.main.async {
                model.opened = opened
                self.reconcileBodies()
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
            self.positionMarkOverlays()
        }
    }

    /// Each mark's view is a real subview, laid over the space its attachment
    /// holds open, so it shows the moment its line is laid out rather than
    /// waiting for the text view to be first responder.
    override func layout() {
        super.layout()
        positionMarkOverlays()
    }

    private var bodyVisibleWidth: CGFloat {
        let visible = enclosingScrollView?.contentView.bounds.width ?? bounds.width
        return max(visible - 2 * textContainerInset.width, 80)
    }

    /// Each mark keeps to the glyph its attachment holds; each body spreads over
    /// the whole line its own paragraph holds open, held at the visible left so
    /// long lines scroll under it rather than carrying it off the side.
    private func positionMarkOverlays() {
        guard let storage = textStorage, let layout = textLayoutManager else { return }
        let origin = textContainerOrigin
        let pinnedX = (enclosingScrollView?.contentView.bounds.origin.x ?? 0) + textContainerInset.width
        var presentMarks: Set<PharoMarkContent> = []
        var presentBodies: Set<String> = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) {
            value, range, _ in
            if let mark = value as? PharoMarkAttachment {
                presentMarks.insert(mark.content)
                guard let frame = markFrame(forStorage: range, in: layout) else { return }
                if mark.markView.superview !== self { addSubview(mark.markView) }
                mark.markView.frame = frame.offsetBy(dx: origin.x, dy: origin.y)
            } else if let body = value as? PharoBodyAttachment {
                presentBodies.insert(body.id)
                guard let frame = fragmentFrame(forStorage: range, in: layout) else { return }
                if body.bodyView.superview !== self { addSubview(body.bodyView) }
                let line = frame.offsetBy(dx: origin.x, dy: origin.y)
                body.bodyView.frame = CGRect(x: pinnedX, y: line.minY, width: bodyVisibleWidth, height: line.height)
            }
        }
        for (content, attachment) in attachments where !presentMarks.contains(content) {
            attachment.markView.removeFromSuperview()
        }
        for (id, attachment) in bodyAttachments where !presentBodies.contains(id) {
            attachment.bodyView.removeFromSuperview()
        }
    }

    private func markFrame(forStorage range: NSRange, in layout: NSTextLayoutManager) -> CGRect? {
        guard let content = layout.textContentManager,
            let start = content.location(content.documentRange.location, offsetBy: range.location),
            let end = content.location(start, offsetBy: range.length),
            let textRange = NSTextRange(location: start, end: end)
        else { return nil }

        var frame: CGRect?
        layout.ensureLayout(for: textRange)
        layout.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, segment, _, _ in
            frame = segment
            return false
        }
        return frame
    }

    /// The whole frame of the line a body's paragraph holds open, which its
    /// minimum line height has grown to the body's height.
    private func fragmentFrame(forStorage range: NSRange, in layout: NSTextLayoutManager) -> CGRect? {
        guard let content = layout.textContentManager,
            let location = content.location(content.documentRange.location, offsetBy: range.location)
        else { return nil }
        return layout.textLayoutFragment(for: location)?.layoutFragmentFrame
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
            reconcileBodies()
            return
        }

        // Each fetch is four image round trips, served one at a time, so asking
        // on every keystroke queues a backlog that shows stale marks for seconds.
        // Waiting for a pause coalesces a burst of edits into a single ask.
        pendingMarkUp?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fetchMarks(for: source) }
        pendingMarkUp = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func fetchMarks(for source: String) {
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
            referencedSource = source
            reconcileMarks()
            reconcileBodies()
            applyStyle()
        }
    }

    /// Paint the coloured runs GT would over the source, mapped past the mark
    /// characters, on a plain label-coloured ground. Each run's colour resolves
    /// the light or dark shade itself, so a theme flip redraws without another
    /// attribute pass -- which would relayout and unsettle the marks.
    private func applyStyle() {
        guard let storage = textStorage else { return }
        let plain = Self.sourceFont
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
        let selection = selectedRange()
        let selectionStart = sourceOffset(ofStorage: selection.location)
        let selectionEnd = sourceOffset(ofStorage: NSMaxRange(selection))
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
        let restoredStart = storageOffset(forSource: selectionStart)
        setSelectedRange(NSRange(location: restoredStart, length: storageOffset(forSource: selectionEnd) - restoredStart))
        isApplyingMarks = false
        positionMarkOverlays()
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
        if let error = marks.error {
            let offset = min(max((error.position ?? 1) - 1, 0), source.utf16.count)
            wanted.append(PharoPlacedMark(sourceOffset: offset, content: .errorDot(error.message)))
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
        let capHeight = Self.sourceFont.capHeight.rounded()
        switch content {
        case .result where !resultModel.hasResult:
            return CGRect(x: 0, y: 0, width: 0.01, height: 0.01)
        case .errorDot:
            let side = (capHeight * 1.4).rounded()
            return CGRect(x: 0, y: 0, width: side + 4, height: side)
        case .classTriangle, .methodTriangle, .undeclaredWrench, .result:
            return CGRect(x: 0, y: 0, width: capHeight + 3, height: capHeight)
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
        case .errorDot(let message):
            PharoMarkHostingView(content: PharoErrorDot(message: message))
        }
    }

    /// Bring the bodies laid into the text in line with the marks the reader has
    /// opened, each set on its own line just under the mark whose body it is. The
    /// text reserves and reflows their space; here only their characters move.
    private func reconcileBodies() {
        guard let storage = textStorage else { return }
        let wanted = openBodyItems()
        let present = presentBodyLocations()
        let stale = present.keys.filter { id in !wanted.contains { $0.item.id == id } }
        let missing = wanted.filter { present[$0.item.id] == nil }
        guard !stale.isEmpty || !missing.isEmpty else { return }

        isApplyingMarks = true
        let selectionStart = sourceOffset(ofStorage: selectedRange().location)
        let selectionEnd = sourceOffset(ofStorage: NSMaxRange(selectedRange()))
        storage.beginEditing()
        for id in stale.sorted(by: { present[$0]! > present[$1]! }) {
            storage.deleteCharacters(in: NSRange(location: present[id]! - 1, length: 3))
            bodyAttachments[id] = nil
        }
        for entry in missing.sorted(by: { $0.markLocation > $1.markLocation }) {
            insertBody(entry.item, at: bodyStart(after: entry.markLocation), in: storage)
        }
        storage.endEditing()
        let restoredStart = storageOffset(forSource: selectionStart)
        setSelectedRange(NSRange(location: restoredStart, length: storageOffset(forSource: selectionEnd) - restoredStart))
        isApplyingMarks = false
        relayoutBodies()
    }

    private func openBodyItems() -> [(markLocation: Int, item: PharoBodyItem)] {
        var open: [(location: Int, item: PharoBodyItem)] = []
        for reference in references {
            if let model = classModels[reference.name], model.opened != nil,
                let location = markLocation(of: .classTriangle(reference.name)) {
                open.append((location, .classBody(model)))
            }
        }
        for reference in methodRefs {
            if let model = methodModels[reference.id], model.opened,
                let location = markLocation(of: .methodTriangle(reference.id)) {
                open.append((location, .methodBody(model)))
            }
        }
        for variable in undeclared {
            if let model = undeclaredModels[variable.id], model.isDefining,
                let location = markLocation(of: .undeclaredWrench(variable.id)) {
                open.append((location, .newClass(model)))
            }
        }
        return open.sorted { $0.location < $1.location }.map { (markLocation: $0.location, item: $0.item) }
    }

    private func presentBodyLocations() -> [String: Int] {
        guard let storage = textStorage else { return [:] }
        var located: [String: Int] = [:]
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) {
            value, range, _ in
            guard let attachment = value as? PharoBodyAttachment else { return }
            located[attachment.id] = range.location
        }
        return located
    }

    /// A body sits on a line of its own right after its mark, with the rest of the
    /// send carried on below it: a newline breaks the line off before the body and
    /// another after it, the attachment anchors it, and the line's paragraph holds
    /// it open to the body's height.
    private func insertBody(_ item: PharoBodyItem, at location: Int, in storage: NSTextStorage) {
        let attachment = makeBodyAttachment(for: item)
        bodyAttachments[item.id] = attachment
        let carrier = NSMutableAttributedString(string: "\n", attributes: sourceAttributes)
        carrier.append(NSAttributedString(attachment: attachment))
        carrier.append(NSAttributedString(string: "\n", attributes: sourceAttributes))
        carrier.addAttribute(
            .paragraphStyle,
            value: bodyLineHeight(attachment.height),
            range: NSRange(location: 1, length: 2))
        storage.insert(carrier, at: location)
    }

    private func makeBodyAttachment(for item: PharoBodyItem) -> PharoBodyAttachment {
        let id = item.id
        let host = NSHostingView(rootView: bodyContent(for: item, id: id))
        let attachment = PharoBodyAttachment(id: id, bodyView: host)
        attachment.height = measuredHeight(of: host)
        return attachment
    }

    private func bodyContent(for item: PharoBodyItem, id: String) -> AnyView {
        AnyView(
            bodyView(for: item)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { [weak self] height in
                    self?.updateBodyHeight(id: id, to: height)
                })
    }

    @ViewBuilder
    private func bodyView(for item: PharoBodyItem) -> some View {
        switch item {
        case .classBody(let model): PharoClassBody(model: model)
        case .methodBody(let model): PharoMethodBody(model: model)
        case .newClass(let model): PharoNewClassBody(model: model)
        }
    }

    private func measuredHeight(of host: NSHostingView<AnyView>) -> CGFloat {
        host.frame.size.width = bodyVisibleWidth
        host.layoutSubtreeIfNeeded()
        return max(host.fittingSize.height, 1)
    }

    private func bodyLineHeight(_ height: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = height
        style.maximumLineHeight = height
        return style
    }

    private func updateBodyHeight(id: String, to height: CGFloat) {
        guard height > 0, let attachment = bodyAttachments[id], abs(attachment.height - height) > 0.5 else { return }
        attachment.height = height
        applyBodyLineHeights()
        relayoutBodies()
    }

    /// Bring each body's line up to the height its body now needs. A resized box
    /// changes no text, so the storage is told its attributes moved to re-lay the
    /// line at once, and the code below drops to what the bodies now take.
    private func applyBodyLineHeights() {
        guard let storage = textStorage else { return }
        isApplyingMarks = true
        storage.beginEditing()
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) {
            value, range, _ in
            guard let body = value as? PharoBodyAttachment else { return }
            let line = NSRange(location: range.location, length: 2)
            storage.addAttribute(.paragraphStyle, value: bodyLineHeight(body.height), range: line)
            storage.edited(.editedAttributes, range: line, changeInLength: 0)
        }
        storage.endEditing()
        isApplyingMarks = false
    }

    private func relayoutBodies() {
        guard let layout = textLayoutManager else { return }
        layout.invalidateLayout(for: layout.documentRange)
        layout.ensureLayout(for: layout.documentRange)
        positionMarkOverlays()
        let metrics = metrics
        DispatchQueue.main.async { metrics?.revision += 1 }
    }

    /// Where a body opens: past the mark and the spaces that follow it, so the
    /// blanks stay at the end of the code line and the rest of the send starts
    /// its own line clean rather than indented by them.
    private func bodyStart(after markLocation: Int) -> Int {
        let units = Array(string.utf16)
        var at = markLocation + 1
        while at < units.count, units[at] == 0x20 || units[at] == 0x09 { at += 1 }
        return at
    }

    private func markLocation(of content: PharoMarkContent) -> Int? {
        guard let storage = textStorage else { return nil }
        var found: Int?
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) {
            value, range, stop in
            if let attachment = value as? PharoMarkAttachment, attachment.content == content {
                found = range.location
                stop.pointee = true
            }
        }
        return found
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
        reconcileBodies()
    }

    private func undeclaredModel(_ key: String) -> PharoUndeclaredMarkModel {
        if let existing = undeclaredModels[key] {
            return existing
        }

        let variable = undeclared.first { $0.id == key }!
        let model = PharoUndeclaredMarkModel(variable: variable)
        model.onReplace = { [weak self] name in self?.replace(variable, with: name) }
        model.onConfirm = { [weak self, weak model] in model.map { self?.defineClass($0) } }
        model.onChanged = { [weak self] in self?.reconcileBodies() }
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
        sourceOffset(ofStorage: selectedRange().location)
    }

    private func storageOffset(forSource cursor: Int) -> Int {
        let carried = carriedOffsets()
        let count = string.utf16.count
        var counted = 0
        var offset = 0
        while offset < count, counted < cursor {
            if !carried.contains(offset) {
                counted += 1
            }
            offset += 1
        }
        return offset
    }

    private func sourceOffset(ofStorage offset: Int) -> Int {
        let carried = carriedOffsets()
        return (0..<offset).count { !carried.contains($0) }
    }

    private let markCharacter: UTF16.CodeUnit = 0xFFFC

    static let sourceFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

    private var sourceAttributes: [NSAttributedString.Key: Any] {
        [
            .font: Self.sourceFont,
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

        let carried = carriedOffsets()
        let count = string.utf16.count
        var caret = selection.location
        while caret > 0, caret <= count, carried.contains(caret - 1) {
            caret += forward ? 1 : -1
            guard caret >= 0, caret <= count else { break }
        }
        setSelectedRange(NSRange(location: max(0, min(caret, count)), length: 0))
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
        let source = self.source
        let cursor = sourceCursor
        Task { @MainActor in
            guard let list = await completions?(source, cursor), self.source == source else { return }
            fetched = list
            guard !list.candidates.isEmpty else { return }
            super.complete(sender)
        }
    }

    // The browse keys are the system's Minimize and New; catching them here, while
    // this editor holds focus, keeps them from the Window and File menus.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self,
            event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            switch event.charactersIgnoringModifiers {
            case "m": browse(.implementors); return true
            case "n": browse(.senders); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    private func browse(_ kind: PharoBrowseKind) {
        guard let runtime, let onOpen else { return }
        let source = self.source
        let cursor = sourceCursor
        Task { @MainActor in
            if let methods = await runtime.browsing(kind, in: source, at: cursor) {
                onOpen(methods)
            }
        }
    }

    override func completions(
        forPartialWordRange charRange: NSRange,
        indexOfSelectedItem index: UnsafeMutablePointer<Int>?
    ) -> [String]? {
        let noPreselection = -1
        index?.pointee = noPreselection
        return fetched?.candidates
    }

    /// The token the caret sits at the end of, computed afresh so it tracks each
    /// keystroke: once it is empty -- right after a colon -- there is nothing to
    /// complete, and the panel dismisses rather than offering a stale selector.
    override var rangeForUserCompletion: NSRange {
        let units = Array(string.utf16)
        let cursor = min(selectedRange().location, units.count)
        var start = cursor
        while start > 0, isTokenUnit(units[start - 1]) { start -= 1 }
        return NSRange(location: start, length: cursor - start)
    }

    private func isTokenUnit(_ unit: UTF16.CodeUnit) -> Bool {
        (unit >= 48 && unit <= 57) || (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) || unit == 95
    }

    /// A keyword selector completes to its keywords spaced for arguments, each a
    /// placeholder the reader tabs through and types over. The completed word is
    /// the whole selector at its first keyword and the next keyword after that,
    /// so laying it over the token adds only what has not been typed.
    override func insertCompletion(_ word: String, forPartialWordRange charRange: NSRange, movement: Int, isFinal: Bool) {
        guard isFinal, word.contains(":"), let storage = textStorage else {
            return super.insertCompletion(word, forPartialWordRange: charRange, movement: movement, isFinal: isFinal)
        }
        // By the time the choice is final the panel has already previewed the
        // word into the text over the token; the template replaces that preview,
        // not the token, which would leave the preview's tail behind.
        let previewed = NSRange(location: charRange.location, length: (word as NSString).length)
        let replacing = NSMaxRange(previewed) <= (string as NSString).length
            && (string as NSString).substring(with: previewed) == word ? previewed : charRange
        let (text, placeholders) = keywordTemplate(word)
        guard shouldChangeText(in: replacing, replacementString: text.string) else { return }
        storage.replaceCharacters(in: replacing, with: text)
        didChangeText()
        argumentPlaceholders = placeholders.map { NSRange(location: replacing.location + $0.location, length: $0.length) }
        guard let first = argumentPlaceholders.first else { return }
        // The completion sets its own insertion point once this returns, so the
        // first placeholder is selected after that, not before.
        DispatchQueue.main.async { [weak self] in self?.setSelectedRange(first) }
    }

    private func keywordTemplate(_ selector: String) -> (text: NSAttributedString, placeholders: [NSRange]) {
        let keywords = selector.split(separator: ":").map(String.init)
        let text = NSMutableAttributedString()
        var placeholders: [NSRange] = []
        for (index, keyword) in keywords.enumerated() {
            text.append(NSAttributedString(string: "\(keyword): ", attributes: sourceAttributes))
            placeholders.append(NSRange(location: text.length, length: 1))
            text.append(NSAttributedString(attachment: placeholderAttachment()))
            if index < keywords.count - 1 {
                text.append(NSAttributedString(string: " ", attributes: sourceAttributes))
            }
        }
        return (text, placeholders)
    }

    /// Each argument slot rides a token the way Xcode draws a placeholder: a
    /// rounded capsule the reader tabs onto and types over. The keyword already
    /// names it, so the capsule is a plain marker rather than the keyword echoed.
    private func placeholderAttachment() -> NSTextAttachment {
        let attachment = NSTextAttachment()
        let pill = Self.placeholderPill
        attachment.image = pill
        attachment.bounds = CGRect(
            x: 0,
            y: (Self.sourceFont.descender - 1).rounded(),
            width: pill.size.width,
            height: pill.size.height)
        return attachment
    }

    private static let placeholderPill: NSImage = {
        let height = (sourceFont.capHeight + 7).rounded()
        let dotDiameter: CGFloat = 2.6
        let dotSpacing: CGFloat = 4
        let contentWidth = 2 * dotSpacing + dotDiameter
        let width = (contentWidth + 12).rounded()
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        let capsule = NSBezierPath(
            roundedRect: NSRect(x: 0.5, y: 0.5, width: width - 1, height: height - 1),
            xRadius: 4,
            yRadius: 4)
        NSColor(white: 0.5, alpha: 0.20).setFill()
        capsule.fill()
        NSColor(white: 0.42, alpha: 0.9).setFill()
        let centerY = height / 2
        let firstX = (width - contentWidth) / 2
        for index in 0..<3 {
            let centerX = firstX + CGFloat(index) * dotSpacing + dotDiameter / 2
            NSBezierPath(ovalIn: NSRect(
                x: centerX - dotDiameter / 2,
                y: centerY - dotDiameter / 2,
                width: dotDiameter,
                height: dotDiameter)).fill()
        }
        image.unlockFocus()
        return image
    }()

    /// Steps to the next or previous argument placeholder, selecting it so a keypress
    /// types over it. The placeholders shift and clear with edits through the
    /// storage delegate, so only unfilled ones remain to visit.
    private func selectArgumentPlaceholder(forward: Bool) -> Bool {
        let selection = selectedRange()
        let ordered = argumentPlaceholders.sorted { $0.location < $1.location }
        let target = forward
            ? ordered.first { $0.location >= NSMaxRange(selection) }
            : ordered.last { $0.location < selection.location }
        guard let range = target else { return false }
        setSelectedRange(range)
        scrollRangeToVisible(range)
        return true
    }

    func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters), !argumentPlaceholders.isEmpty else { return }
        let editStart = editedRange.location
        let editEnd = NSMaxRange(editedRange) - delta
        let userEdit = !isApplyingMarks
        argumentPlaceholders = argumentPlaceholders.compactMap { placeholder in
            if NSMaxRange(placeholder) <= editStart { return placeholder }
            if placeholder.location >= editEnd { return NSRange(location: placeholder.location + delta, length: placeholder.length) }
            return userEdit ? nil : NSRange(location: placeholder.location + delta, length: placeholder.length)
        }
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        guard let typed = string as? String else { return }
        if typed.count == 1, let unit = typed.utf16.first, unit == 41 || unit == 93 || unit == 125 {
            // Editing the storage now, mid-insert, does not take; it lands once
            // this input has finished.
            DispatchQueue.main.async { [weak self] in self?.dedentCloserLine() }
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
        guard shouldChangeText(in: leading, replacementString: openerIndent) else { return }

        storage.replaceCharacters(in: leading, with: NSAttributedString(string: openerIndent, attributes: sourceAttributes))
        didChangeText()
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
            case 41, 93, 125:
                if !openers.isEmpty { openers.removeLast() }
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
            case ")", "]", "}":
                if depth > 0 { depth -= 1 }
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
        if selectArgumentPlaceholder(forward: true) { return }
        guard selectedRange().length > 0 else { return super.insertText("\t", replacementRange: selectedRange()) }
        shiftSelectedLines(indenting: true)
    }

    override func insertBacktab(_ sender: Any?) {
        if selectArgumentPlaceholder(forward: false) { return }
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
    case errorDot(String)

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

/// The attachment only holds the line open for its mark: it draws nothing, and
/// the mark's view is placed over it as a real subview. NSTextView builds an
/// attachment's own view lazily, and only once it is first responder, so a
/// loaded snippet's marks would otherwise stay placeholders until a click.
nonisolated final class PharoMarkAttachment: NSTextAttachment, @unchecked Sendable {
    let content: PharoMarkContent
    let markView: NSView

    func resize(to size: CGRect) {
        bounds = size
        // An empty image of the wanted size holds the space and draws nothing; an
        // attachment with no contents would draw the placeholder document icon.
        image = NSImage(size: size.size)
    }

    init(content: PharoMarkContent, markView: NSView) {
        self.content = content
        self.markView = markView
        super.init(data: nil, ofType: nil)
        image = NSImage(size: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PharoMarkAttachment is not loaded from a nib")
    }
}

/// A body the reader opened. Its own line is held open to the body's height by
/// that line's paragraph style, and the body is drawn over that line as a real
/// subview -- the way the marks are -- so it fills the visible width while long
/// lines scroll under it. The attachment itself only anchors the line.
nonisolated final class PharoBodyAttachment: NSTextAttachment, @unchecked Sendable {
    let id: String
    let bodyView: NSView
    var height: CGFloat = 1

    init(id: String, bodyView: NSView) {
        self.id = id
        self.bodyView = bodyView
        super.init(data: nil, ofType: nil)
        image = NSImage(size: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PharoBodyAttachment is not loaded from a nib")
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

/// The larger red dot GT sets at the head of an expression that failed to run.
/// Its message opens on a click.
private struct PharoErrorDot: View {
    let message: String

    @State private var isPointedAt = false
    @State private var isShowingMessage = false

    var body: some View {
        Button(action: { isShowingMessage = true }) {
            Circle()
                .fill(isPointedAt ? Color.red.opacity(0.8) : Color.red)
                .frame(width: 11, height: 11)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { isPointedAt = $0 }
        .help(message)
        .popover(isPresented: $isShowingMessage) {
            Text(message)
                .font(.callout)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: 320)
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
        case (.errorDot(let a), .errorDot(let b)):
            a == b
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
        case .errorDot(let message):
            hasher.combine(7)
            hasher.combine(message)
        }
    }
}
#endif
