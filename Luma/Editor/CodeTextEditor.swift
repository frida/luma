import LumaCore
import SwiftUI

#if canImport(AppKit)
    import AppKit
#else
    import UIKit
#endif

struct CodeTextEditor: PlatformViewRepresentable {
    @Binding var text: String
    let profile: EditorProfile
    let introspector: CodeIntrospector?
    let focused: Binding<Bool>?
    var reveal: EditorReveal? = nil
    let engine: Engine

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    #if canImport(AppKit)
        func makeNSView(context: Context) -> NSScrollView {
            let view = makeTextView(context: context)
            view.allowsUndo = true
            view.usesFindBar = true
            view.isIncrementalSearchingEnabled = true
            view.isRichText = false
            view.isAutomaticQuoteSubstitutionEnabled = false
            view.isAutomaticTextReplacementEnabled = false
            view.isAutomaticDashSubstitutionEnabled = false
            view.isAutomaticSpellingCorrectionEnabled = false
            view.isContinuousSpellCheckingEnabled = false
            view.isHorizontallyResizable = true
            view.isVerticallyResizable = true
            view.autoresizingMask = [.width]
            view.minSize = .zero
            view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            view.textContainer?.widthTracksTextView = false
            view.textContainer?.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            view.textContainerInset = NSSize(width: 0, height: 8)
            view.textContainer?.lineFragmentPadding = 0

            let scroll = NSScrollView()
            scroll.documentView = view
            scroll.hasHorizontalScroller = true
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.borderType = .noBorder
            let gutter = CodeGutterView(scrollView: scroll, textView: view)
            gutter.onToggleFold = { [weak view] line in view?.toggleFold(atLine: line) }
            view.onLineStateChanged = { [weak gutter] in gutter?.refresh() }
            scroll.hasVerticalRuler = true
            scroll.verticalRulerView = gutter
            scroll.rulersVisible = true
            gutter.refresh()
            return scroll
        }

        func updateNSView(_ scroll: NSScrollView, context: Context) {
            update(scroll.documentView as! CodeTextView, context: context)
        }
    #else
        func makeUIView(context: Context) -> CodeTextView {
            let view = makeTextView(context: context)
            view.autocorrectionType = .no
            view.autocapitalizationType = .none
            view.smartQuotesType = .no
            view.smartDashesType = .no
            view.smartInsertDeleteType = .no
            view.spellCheckingType = .no
            view.isScrollEnabled = true
            view.textContainer.widthTracksTextView = false
            view.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
            return view
        }

        func updateUIView(_ view: CodeTextView, context: Context) {
            update(view, context: context)
        }
    #endif

    private func makeTextView(context: Context) -> CodeTextView {
        let view = CodeTextView.make()
        view.delegate = context.coordinator
        view.setSource(text)
        context.coordinator.attach(view)
        return view
    }

    private func update(_ view: CodeTextView, context: Context) {
        context.coordinator.parent = self
        view.onEdit = { text = $0 }
        view.onFocused = { focused?.wrappedValue = true }
        view.isEditable = !profile.readOnly
        view.syntax = profile.syntax
        if view.source != text {
            view.setSource(text)
        }
        context.coordinator.reconcileSession(profile: profile, engine: engine)
        context.coordinator.reconcileFocus(view: view)
        context.coordinator.reconcileReveal(view: view, reveal: reveal)
    }

    @MainActor
    final class Coordinator: NSObject, CodeTextViewDelegate {
        var parent: CodeTextEditor
        private weak var view: CodeTextView?
        private var session: TypeScriptEditorSession?
        private var sessionProfile: EditorProfile?
        private var sessionGeneration = 0
        private var appliedFocus = false
        private let textUndoManager = UndoManager()

        init(_ parent: CodeTextEditor) {
            self.parent = parent
        }

        func attach(_ view: CodeTextView) {
            self.view = view
        }

        func reconcileSession(profile: EditorProfile, engine: Engine) {
            guard sessionProfile.map({ TypeScriptEditorSession.isSameProject($0, profile) }) != true else { return }
            sessionProfile = profile
            sessionGeneration += 1
            let generation = sessionGeneration
            let previous = session
            session = nil
            view?.session = nil
            parent.introspector?.document = nil
            if let previous {
                previous.close()
            }
            let text = view?.source ?? parent.text
            Task { @MainActor in
                guard let session = try? await TypeScriptEditorSession.open(engine: engine, profile: profile, text: text),
                    generation == sessionGeneration
                else { return }
                self.session = session
                view?.session = session
                parent.introspector?.document = session.document
            }
        }

        private var appliedReveal: EditorReveal?

        func reconcileReveal(view: CodeTextView, reveal: EditorReveal?) {
            guard let reveal, reveal != appliedReveal else { return }
            appliedReveal = reveal
            #if canImport(AppKit)
                DispatchQueue.main.async { view.reveal(reveal.range) }
            #endif
        }

        func reconcileFocus(view: CodeTextView) {
            guard let focused = parent.focused else { return }
            guard focused.wrappedValue else {
                appliedFocus = false
                return
            }
            guard !appliedFocus else { return }
            appliedFocus = true
            DispatchQueue.main.async {
                #if canImport(AppKit)
                    view.window?.makeFirstResponder(view)
                #else
                    _ = view.becomeFirstResponder()
                #endif
            }
        }

        #if canImport(AppKit)
            func undoManager(for view: NSTextView) -> UndoManager? {
                textUndoManager
            }
        #else
            func textViewDidChange(_ view: UITextView) {
                (view as? CodeTextView)?.noteEdited()
            }
        #endif
    }
}

struct EditorReveal: Equatable {
    let range: LSP.Range
    let generation: Int
}

#if canImport(AppKit)
    typealias CodeTextViewDelegate = NSTextViewDelegate
#else
    typealias CodeTextViewDelegate = UITextViewDelegate
#endif
