public enum TracerTargetScope: String, CaseIterable, Codable, Sendable {
    case function
    case relativeFunction = "relative-function"
    case absoluteInstruction = "absolute-instruction"
    case imports
    case module
    case objcMethod = "objc-method"
    case swiftFunc = "swift-func"
    case debugSymbol = "debug-symbol"

    public var label: String {
        switch self {
        case .function: return "Function"
        case .relativeFunction: return "Relative Function"
        case .absoluteInstruction: return "Instruction"
        case .imports: return "All Module Imports"
        case .module: return "All Module Exports"
        case .objcMethod: return "Objective-C Method"
        case .swiftFunc: return "Swift Function"
        case .debugSymbol: return "Debug Symbol"
        }
    }

    public var placeholder: String {
        switch self {
        case .function: return "[Module!]Function"
        case .relativeFunction: return "Module!Offset"
        case .absoluteInstruction: return "0x1234"
        case .imports, .module: return "Module"
        case .objcMethod: return "-[*Auth foo:bar:], +[Foo foo*], or *[Bar baz]"
        case .swiftFunc: return "*SomeModule*!SomeClassPrefix*.*secret*()"
        case .debugSymbol: return "Function"
        }
    }
}
