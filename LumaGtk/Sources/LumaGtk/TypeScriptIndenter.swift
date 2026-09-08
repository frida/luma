import CGtk
import Foundation
import Gdk
import GtkSource
import Gtk
import LumaCore

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
@MainActor
final class TypeScriptIndenter: IndenterImplementation {
    private let buffer: GtkSource.Buffer

    init(buffer: GtkSource.Buffer) {
        self.buffer = buffer
        super.init()
    }

    override func isTrigger(view: UnsafeMutablePointer<GtkSourceView>?, location: UnsafePointer<GtkTextIter>?, state: GdkModifierType, keyval: guint) -> gboolean {
        switch Int32(keyval) {
        case Gdk.keyReturn, Gdk.keyKPEnter, Gdk.keyISOEnter,
             Gdk.keybraceright, Gdk.keyparenright, Gdk.keybracketright:
            return 1
        default:
            return 0
        }
    }

    override func indent(view: UnsafeMutablePointer<GtkSourceView>?, iter: UnsafeMutablePointer<GtkTextIter>?) {
        guard let iter else { return }
        let text = buffer.text
        let offsets = CharacterOffsets(text: text)
        let caretUTF16 = offsets.utf16Offset(ofCharacter: Int(TextIter(iter).offset))
        guard SourceIndentation.isReindentTrigger(in: text, atUTF16: caretUTF16) else { return }
        let plan = SourceIndentation.reindent(in: text, atUTF16: caretUTF16)

        let startChar = offsets.characterOffset(ofUTF16: plan.range.lowerBound)
        let endChar = offsets.characterOffset(ofUTF16: plan.range.upperBound)
        if startChar != endChar {
            withIters { first, second in
                buffer.getIterAtOffset(iter: first, charOffset: startChar)
                buffer.getIterAtOffset(iter: second, charOffset: endChar)
                buffer.delete(start: first, end: second)
            }
        }
        if !plan.replacement.isEmpty {
            placeCursor(atCharacter: startChar)
            buffer.insertAtCursor(text: plan.replacement, len: Int(plan.replacement.utf8.count))
        }

        let newText = buffer.text
        let caretChar = CharacterOffsets(text: newText).characterOffset(ofUTF16: plan.caretUTF16)
        placeCursor(atCharacter: caretChar)
        buffer.getIterAtOffset(iter: TextIter(iter), charOffset: caretChar)
    }

    private func placeCursor(atCharacter offset: Int) {
        withIter { iter in
            buffer.getIterAtOffset(iter: iter, charOffset: offset)
            buffer.placeCursor(where: iter)
        }
    }

    private func withIter<R>(_ body: (TextIter) -> R) -> R {
        let storage = UnsafeMutablePointer<GtkTextIter>.allocate(capacity: 1)
        defer { storage.deallocate() }
        return body(TextIter(storage))
    }

    private func withIters<R>(_ body: (TextIter, TextIter) -> R) -> R {
        let first = UnsafeMutablePointer<GtkTextIter>.allocate(capacity: 1)
        let second = UnsafeMutablePointer<GtkTextIter>.allocate(capacity: 1)
        defer { first.deallocate(); second.deallocate() }
        return body(TextIter(first), TextIter(second))
    }
}
