import Combine
import SwiftUI
import SwiftyPharo

#if canImport(AppKit)
    import AppKit

    typealias PharoTextViewBase = NSTextView
    typealias PharoStorageEditActions = NSTextStorageEditActions
#else
    import UIKit

    typealias PharoTextViewBase = UITextView
    typealias PharoStorageEditActions = NSTextStorage.EditActions
#endif

/// Marks and the bodies they open both live in the text as attachments, so the
/// source the reader edits is the text with those attachment characters -- and
/// the line separators that set a body on its own line -- taken back out.
final class PharoTextView: PharoTextViewBase, NSTextStorageDelegate {
    var completions: ((String, Int) async -> PharoCompletionList)?
    var classReferences: (String) async -> [PharoClassReference]? = { _ in [] }
    var methodReferences: (String) async -> [PharoMethodReference]? = { _ in [] }
    var undeclaredVariables: (String) async -> [PharoUndeclaredVariable]? = { _ in [] }
    var styleSpans: (String) async -> [PharoStyleSpan]? = { _ in [] }
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

    #if canImport(UIKit)
        private let candidates = PharoCompletionCandidates()
        private let completionBarHeight: CGFloat = 38

        /// A TextKit 2 text view leaves `textStorage` behind, so the stack is
        /// built here and its storage kept, which is what the marks are laid
        /// into.
        private let ownStorage = NSTextStorage()

        init() {
            let content = NSTextContentStorage()
            content.textStorage = ownStorage
            let layout = NSTextLayoutManager()
            content.addTextLayoutManager(layout)
            let container = NSTextContainer(
                size: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
            layout.textContainer = container
            super.init(frame: .zero, textContainer: container)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("PharoTextView is not loaded from a nib")
        }
    #endif

    var source: String {
        bareText(in: NSRange(location: 0, length: storageText.utf16.count))
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
        let units = Array(storageText.utf16)
        let kept = (range.location..<NSMaxRange(range)).filter { !carried.contains($0) }.map { units[$0] }
        return String(utf16CodeUnits: kept, count: kept.count)
    }

    /// The storage offsets the source does not count: every attachment, and the
    /// newline standing just before each body that sets it on its own line.
    private func carriedOffsets() -> Set<Int> {
        var carried: Set<Int> = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) {
            value, range, _ in
            guard value is NSTextAttachment else { return }
            carried.formUnion(range.location..<NSMaxRange(range))
            if value is PharoBodyAttachment {
                carried.insert(range.location - 1)
                carried.insert(NSMaxRange(range))
            }
        }
        return carried
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
    /// in: inserting it now would leave a mark the text view never builds a view
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
    #if canImport(AppKit)
        override func layout() {
            super.layout()
            positionMarkOverlays()
        }
    #else
        override func layoutSubviews() {
            super.layoutSubviews()
            positionMarkOverlays()
        }
    #endif

    /// Each mark keeps to the glyph its attachment holds; each body spreads over
    /// the whole line its own paragraph holds open, held at the visible left so
    /// long lines scroll under it rather than carrying it off the side.
    private func positionMarkOverlays() {
        guard let layout = textLayoutManager else { return }
        let origin = containerOrigin
        let pinnedX = visibleBounds.origin.x + sourceInset.width
        var presentMarks: Set<PharoMarkContent> = []
        var presentBodies: Set<String> = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) {
            value, range, _ in
            if let mark = value as? PharoMarkAttachment {
                presentMarks.insert(mark.content)
                guard let frame = markFrame(forStorage: range, in: layout) else { return }
                place(mark.markView, at: frame.offsetBy(dx: origin.x, dy: origin.y))
            } else if let body = value as? PharoBodyAttachment {
                presentBodies.insert(body.id)
                guard let frame = fragmentFrame(forStorage: range, in: layout) else { return }
                let line = frame.offsetBy(dx: origin.x, dy: origin.y)
                place(
                    body.bodyView,
                    at: CGRect(x: pinnedX, y: line.minY, width: bodyVisibleWidth, height: line.height))
            }
        }
        for (content, attachment) in attachments where !presentMarks.contains(content) {
            attachment.markView.removeFromSuperview()
        }
        for (id, attachment) in bodyAttachments where !presentBodies.contains(id) {
            attachment.bodyView.removeFromSuperview()
        }
    }

