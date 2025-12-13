import Foundation

enum AddressAnchor: Codable, Hashable {
    case absolute(UInt64)
    case module(name: String, offset: UInt64)

    var displayString: String {
        switch self {
        case .absolute(let a):
            return String(format: "0x%llx", a)
        case .module(let name, let off):
            return "\(name)+\(String(format: "0x%llx", off))"
        }
    }
}
