import AppKit
import SwiftUI
import SwiftyPharo

/// A multi-line Smalltalk editor that grows with its text and completes from
/// the image. AppKit rather than `TextField` because completion over several
/// lines is `NSTextView`'s job, and the suggestions API `REPLView` uses is
/// single-line only.
struct PharoSourceEditor: NSViewRepresentable {
    let id: UUID
    @Binding var source: String
    @Binding var focused: UUID?
    let runtime: PharoRuntime
    let expanded: Set<String>
    let onToggle: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> PharoTextView {
        let view = PharoTextView()
        view.delegate = context.coordinator
        view.completions = runtime.completionList
        view.classReferences = runtime.namedClasses(in:)
        view.onToggle = onToggle
        view.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        view.isRichText = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 4, height: 6)
        view.string = source
        return view
    }

    func updateNSView(_ view: PharoTextView, context: Context) {
        context.coordinator.parent = self
        view.onToggle = onToggle
        if view.string != source {
            view.string = source
        }
        view.expanded = expanded
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
            guard let view = notification.object as? NSTextView else { return }
            parent.source = view.string
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
    /// A page that cannot reach the image simply does not complete.
    func completionList(for source: String, at position: Int) async -> PharoCompletionList {
        guard let answer = try? await completions(for: source, at: position) else { return .none }
        return PharoCompletionList(tokenStart: answer.tokenStart, candidates: answer.completions)
    }

    /// Nor does a page that cannot reach the image name any classes.
    func namedClasses(in source: String) async -> [PharoClassReference] {
        (try? await classReferences(in: source)) ?? []
    }
}

/// Completion in `NSTextView` is answered synchronously, but the image is a
/// round trip away, so a request fetches first and then re-enters completion
/// with what it got.
final class PharoTextView: NSTextView {
    var completions: ((String, Int) async -> PharoCompletionList)?
    var classReferences: ((String) async -> [PharoClassReference])?
    var onToggle: ((String) -> Void)?

    var expanded: Set<String> = [] {
        didSet { adornments.forEach { $0.showsExpanded = expanded.contains($0.openedClass) } }
    }

    private var fetched: PharoCompletionList?
    private var adornments: [PharoClassAdornment] = []
    private var adornedSource: String?

    override func complete(_ sender: Any?) {
        if let fetched {
            self.fetched = nil
            guard !fetched.candidates.isEmpty else { return }
            return super.complete(sender)
        }

        let source = string
        let cursor = selectedRange().location
        Task { @MainActor in
            guard let list = await completions?(source, cursor), string == source else { return }
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

    /// A triangle sits after every class the snippet names, the way GT's class
    /// expander marks them. They are subviews rather than text attachments so
    /// that marking the source never rewrites it.
    func refreshAdornments() {
        guard adornedSource != string else { return placeAdornments() }

        let source = string
        adornedSource = source
        Task { @MainActor in
            guard let found = await classReferences?(source), string == source else { return }
            rebuildAdornments(for: found)
        }
    }

    private func rebuildAdornments(for references: [PharoClassReference]) {
        adornments.forEach { $0.removeFromSuperview() }
        adornments = references.map { reference in
            let adornment = PharoClassAdornment(openedClass: reference.name, after: reference.stop)
            adornment.showsExpanded = expanded.contains(reference.name)
            adornment.target = self
            adornment.action = #selector(toggleAdornment(_:))
            addSubview(adornment)
            return adornment
        }
        placeAdornments()
    }

    private func placeAdornments() {
        guard let container = textContainer, let manager = layoutManager else { return }
        for adornment in adornments {
            let last = NSRange(location: adornment.sourceStop - 1, length: 1)
            guard NSMaxRange(last) <= string.utf16.count else { continue }
            let glyphs = manager.glyphRange(forCharacterRange: last, actualCharacterRange: nil)
            let box = manager.boundingRect(forGlyphRange: glyphs, in: container)
            adornment.setFrameOrigin(NSPoint(
                x: box.maxX + textContainerInset.width + 1,
                y: box.midY + textContainerInset.height - adornment.frame.height / 2))
        }
    }

    @objc private func toggleAdornment(_ sender: PharoClassAdornment) {
        onToggle?(sender.openedClass)
    }

    override func layout() {
        super.layout()
        placeAdornments()
    }

    override func didChangeText() {
        super.didChangeText()
        refreshAdornments()
    }

    func height(fitting width: CGFloat) -> CGFloat {
        guard let container = textContainer, let manager = layoutManager else { return 0 }
        container.containerSize = NSSize(width: width - 2 * textContainerInset.width, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        return manager.usedRect(for: container).height + 2 * textContainerInset.height
    }
}

/// The triangle itself, remembering which class it stands for and where in the
/// source it belongs so the editor can place it again after every relayout.
final class PharoClassAdornment: NSButton {
    let openedClass: String
    let sourceStop: Int

    var showsExpanded = false {
        didSet { image = NSImage(systemSymbolName: symbolName, accessibilityDescription: openedClass) }
    }

    init(openedClass: String, after stop: Int) {
        self.openedClass = openedClass
        self.sourceStop = stop
        super.init(frame: NSRect(x: 0, y: 0, width: 12, height: 12))
        isBordered = false
        imagePosition = .imageOnly
        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: openedClass)
        contentTintColor = .tertiaryLabelColor
        toolTip = openedClass
    }

    private var symbolName: String {
        showsExpanded ? "chevron.down.circle" : "chevron.right.circle"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PharoClassAdornment is not loaded from a nib")
    }
}
