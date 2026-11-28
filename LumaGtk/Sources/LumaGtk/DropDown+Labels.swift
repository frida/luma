import CGLib
import Gtk

extension DropDown {
    static func listing(_ labels: [String]) -> DropDown {
        withNullTerminatedCopies(of: labels) { DropDown(strings: $0) }
    }
}

extension StringList {
    static func listing(_ labels: [String]) -> StringList {
        withNullTerminatedCopies(of: labels) { StringList(strings: $0) }
    }
}

private func withNullTerminatedCopies<Result>(of strings: [String], _ body: (UnsafePointer<UnsafePointer<CChar>?>) -> Result) -> Result {
    let copies = strings.map { g_strdup($0) }
    defer { copies.forEach { g_free($0) } }
    let pointers = copies.map { UnsafePointer($0) } + [nil]
    return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
}
