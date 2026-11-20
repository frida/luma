import Foundation

public struct VirtualMachineCommandLine: Sendable, Equatable {
    public let executable: URL
    public let arguments: [String]

    public var text: String {
        var lines = [Self.quoted(executable.path)]
        for argument in arguments.map(Self.quoted) {
            if argument.hasPrefix("-") || lines.count == 1 {
                lines.append(argument)
            } else {
                lines[lines.count - 1] += " " + argument
            }
        }
        return lines.joined(separator: " \\\n    ")
    }

    private static func quoted(_ word: String) -> String {
        guard word.isEmpty || word.contains(where: { !safeCharacters.contains($0) }) else { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static let safeCharacters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-+=/.,:@%")
}