    /// A text view can draw its text in a subview of its own, adding it back on
    /// top as it lays out, so a mark laid over the text is raised on every pass
    /// rather than only when it is first put there.
    private func place(_ view: PlatformView, at frame: CGRect) {
        if view.superview !== self { addSubview(view) }
        view.frame = frame
        #if canImport(UIKit)
            bringSubviewToFront(view)
        #endif
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

    private func fragmentFrame(forStorage range: NSRange, in layout: NSTextLayoutManager) -> CGRect? {
        guard let content = layout.textContentManager,
            let location = content.location(content.documentRange.location, offsetBy: range.location)
        else { return nil }
        return layout.textLayoutFragment(for: location)?.layoutFragmentFrame
    }

    private var bodyVisibleWidth: CGFloat {
        max(visibleBounds.width - 2 * sourceInset.width, 80)
    }

    func noteEdited() {
        guard !isApplyingMarks else { return }
        onEdit?(source)
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
        scheduleFetch(of: source, after: 0.12)
    }

    private func fetchMarks(for source: String) {
        Task { @MainActor in
            let classes = await classReferences(source)
            let methods = await methodReferences(source)
            let undeclaredNames = await undeclaredVariables(source)
            let spans = await styleSpans(source)
            guard self.source == source else { return }
            // Reading a silence as an empty answer tears every mark out of the
            // text, and a mark put back where it was blanks the view it had.
            guard let classes, let methods, let undeclaredNames, let spans else {
                scheduleFetch(of: source, after: 0.5)
                return
            }
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

    private func scheduleFetch(of source: String, after delay: TimeInterval) {
        pendingMarkUp?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fetchMarks(for: source) }
        pendingMarkUp = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Paint the coloured runs GT would over the source, mapped past the mark
    /// characters, on a plain label-coloured ground. Each run's colour resolves
    /// the light or dark shade itself, so a theme flip redraws without another
    /// attribute pass -- which would relayout and unsettle the marks.
    private func applyStyle() {
        let whole = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: PlatformColor.platformLabel, range: whole)
        storage.addAttribute(.font, value: PharoSourceFont.regular, range: whole)
        for span in spans {
            let start = storageOffset(forSource: span.start - 1)
            let end = storageOffset(forSource: span.stop)
            guard end > start, end <= storage.length else { continue }
            let range = NSRange(location: start, length: end - start)
            if let color = PlatformColor.pharoRun(lightHex: span.light, darkHex: span.dark) {
                storage.addAttribute(.foregroundColor, value: color, range: range)
            }
            if span.bold {
                storage.addAttribute(.font, value: PharoSourceFont.bold, range: range)
            }
        }
        storage.endEditing()
    }

    /// Bring the marks in the text into line with the ones the snippet wants,
    /// touching only what differs. A mark that has not moved is left alone, so
    /// typing beside one disturbs neither it nor the cursor.
    private func reconcileMarks() {
        let wanted = wantedMarks()
        let present = presentMarks()
        let stale = present.filter { !wanted.contains($0.mark) }
        let missing = wanted.filter { mark in !present.contains { $0.mark == mark } }
        guard !stale.isEmpty || !missing.isEmpty else { return }

        isApplyingMarks = true
        let selection = sourceSelection
        // A selected placeholder is a token attachment, which the source does not
        // count, so mapping it through source offsets would collapse it; note it
        // and re-select it once its range has shifted with the marks instead.
        let selectedPlaceholder = argumentPlaceholders.firstIndex(of: selection)
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
        sourceSelection = NSRange(location: restoredStart, length: storageOffset(forSource: selectionEnd) - restoredStart)
        if let index = selectedPlaceholder, index < argumentPlaceholders.count {
            sourceSelection = argumentPlaceholders[index]
        }
        isApplyingMarks = false
        positionMarkOverlays()
    }

    /// One mark to a place: the image names a keyword send once per part of its
    /// selector, and laying a triangle down for each would stack them.
    private func wantedMarks() -> Set<PharoPlacedMark> {
        var wanted: Set<PharoPlacedMark> = []

        for reference in references {
            wanted.insert(PharoPlacedMark(sourceOffset: reference.stop, content: .classTriangle(reference.name)))
        }
        for reference in methodRefs {
            wanted.insert(PharoPlacedMark(sourceOffset: reference.stop, content: .methodTriangle(reference.id)))
        }
        for variable in undeclared {
            wanted.insert(PharoPlacedMark(sourceOffset: variable.stop, content: .undeclaredWrench(variable.id)))
        }
        if let error = marks.error {
            let offset = min(max((error.position ?? 1) - 1, 0), source.utf16.count)
            wanted.insert(PharoPlacedMark(sourceOffset: offset, content: .errorDot(error.message)))
        }
        wanted.insert(PharoPlacedMark(sourceOffset: source.utf16.count, content: .result))

        return wanted
    }

    private func presentMarks() -> [(mark: PharoPlacedMark, storageOffset: Int)] {
        var present: [(mark: PharoPlacedMark, storageOffset: Int)] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storageText.utf16.count)) {
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
        let capHeight = PharoSourceFont.regular.capHeight.rounded()
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

    private func markView(for content: PharoMarkContent) -> PlatformView {
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
        let wanted = openBodyItems()
        let present = presentBodyLocations()
        let stale = present.keys.filter { id in !wanted.contains { $0.item.id == id } }
        let missing = wanted.filter { present[$0.item.id] == nil }
        guard !stale.isEmpty || !missing.isEmpty else { return }

        isApplyingMarks = true
        let selectionStart = sourceOffset(ofStorage: sourceSelection.location)
        let selectionEnd = sourceOffset(ofStorage: NSMaxRange(sourceSelection))
        storage.beginEditing()
        for id in stale.sorted(by: { present[$0]! > present[$1]! }) {
            storage.deleteCharacters(in: NSRange(location: present[id]! - 1, length: 3))
            bodyAttachments[id] = nil
        }
        for entry in missing.sorted(by: { $0.markLocation > $1.markLocation }) {
            insertBody(entry.item, at: bodyStart(after: entry.markLocation))
        }
        storage.endEditing()
        let restoredStart = storageOffset(forSource: selectionStart)
        sourceSelection = NSRange(location: restoredStart, length: storageOffset(forSource: selectionEnd) - restoredStart)
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
    private func insertBody(_ item: PharoBodyItem, at location: Int) {
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
        let host = PlatformHostingView(rootView: bodyContent(for: item, id: id))
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

    private func measuredHeight(of host: PlatformHostingView) -> CGFloat {
        host.frame.size.width = bodyVisibleWidth
        return max(host.fittingHeight, 1)
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
        let units = Array(storageText.utf16)
        var at = markLocation + 1
        while at < units.count, units[at] == 0x20 || units[at] == 0x09 { at += 1 }
        return at
    }

    private func markLocation(of content: PharoMarkContent) -> Int? {
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
        guard !isApplyingMarks, !storage.isEqual(to: attributed) else { return }

        isApplyingMarks = true
        storage.setAttributedString(attributed)
        isApplyingMarks = false
    }

    private var sourceCursor: Int {
        sourceOffset(ofStorage: sourceSelection.location)
    }

    private func storageOffset(forSource cursor: Int) -> Int {
        let carried = carriedOffsets()
        let count = storageText.utf16.count
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

    private var sourceAttributes: [NSAttributedString.Key: Any] {
        [
            .font: PharoSourceFont.regular,
            .foregroundColor: PlatformColor.platformLabel,
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
    func skipMarksFromCaret(forward: Bool) {
        let selection = sourceSelection
        guard selection.length == 0 else { return }

        let carried = carriedOffsets()
        let count = storageText.utf16.count
        var caret = selection.location
        while caret > 0, caret <= count, carried.contains(caret - 1) {
            caret += forward ? 1 : -1
            guard caret >= 0, caret <= count else { break }
        }
        sourceSelection = NSRange(location: max(0, min(caret, count)), length: 0)
    }

    func askForCompletions() {
        let source = self.source
        let cursor = sourceCursor
        Task { @MainActor in
            guard let list = await completions?(source, cursor), self.source == source else { return }
            fetched = list
            offerCompletions(list)
        }
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

    /// The token the caret sits at the end of, computed afresh so it tracks each
    /// keystroke: once it is empty -- right after a colon -- there is nothing to
    /// complete, and the panel dismisses rather than offering a stale selector.
    var completionTokenRange: NSRange {
        let units = Array(storageText.utf16)
        let cursor = min(sourceSelection.location, units.count)
        var start = cursor
        while start > 0, isTokenUnit(units[start - 1]) { start -= 1 }
        return NSRange(location: start, length: cursor - start)
    }

    private func isTokenUnit(_ unit: UTF16.CodeUnit) -> Bool {
        (unit >= 48 && unit <= 57) || (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) || unit == 95
    }

    func insertKeywordTemplate(_ word: String, replacing: NSRange) {
        let (text, placeholders) = keywordTemplate(word)
        guard beginEdit(in: replacing, replacing: text.string) else { return }
        storage.replaceCharacters(in: replacing, with: text)
        finishEdit()
        argumentPlaceholders = placeholders.map { NSRange(location: replacing.location + $0.location, length: $0.length) }
        guard let first = argumentPlaceholders.first else { return }
        // The completion sets its own insertion point once this returns, so the
        // first placeholder is selected after that, not before.
        DispatchQueue.main.async { [weak self] in self?.sourceSelection = first }
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

    private func placeholderAttachment() -> NSTextAttachment {
        let attachment = NSTextAttachment()
        let pill = Self.placeholderPill
        attachment.image = pill
        attachment.bounds = CGRect(
            x: 0,
            y: (PharoSourceFont.regular.descender - 1).rounded(),
            width: pill.size.width,
            height: pill.size.height)
        return attachment
    }

    private static let placeholderPill: PlatformImage = {
        let height = (PharoSourceFont.regular.capHeight + 7).rounded()
        let dotDiameter: CGFloat = 2.6
        let dotSpacing: CGFloat = 4
        let contentWidth = 2 * dotSpacing + dotDiameter
        let width = (contentWidth + 12).rounded()
        return .pharoPlaceholderPill(
            size: CGSize(width: width, height: height),
            dotDiameter: dotDiameter,
            dotSpacing: dotSpacing)
    }()

    private func selectArgumentPlaceholder(forward: Bool) -> Bool {
        let selection = sourceSelection
        let ordered = argumentPlaceholders.sorted { $0.location < $1.location }
        let target = forward
            ? ordered.first { $0.location >= NSMaxRange(selection) }
            : ordered.last { $0.location < selection.location }
        guard let range = target else { return false }
        sourceSelection = range
        scrollRangeToVisible(range)
        return true
    }

    func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: PharoStorageEditActions,
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

    // MARK: - Platform Overrides

    #if canImport(AppKit)
        /// Copy and cut hand over the source alone, with the mark characters that
        /// hold the triangles and dots taken back out, so a paste elsewhere is the
        /// text the reader sees rather than that text peppered with placeholders.
        override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
            [.string]
        }

        override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
            pboard.setString(bareText(in: sourceSelection), forType: .string)
            return true
        }

        override func didChangeText() {
            super.didChangeText()
            noteEdited()
        }

        override func moveRight(_ sender: Any?) {
            super.moveRight(sender)
            skipMarksFromCaret(forward: true)
        }

        override func moveLeft(_ sender: Any?) {
            super.moveLeft(sender)
            skipMarksFromCaret(forward: false)
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
            askForCompletions()
        }

        /// The panel is the platform's own, so a fetched list only has to say
        /// there is something to show.
        private func offerCompletions(_ list: PharoCompletionList) {
            guard !list.candidates.isEmpty else { return }
            super.complete(nil)
        }

        override func completions(
            forPartialWordRange charRange: NSRange,
            indexOfSelectedItem index: UnsafeMutablePointer<Int>?
        ) -> [String]? {
            let noPreselection = -1
            index?.pointee = noPreselection
            return fetched?.candidates
        }

        override var rangeForUserCompletion: NSRange {
            completionTokenRange
        }

        override func insertCompletion(_ word: String, forPartialWordRange charRange: NSRange, movement: Int, isFinal: Bool) {
            guard isFinal, word.contains(":") else {
                return super.insertCompletion(word, forPartialWordRange: charRange, movement: movement, isFinal: isFinal)
            }
            // By the time the choice is final the panel has already previewed the
            // word into the text over the token; the template replaces that preview,
            // not the token, which would leave the preview's tail behind.
            let previewed = NSRange(location: charRange.location, length: (word as NSString).length)
            let replacing = NSMaxRange(previewed) <= (storageText as NSString).length
                && (storageText as NSString).substring(with: previewed) == word ? previewed : charRange
            insertKeywordTemplate(word, replacing: replacing)
        }

        // The find and browse keys are also the system's Find, Minimize and New;
        // catching them here, while this editor holds focus, keeps them from the
        // Edit, Window and File menus, and keeps each snippet finding within itself.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }

            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            switch (modifiers, event.charactersIgnoringModifiers?.lowercased()) {
            case (.command, "f"): find(.showFindInterface); return true
            case (.command, "e"): find(.setSearchString); return true
            // Command-G evaluates a snippet, so it steps through matches only while
            // the find bar is up, where that is the reading it has everywhere else.
            case (.command, "g") where isFindBarVisible: find(.nextMatch); return true
            case ([.command, .shift], "g") where isFindBarVisible: find(.previousMatch); return true
            case (.command, "m"): browse(.implementors); return true
            case (.command, "n"): browse(.senders); return true
            default: return super.performKeyEquivalent(with: event)
            }
        }

        private var isFindBarVisible: Bool {
            enclosingScrollView?.isFindBarVisible == true
        }

        /// The text finder takes its action from the sender's tag, the way the Find
        /// menu items carry theirs.
        private func find(_ action: NSTextFinder.Action) {
            let request = NSMenuItem()
            request.tag = action.rawValue
            performTextFinderAction(request)
        }

        override func insertText(_ string: Any, replacementRange: NSRange) {
            super.insertText(string, replacementRange: replacementRange)
            guard let typed = string as? String else { return }
            noteTyped(typed)
        }

        /// A new line follows the nesting, and opening a bracket and pressing Enter
        /// with its closer still ahead drops the closer to its own line at the
        /// outer indent.
        override func insertNewline(_ sender: Any?) {
            let (inner, base, splitsCloser) = newlineIndent()

            super.insertNewline(sender)
            if !inner.isEmpty {
                super.insertText(inner, replacementRange: sourceSelection)
            }
            guard splitsCloser else { return }
            let caretAfterInner = sourceSelection
            super.insertText("\n" + base, replacementRange: caretAfterInner)
            sourceSelection = caretAfterInner
        }

        /// Tab indents: it steps in every line a selection touches, and is a plain
        /// tab when nothing is selected. Shift-tab always steps a line back out.
        override func insertTab(_ sender: Any?) {
            if selectArgumentPlaceholder(forward: true) { return }
            guard sourceSelection.length > 0 else { return super.insertText("\t", replacementRange: sourceSelection) }
            shiftSelectedLines(indenting: true)
        }

        override func insertBacktab(_ sender: Any?) {
            if selectArgumentPlaceholder(forward: false) { return }
            shiftSelectedLines(indenting: false)
        }

        override func deleteBackward(_ sender: Any?) {
            guard let run = indentRunBeforeCaret(), beginEdit(in: run, replacing: "") else {
                return super.deleteBackward(sender)
            }
            storage.deleteCharacters(in: run)
            finishEdit()
        }
    #else
        /// The keyboard is where a completion can be offered without a pointer to
        /// point at it, so the candidates ride above it.
        private func offerCompletions(_ list: PharoCompletionList) {
            candidates.offer(list.candidates) { [weak self] word in
                self?.accept(completion: word)
            }
            guard inputAccessoryView == nil, !list.candidates.isEmpty else { return }
            let bar = PlatformHostingView(rootView: PharoCompletionStrip(candidates: candidates))
            bar.frame.size.height = completionBarHeight
            bar.autoresizingMask = .flexibleWidth
            inputAccessoryView = bar
            reloadInputViews()
        }

        private func accept(completion word: String) {
            let token = completionTokenRange
            guard word.contains(":") else {
                storage.replaceCharacters(
                    in: token,
                    with: NSAttributedString(string: word, attributes: sourceAttributes))
                finishEdit()
                sourceSelection = NSRange(location: token.location + (word as NSString).length, length: 0)
                return
            }
            insertKeywordTemplate(word, replacing: token)
        }

        override func copy(_ sender: Any?) {
            UIPasteboard.general.string = bareText(in: sourceSelection)
        }

        override func cut(_ sender: Any?) {
            let selection = sourceSelection
            UIPasteboard.general.string = bareText(in: selection)
            storage.deleteCharacters(in: selection)
            finishEdit()
        }

        /// Return and tab reach a text view as typed text, so what they mean to
        /// the source is decided here rather than in a command of their own.
        override func insertText(_ text: String) {
            switch text {
            case "\n": insertNewline()
            case "\t": insertTab()
            default:
                super.insertText(text)
                noteTyped(text)
            }
        }

        private func insertNewline() {
            let (inner, base, splitsCloser) = newlineIndent()

            super.insertText("\n" + inner)
            guard splitsCloser else { return }
            let caretAfterInner = sourceSelection
            super.insertText("\n" + base)
            sourceSelection = caretAfterInner
        }

        private func insertTab() {
            if selectArgumentPlaceholder(forward: true) { return }
            guard sourceSelection.length > 0 else { return super.insertText("\t") }
            shiftSelectedLines(indenting: true)
        }

        override func deleteBackward() {
            guard let run = indentRunBeforeCaret() else { return super.deleteBackward() }
            storage.deleteCharacters(in: run)
            finishEdit()
        }

        override var keyCommands: [UIKeyCommand]? {
            [
                UIKeyCommand(input: "f", modifierFlags: .command, action: #selector(showFind)),
                UIKeyCommand(input: "m", modifierFlags: .command, action: #selector(browseImplementors)),
                UIKeyCommand(input: "n", modifierFlags: .command, action: #selector(browseSenders)),
                UIKeyCommand(input: "\t", modifierFlags: .shift, action: #selector(outdent)),
            ]
        }

        @objc private func showFind() {
            findInteraction?.presentFindNavigator(showingReplace: false)
        }

        @objc private func browseImplementors() {
            browse(.implementors)
        }

        @objc private func browseSenders() {
            browse(.senders)
        }

        @objc private func outdent() {
            if selectArgumentPlaceholder(forward: false) { return }
            shiftSelectedLines(indenting: false)
        }
    #endif

    private func noteTyped(_ typed: String) {
        if typed.count == 1, let unit = typed.utf16.first, unit == 41 || unit == 93 || unit == 125 {
            // Editing the storage now, mid-insert, does not take; it lands once
            // this input has finished.
            DispatchQueue.main.async { [weak self] in self?.dedentCloserLine() }
        } else if typed.allSatisfy(\.isLetter) {
            askForCompletions()
        }
    }

    private func dedentCloserLine() {
        let text = storageText as NSString
        let closer = sourceSelection.location - 1
        guard closer >= 0 else { return }

        let line = text.lineRange(for: NSRange(location: closer, length: 0))
        let leading = NSRange(location: line.location, length: closer - line.location)
        let indent = text.substring(with: leading)
        guard indent.allSatisfy({ $0 == " " || $0 == "\t" }) else { return }
        guard let opener = matchingOpenerOffset(before: closer) else { return }

        let openerLine = text.lineRange(for: NSRange(location: opener, length: 0))
        let openerIndent = String(text.substring(with: openerLine).prefix { $0 == " " || $0 == "\t" })
        guard openerIndent != indent else { return }
        guard beginEdit(in: leading, replacing: openerIndent) else { return }

        storage.replaceCharacters(in: leading, with: NSAttributedString(string: openerIndent, attributes: sourceAttributes))
        finishEdit()
        sourceSelection = NSRange(location: line.location + (openerIndent as NSString).length + 1, length: 0)
    }

    /// The offset of the bracket that a closer at `closerOffset` matches, found
    /// by lexing forward with the same blindness to strings, comments and
    /// character literals as the indenter.
    private func matchingOpenerOffset(before closerOffset: Int) -> Int? {
        let units = Array(storageText.utf16)
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

    private func newlineIndent() -> (inner: String, base: String, splitsCloser: Bool) {
        let text = storageText as NSString
        let caret = sourceSelection.location
        let line = text.lineRange(for: NSRange(location: caret, length: 0))
        let toCaret = text.substring(with: NSRange(location: line.location, length: caret - line.location))
        let base = String(toCaret.prefix { $0 == " " || $0 == "\t" })
        let depth = openDepth(in: toCaret)
        let inner = depth > 0 ? base + String(repeating: "\t", count: depth) : base
        return (inner, base, depth > 0 && nextNonSpaceIsCloser(text, from: caret))
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

    /// Backspace in space indentation clears a whole level back to the previous
    /// tab stop, not one space; a real tab already deletes as one.
    private func indentRunBeforeCaret() -> NSRange? {
        let caret = sourceSelection
        guard caret.length == 0, caret.location > 0 else { return nil }

        let text = storageText as NSString
        let line = text.lineRange(for: NSRange(location: caret.location, length: 0))
        let lead = text.substring(with: NSRange(location: line.location, length: caret.location - line.location))
        guard !lead.isEmpty, lead.allSatisfy({ $0 == " " }) else { return nil }

        let width = 4
        let column = caret.location - line.location
        let count = column - (column - 1) / width * width
        return NSRange(location: caret.location - count, length: count)
    }

    /// Editing the line starts rather than rewriting the lines leaves any marks
    /// they carry in place.
    private func shiftSelectedLines(indenting: Bool) {
        let text = storageText as NSString
        let block = text.lineRange(for: sourceSelection)
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
        finishEdit()
        sourceSelection = NSRange(location: block.location, length: max(0, block.length + delta))
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
        return layout.usageBoundsForTextContainer.height + 2 * sourceInset.height
    }

    // MARK: - Platform Text Access

    /// Whether an edit may go ahead, which on a platform that registers undo for
    /// the text view is its to say.
    private func beginEdit(in range: NSRange, replacing text: String) -> Bool {
        #if canImport(AppKit)
            return shouldChangeText(in: range, replacementString: text)
        #else
            return true
        #endif
    }

    private func finishEdit() {
        #if canImport(AppKit)
            didChangeText()
        #else
            noteEdited()
        #endif
    }

    var storage: NSTextStorage {
        #if canImport(AppKit)
            return textStorage!
        #else
            return ownStorage
        #endif
    }

    private var storageText: String {
        #if canImport(AppKit)
            return string
        #else
            return text
        #endif
    }

    var sourceSelection: NSRange {
        get {
            #if canImport(AppKit)
                return selectedRange()
            #else
                return selectedRange
            #endif
        }
        set {
            #if canImport(AppKit)
                setSelectedRange(newValue)
            #else
                selectedRange = newValue
            #endif
        }
    }

    var sourceInset: CGSize {
        get {
            #if canImport(AppKit)
                return textContainerInset
            #else
                return CGSize(width: textContainerInset.left, height: textContainerInset.top)
            #endif
        }
        set {
            #if canImport(AppKit)
                textContainerInset = newValue
            #else
                textContainerInset = UIEdgeInsets(
                    top: newValue.height,
                    left: newValue.width,
                    bottom: newValue.height,
                    right: newValue.width)
            #endif
        }
    }

    private var containerOrigin: CGPoint {
        #if canImport(AppKit)
            return textContainerOrigin
        #else
            return CGPoint(x: sourceInset.width, y: sourceInset.height)
        #endif
    }

    /// What of the text is on screen, which is the scroller's window onto it
    /// where the text view is inside one and the text view itself where it is
    /// the scroller.
    private var visibleBounds: CGRect {
        #if canImport(AppKit)
            return enclosingScrollView?.contentView.bounds ?? bounds
        #else
            return CGRect(origin: contentOffset, size: bounds.size)
        #endif
    }
}

extension PlatformImage {
    static func pharoPlaceholderPill(size: CGSize, dotDiameter: CGFloat, dotSpacing: CGFloat) -> PlatformImage {
        let contentWidth = 2 * dotSpacing + dotDiameter
        let firstX = (size.width - contentWidth) / 2
        let centerY = size.height / 2
        let capsule = CGRect(x: 0.5, y: 0.5, width: size.width - 1, height: size.height - 1)

        func dot(_ index: Int) -> CGRect {
            let centerX = firstX + CGFloat(index) * dotSpacing + dotDiameter / 2
            return CGRect(
                x: centerX - dotDiameter / 2,
                y: centerY - dotDiameter / 2,
                width: dotDiameter,
                height: dotDiameter)
        }

        #if canImport(AppKit)
            let image = NSImage(size: size)
            image.lockFocus()
            NSColor(white: 0.5, alpha: 0.20).setFill()
            NSBezierPath(roundedRect: capsule, xRadius: 4, yRadius: 4).fill()
            NSColor(white: 0.42, alpha: 0.9).setFill()
            for index in 0..<3 {
                NSBezierPath(ovalIn: dot(index)).fill()
            }
            image.unlockFocus()
            return image
        #else
            return UIGraphicsImageRenderer(size: size).image { _ in
                UIColor(white: 0.5, alpha: 0.20).setFill()
                UIBezierPath(roundedRect: capsule, cornerRadius: 4).fill()
                UIColor(white: 0.42, alpha: 0.9).setFill()
                for index in 0..<3 {
                    UIBezierPath(ovalIn: dot(index)).fill()
                }
            }
        #endif
    }
}

#if canImport(UIKit)
    @Observable
    final class PharoCompletionCandidates {
        private(set) var words: [String] = []
        @ObservationIgnored private var accept: (String) -> Void = { _ in }

        func offer(_ words: [String], accept: @escaping (String) -> Void) {
            self.words = words
            self.accept = accept
        }

        func take(_ word: String) {
            accept(word)
        }
    }

    struct PharoCompletionStrip: View {
        let candidates: PharoCompletionCandidates

        var body: some View {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(candidates.words, id: \.self) { word in
                        Button(word) { candidates.take(word) }
                            .font(.system(.footnote, design: .monospaced))
                            .buttonStyle(.bordered)
                    }
                }
                .padding(.horizontal, 8)
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: .infinity)
            .background(.bar)
        }
    }
#endif
