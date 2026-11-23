import SwiftUI

#if canImport(AppKit)
    import AppKit

    @MainActor
    final class DocumentEdits {
        fileprivate weak var window: NSWindow?

        func markEdited() {
            guard let window, let document = NSDocumentController.shared.document(for: window) else { return }
            document.updateChangeCount(.changeDone)
        }
    }

    struct DocumentWindowReader: NSViewRepresentable {
        let edits: DocumentEdits

        func makeNSView(context: Context) -> NSView {
            let view = WindowReportingView()
            view.edits = edits
            return view
        }

        func updateNSView(_ nsView: NSView, context: Context) {}
    }

    private final class WindowReportingView: NSView {
        weak var edits: DocumentEdits?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            edits?.window = window
        }
    }
#endif
