import Foundation

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public struct InstrumentFolderLink: Codable, Equatable, Sendable {
    public var path: String
    public var synced: Snapshot

    public init(path: String, synced: Snapshot) {
        self.path = path
        self.synced = synced
    }

    public var folderURL: URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }

    public struct Snapshot: Codable, Equatable, Sendable {
        public var definition: String
        public var files: [String: String]

        public init(of instrument: CustomInstrumentBundle) {
            var definition = instrument.def.toJSON()
            for key in ["id", "created_at", "updated_at"] {
                definition.removeValue(forKey: key)
            }
            self.definition = Self.digest(try! JSONSerialization.data(withJSONObject: definition, options: [.sortedKeys]))
            files = Dictionary(uniqueKeysWithValues: instrument.files.map { ($0.path, Self.digest(Data($0.content.utf8))) })
        }

        static func digest(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }
}

public enum InstrumentFolderDrift: Sendable, Equatable {
    case folderChanged
    case diverged
}
