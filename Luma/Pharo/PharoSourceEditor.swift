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
    let completions: (String, Int) async -> PharoCompletionList

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> PharoTextView {
        let view = PharoTextView()
        view.delegate = context.coordinator
        view.completions = completions
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
        view.completions = completions
        if view.string != source {
            view.string = source
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
}

/// Completion in `NSTextView` is answered synchronously, but the image is a
/// round trip away, so a request fetches first and then re-enters completion
/// with what it got.
final class PharoTextView: NSTextView {
    var completions: ((String, Int) async -> PharoCompletionList)?

    private var fetched: PharoCompletionList?

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

    func height(fitting width: CGFloat) -> CGFloat {
        guard let container = textContainer, let manager = layoutManager else { return 0 }
        container.containerSize = NSSize(width: width - 2 * textContainerInset.width, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        return manager.usedRect(for: container).height + 2 * textContainerInset.height
    }
}
