struct ProcessModule: Hashable, Identifiable {
    var id: String { "\(path)@0x\(String(base, radix: 16))" }
    let name: String
    let path: String
    let base: UInt64
    let size: UInt64
}
