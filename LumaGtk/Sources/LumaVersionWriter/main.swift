import Foundation

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write(Data("usage: luma-version-writer <version> <output>\n".utf8))
    exit(1)
}

let content = """
    enum LumaVersion {
        static let string = "\(args[1])"
    }

    """

try content.write(toFile: args[2], atomically: true, encoding: .utf8)
