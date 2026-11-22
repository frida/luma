import Foundation

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public struct HostCode: Sendable, Equatable {
    public let digest: String
    public let files: [CustomInstrumentFile]

    public init?(files: [CustomInstrumentFile]) {
        let smalltalk = files
            .filter { Self.isHostCode($0.path) }
            .sorted { Array($0.path.utf8).lexicographicallyPrecedes(Array($1.path.utf8)) }
        guard !smalltalk.isEmpty else { return nil }

        var hasher = SHA256()
        for file in smalltalk {
            let content = Data(file.content.utf8)
            hasher.update(data: Data(file.path.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: Data(String(content.count).utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: content)
        }
        digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        self.files = smalltalk
    }

    public static func isHostCode(_ path: String) -> Bool {
        path.hasSuffix(".st")
    }
}
