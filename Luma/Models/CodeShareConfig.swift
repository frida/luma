import CryptoKit
import Foundation
import SwiftyMonaco

struct CodeShareConfig: Codable, Equatable {
    var name: String
    var description: String
    var source: String
    var exports: [String]

    var project: CodeShareProjectRef?
    var lastSyncedHash: String?
    var lastReviewedHash: String?

    var fridaVersion: String?

    var allowRemoteUpdates: Bool

    init(
        name: String,
        description: String,
        source: String,
        exports: [String],
        project: CodeShareProjectRef? = nil,
        lastSyncedHash: String? = nil,
        lastReviewedHash: String? = nil,
        fridaVersion: String? = nil,
        allowRemoteUpdates: Bool = false
    ) {
        self.name = name
        self.description = description
        self.source = source
        self.exports = exports
        self.project = project
        self.lastSyncedHash = lastSyncedHash
        self.lastReviewedHash = lastReviewedHash
        self.fridaVersion = fridaVersion
        self.allowRemoteUpdates = allowRemoteUpdates
    }

    var currentSourceHash: String {
        let data = Data(source.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

struct CodeShareProjectRef: Codable, Equatable {
    let id: String
    let owner: String
    let slug: String

    var url: URL {
        URL(string: "https://codeshare.frida.re/@\(owner)/\(slug)/")!
    }

    var apiEndpoint: URL {
        URL(string: "https://codeshare.frida.re/api/project/\(owner)/\(slug)")!
    }
}

enum CodeShareEditorProfile {
    static let javascript: MonacoEditorProfile = MonacoEditorProfileBuilder()
        .syntax(.monaco(languageId: "javascript"))
        .javascriptCompilerOptions(TypeScriptEnvironment.defaultCompilerOptions)
        .javascriptExtraLibs([
            TypeScriptEnvironment.gumTypeLib
        ])
        .build()
}
