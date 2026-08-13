import Combine
import SwiftUI
import SwiftyPharo

#if canImport(AppKit)
    import AppKit
#else
    import UIKit
#endif

/// An error a snippet raised, with where in its source the image placed it --
/// 1-based, or nothing for a runtime error -- so the dot marks the spot.
struct PharoEvaluationError: Equatable {
    let message: String
    let position: Int?
}

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

/// The text itself: a text view whose container never wraps, so long lines run
/// off the side, with the inline mark triangles as attachments. AppKit puts the
/// text view inside a scroll view; UIKit's text view is already one.
struct PharoTextEditor: PlatformViewRepresentable {
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

    #if canImport(AppKit)
        func makeNSView(context: Context) -> PharoEditorScrollView {
            let view = makeTextView(context: context)
            view.allowsUndo = true
            view.usesFindBar = true
            view.isIncrementalSearchingEnabled = true
            view.isRichText = false
            view.isAutomaticQuoteSubstitutionEnabled = false
            view.isAutomaticTextReplacementEnabled = false
            view.drawsBackground = false
            view.isHorizontallyResizable = true
            view.isVerticallyResizable = true
            view.minSize = .zero
            view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            view.textContainer?.widthTracksTextView = false
            view.textContainer?.size = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude)

            let scroll = PharoEditorScrollView()
            scroll.documentView = view
            scroll.drawsBackground = false
            scroll.hasHorizontalScroller = true
            scroll.hasVerticalScroller = false
            scroll.verticalScrollElasticity = .none
            scroll.autohidesScrollers = true
            scroll.onFindBarVisibilityChanged = { metrics.revision += 1 }
            return scroll
        }

        func updateNSView(_ scroll: PharoEditorScrollView, context: Context) {
            update(scroll.documentView as! PharoTextView, context: context)
        }

        func sizeThatFits(
            _ proposal: ProposedViewSize,
            nsView scroll: PharoEditorScrollView,
            context: Context
        ) -> CGSize? {
            guard let width = proposal.width, let view = scroll.documentView as? PharoTextView else { return nil }
            return CGSize(width: width, height: view.height() + scroll.findBarHeight)
        }
    #else
        func makeUIView(context: Context) -> PharoTextView {
            let view = makeTextView(context: context)
            view.backgroundColor = .clear
            view.isFindInteractionEnabled = true
            view.autocorrectionType = .no
            view.autocapitalizationType = .none
            view.smartQuotesType = .no
            view.smartDashesType = .no
            view.smartInsertDeleteType = .no
            view.spellCheckingType = .no
            view.alwaysBounceVertical = false
            view.showsVerticalScrollIndicator = false
            view.isScrollEnabled = true
            view.textContainer.widthTracksTextView = false
            return view
        }

        func updateUIView(_ view: PharoTextView, context: Context) {
            update(view, context: context)
        }

        func sizeThatFits(_ proposal: ProposedViewSize, uiView view: PharoTextView, context: Context) -> CGSize? {
            guard let width = proposal.width else { return nil }
            return CGSize(width: width, height: view.height())
        }
    #endif

    private func makeTextView(context: Context) -> PharoTextView {
        #if canImport(AppKit)
            let view = PharoTextView(usingTextLayoutManager: true)
        #else
            let view = PharoTextView()
        #endif
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
        view.font = PharoSourceFont.regular
        view.sourceInset = CGSize(width: 4, height: 6)
        view.storage.delegate = view
        view.apply(runtime: runtime, marks: marks, onToggleClass: onToggleClass, onOpen: onOpen, onOpenResult: onOpenResult)
        view.setSource(source)
        return view
    }

    private func update(_ view: PharoTextView, context: Context) {
        context.coordinator.parent = self
        view.onFocused = { if focused != id { focused = id } }
        view.onEdit = { source = $0 }
        view.apply(runtime: runtime, marks: marks, onToggleClass: onToggleClass, onOpen: onOpen, onOpenResult: onOpenResult)
        if view.source != source {
            view.setSource(source)
        }
        context.coordinator.reconcileFocus(id: id, focused: focused, view: view)
    }

    final class Coordinator: NSObject, PharoTextViewDelegate {
        var parent: PharoTextEditor
        private var appliedFocused: UUID?
        private let textUndoManager = UndoManager()

        init(_ parent: PharoTextEditor) {
            self.parent = parent
        }

        #if canImport(AppKit)
            // Each editor undoes its own edits rather than sharing the window's
            // manager, where a snippet's undo could reach into another's.
            func undoManager(for view: NSTextView) -> UndoManager? {
                textUndoManager
            }
        #else
            func textViewDidChange(_ view: UITextView) {
                (view as? PharoTextView)?.noteEdited()
            }

            /// A tap can land the caret inside a mark, which the source does not
            /// count, so it is nudged clear of one the way an arrow key would be.
            func textViewDidChangeSelection(_ view: UITextView) {
                (view as? PharoTextView)?.skipMarksFromCaret(forward: true)
            }
        #endif

        /// Takes first responder only as focus arrives, not on every update: a
        /// body opened below the editor is a separate responder, and reclaiming
        /// focus each pass would snatch it back from there mid-edit.
        func reconcileFocus(id: UUID, focused: UUID?, view: PharoTextView) {
            guard focused == id else { appliedFocused = nil; return }
            guard appliedFocused != id else { return }
            appliedFocused = id
            guard !view.holdsFocus else { return }
            DispatchQueue.main.async {
                guard !view.holdsFocus else { return }
                view.takeFocus()
            }
        }
    }
}

