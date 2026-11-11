import LumaCore
import SwiftUI

#if canImport(AppKit)
import AppKit

struct VirtualMachineLog: NSViewRepresentable {
    let console: VirtualMachineConsole
    let isShown: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.textContainerInset = NSSize(width: 4, height: 6)
        scrollView.borderType = .noBorder
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.catchUp(with: console, in: scrollView)
        context.coordinator.reveal(isShown, in: scrollView)
    }

    @MainActor
    final class Coordinator {
        private var shownConsole: VirtualMachineConsole?
        private var shownFirstLineNumber = 0
        private var shownEndLineNumber = 0
        private var wasShown = false

        func catchUp(with console: VirtualMachineConsole, in scrollView: NSScrollView) {
            let textView = scrollView.documentView as! NSTextView
            let storage = textView.textStorage!
            if console !== shownConsole {
                shownConsole = console
                shownFirstLineNumber = 0
                shownEndLineNumber = 0
                storage.setAttributedString(NSAttributedString())
            }

            let followsBottom = isScrolledToBottom(scrollView)
            removeLinesTheConsoleDropped(from: storage, console: console)
            appendLinesNotYetShown(to: storage, console: console)
            if followsBottom {
                textView.scrollToEndOfDocument(nil)
            }
        }

        func reveal(_ isShown: Bool, in scrollView: NSScrollView) {
            if isShown, !wasShown {
                scrollView.documentView?.scrollToEndOfDocument(nil)
            }
            wasShown = isShown
        }

        private func isScrolledToBottom(_ scrollView: NSScrollView) -> Bool {
            let visible = scrollView.contentView.bounds
            let documentHeight = scrollView.documentView?.frame.height ?? 0
            return visible.maxY >= documentHeight - Self.bottomThreshold
        }

        private func removeLinesTheConsoleDropped(from storage: NSTextStorage, console: VirtualMachineConsole) {
            let droppedCount = min(console.firstLineNumber, shownEndLineNumber) - shownFirstLineNumber
            if droppedCount > 0 {
                let text = storage.string as NSString
                var droppedLength = 0
                for _ in 0..<droppedCount {
                    droppedLength = NSMaxRange(text.lineRange(for: NSRange(location: droppedLength, length: 0)))
                }
                storage.deleteCharacters(in: NSRange(location: 0, length: droppedLength))
            }
            shownFirstLineNumber = console.firstLineNumber
            shownEndLineNumber = max(shownEndLineNumber, shownFirstLineNumber)
        }

        private func appendLinesNotYetShown(to storage: NSTextStorage, console: VirtualMachineConsole) {
            let fresh = NSMutableAttributedString()
            for line in console.lines(from: shownEndLineNumber) {
                let color: NSColor = line.isAlarming ? .systemRed : .labelColor
                fresh.append(NSAttributedString(string: line.text + "\n", attributes: [.font: Self.font, .foregroundColor: color]))
            }
            storage.append(fresh)
            shownEndLineNumber = console.endLineNumber
        }

        private static let font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        private static let bottomThreshold: CGFloat = 8
    }
}

#endif
