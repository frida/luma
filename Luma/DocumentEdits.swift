import SwiftUI

#if canImport(AppKit)
    import AppKit

    @MainActor
    final class DocumentEdits {
        fileprivate weak var window: NSWindow?

        private var holdsUnwrittenRecords = false
        private var pendingRecordWrite: Task<Void, Never>?

        private static let live = NSHashTable<DocumentEdits>.weakObjects()
        private static let recordWriteInterval: Duration = .seconds(30)

        static func writeRecordsOfAll() async {
            for edits in live.allObjects {
                await edits.writeRecords()
            }
        }

        init() {
            Self.live.add(self)
        }

        func markEdited() {
            document?.updateChangeCount(.changeDone)
        }

        func noteRecorded() {
            holdsUnwrittenRecords = true
            guard pendingRecordWrite == nil else { return }
            pendingRecordWrite = Task { [weak self] in
                try? await Task.sleep(for: Self.recordWriteInterval)
                guard !Task.isCancelled else { return }
                await self?.writeRecords()
            }
        }

        fileprivate func windowWillClose() {
            Task { await writeRecords() }
        }

        private func writeRecords() async {
            pendingRecordWrite?.cancel()
            pendingRecordWrite = nil
            guard holdsUnwrittenRecords, let document, !document.isDocumentEdited,
                let fileURL = document.fileURL, let fileType = document.fileType
            else { return }
            holdsUnwrittenRecords = false
            let error: (any Error)? = await withCheckedContinuation { written in
                document.save(to: fileURL, ofType: fileType, for: .autosaveInPlaceOperation) { written.resume(returning: $0) }
            }
            if error != nil {
                holdsUnwrittenRecords = true
            }
        }

        private var document: NSDocument? {
            window.flatMap { NSDocumentController.shared.document(for: $0) }
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

        private var closeObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            edits?.window = window
            observeClose(of: window)
        }

        private func observeClose(of window: NSWindow?) {
            closeObserver.map(NotificationCenter.default.removeObserver)
            closeObserver = window.map { window in
                NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) {
                    [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.edits?.windowWillClose()
                    }
                }
            }
        }
    }
#endif
