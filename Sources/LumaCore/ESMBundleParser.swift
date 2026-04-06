import Foundation

public struct ESMModules: Sendable {
    public let modules: [String: String]
    public let order: [String]

    public init(modules: [String: String], order: [String]) {
        self.modules = modules
        self.order = order
    }
}

public enum ESMBundleParser {
    public static func parse(_ bundle: String) throws -> ESMModules {
        let headerPrefix = "📦\n"
        let separator = "✄\n"

        guard bundle.hasPrefix(headerPrefix) else {
            throw ESMBundleError.invalidFormat
        }

        guard let separatorRange = bundle.range(of: "\n" + separator) else {
            throw ESMBundleError.headerNotFound
        }

        let headerString = String(bundle[..<separatorRange.lowerBound])
        let headerAndSepString = String(bundle[..<separatorRange.upperBound])

        guard let bundleData = bundle.data(using: .utf8) else {
            throw ESMBundleError.encodingError
        }
        let headerAndSepByteCount = headerAndSepString.utf8.count

        let bodyBytes = bundleData[headerAndSepByteCount...]
        let separatorData = separator.data(using: .utf8)!
        let separatorLength = separatorData.count

        var descriptors: [(path: String, size: Int)] = []

        let headerLines = headerString.split(separator: "\n", omittingEmptySubsequences: false)
        guard headerLines.first == "📦" else {
            throw ESMBundleError.invalidFormat
        }

        for line in headerLines.dropFirst() {
            if line.isEmpty {
                throw ESMBundleError.invalidFormat
            }

            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let size = Int(parts[0]) else {
                throw ESMBundleError.invalidHeaderLine(String(line))
            }

            let path = String(parts[1])
            descriptors.append((path: path, size: size))
        }

        if descriptors.isEmpty {
            throw ESMBundleError.emptyBundle
        }

        var modules: [String: String] = [:]
        var order: [String] = []

        var cursor = bodyBytes.startIndex

        for (index, desc) in descriptors.enumerated() {
            let remaining = bodyBytes.distance(from: cursor, to: bodyBytes.endIndex)
            guard remaining >= desc.size else {
                throw ESMBundleError.sizeOutOfRange
            }

            let start = cursor
            let end = bodyBytes.index(start, offsetBy: desc.size)
            let fileData = bodyBytes[start..<end]

            guard let source = String(data: fileData, encoding: .utf8) else {
                throw ESMBundleError.encodingError
            }

            modules[desc.path] = source
            order.append(desc.path)

            cursor = end

            if index < descriptors.count - 1 {
                let remainingAfterFile = bodyBytes.distance(from: cursor, to: bodyBytes.endIndex)
                guard remainingAfterFile >= separatorLength else {
                    throw ESMBundleError.invalidSeparator
                }

                let sepEnd = bodyBytes.index(cursor, offsetBy: separatorLength)
                let sepSlice = bodyBytes[cursor..<sepEnd]
                if sepSlice != separatorData {
                    throw ESMBundleError.invalidSeparator
                }

                cursor = sepEnd
            }
        }

        guard cursor == bodyBytes.endIndex else {
            throw ESMBundleError.trailingData
        }

        return ESMModules(modules: modules, order: order)
    }
}

public enum ESMBundleError: Swift.Error {
    case invalidFormat
    case headerNotFound
    case invalidHeaderLine(String)
    case emptyBundle
    case encodingError
    case sizeOutOfRange
    case invalidSeparator
    case trailingData
}
