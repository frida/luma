import Foundation
import SwiftData

@Model
final class AddressInsight {
    var id = UUID()
    var createdAt: Date = Date()

    var title: String
    var kind: Kind
    var byteCount: Int
    var lastResolvedAddress: UInt64?

    var anchor: AddressAnchor {
        get {
            switch AnchorKind(rawValue: anchorKindRaw) ?? .absolute {
            case .absolute:
                return .absolute(anchorAbsolute)

            case .moduleOffset:
                return .moduleOffset(name: anchorModuleName, offset: anchorModuleOffset)

            case .moduleExport:
                return .moduleExport(name: anchorModuleName, export: anchorExportName)
            }
        }
        set {
            switch newValue {
            case .absolute(let a):
                anchorKindRaw = AnchorKind.absolute.rawValue
                anchorAbsolute = a
                anchorModuleName = ""
                anchorModuleOffset = 0
                anchorExportName = ""

            case .moduleOffset(let name, let off):
                anchorKindRaw = AnchorKind.moduleOffset.rawValue
                anchorAbsolute = 0
                anchorModuleName = name
                anchorModuleOffset = off
                anchorExportName = ""

            case .moduleExport(let name, let export):
                anchorKindRaw = AnchorKind.moduleExport.rawValue
                anchorAbsolute = 0
                anchorModuleName = name
                anchorModuleOffset = 0
                anchorExportName = export
            }
        }
    }

    var session: ProcessSession?

    enum Kind: Int, Codable {
        case memory
        case disassembly
    }

    private enum AnchorKind: Int {
        case absolute
        case moduleOffset
        case moduleExport
    }

    private var anchorKindRaw: Int
    private var anchorAbsolute: UInt64
    private var anchorModuleName: String
    private var anchorModuleOffset: UInt64
    private var anchorExportName: String

    init(title: String, kind: Kind, anchor: AddressAnchor, byteCount: Int = 0x200) {
        self.title = title
        self.kind = kind
        self.byteCount = byteCount

        self.anchorKindRaw = AnchorKind.absolute.rawValue
        self.anchorAbsolute = 0
        self.anchorModuleName = ""
        self.anchorModuleOffset = 0
        self.anchorExportName = ""

        self.anchor = anchor
    }
}