#if canImport(AppKit)
    typealias PharoTextViewDelegate = NSTextViewDelegate
#else
    typealias PharoTextViewDelegate = UITextViewDelegate
#endif

extension PharoTextView {
    var holdsFocus: Bool {
        #if canImport(AppKit)
            return window?.firstResponder === self
        #else
            return isFirstResponder
        #endif
    }

    func takeFocus() {
        #if canImport(AppKit)
            window?.makeFirstResponder(self)
        #else
            _ = becomeFirstResponder()
        #endif
    }
}

#if canImport(AppKit)
    /// The find bar rides at the top of the scroll view, taking its height out of
    /// what the text is given. A snippet is sized to its text rather than the other
    /// way about, so the bar's height is added to the snippet instead: showing one
    /// grows the card rather than clipping the last line of code.
    final class PharoEditorScrollView: NSScrollView {
        var onFindBarVisibilityChanged: (() -> Void)?

        override var isFindBarVisible: Bool {
            didSet {
                guard isFindBarVisible != oldValue else { return }
                onFindBarVisibilityChanged?()
            }
        }

        var findBarHeight: CGFloat {
            guard isFindBarVisible, let bar = findBarView else { return 0 }
            return bar.fittingSize.height
        }
    }
#endif

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

    /// What the image reads in the source, or nothing at all when it could not
    /// be reached -- which is not the same answer as an empty one, and the
    /// editor keeps what it has rather than taking a silence for a reading.
    func namedClasses(in source: String) async -> [PharoClassReference]? {
        try? await whenRunning { try await classReferences(in: source) }
    }

    func methods(in source: String, selfClass: String?) async -> [PharoMethodReference]? {
        try? await whenRunning { try await methodReferences(in: source, selfClass: selfClass) }
    }

    func undeclared(in source: String) async -> [PharoUndeclaredVariable]? {
        try? await whenRunning { try await undeclaredVariables(in: source) }
    }

    func styles(in source: String, isMethod: Bool) async -> [PharoStyleSpan]? {
        try? await whenRunning { try await styleSpans(in: source, isMethod: isMethod) }
    }

    private func whenRunning<Answer>(_ request: () async throws -> Answer) async throws -> Answer {
        try await runningState()
        return try await request()
    }
}
