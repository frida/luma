public enum LumaCoreError: Swift.Error {
    case invalidArgument(String)
    case invalidOperation(String)
    case protocolViolation(String)
    case notSupported(String)
}
