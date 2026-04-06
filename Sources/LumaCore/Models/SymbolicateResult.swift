public enum SymbolicateResult: Hashable, Sendable {
    case failure
    case module(moduleName: String, name: String)
    case file(moduleName: String, name: String, fileName: String, lineNumber: Int)
    case fileColumn(moduleName: String, name: String, fileName: String, lineNumber: Int, column: Int)
}
