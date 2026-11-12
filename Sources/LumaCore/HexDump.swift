import Foundation

public func hexDump(_ data: Data, baseAddress: UInt64 = 0) -> String {
    let bytes = [UInt8](data)
    let bytesPerRow = 16
    let rowStarts = stride(from: 0, to: bytes.count, by: bytesPerRow)
    let lastRowAddress = baseAddress &+ UInt64(max(bytes.count - 1, 0) / bytesPerRow * bytesPerRow)
    let addressDigits = max(8, String(lastRowAddress, radix: 16).count)

    return rowStarts.map { start in
        let row = bytes[start..<min(start + bytesPerRow, bytes.count)]
        let address = String(baseAddress &+ UInt64(start), radix: 16)
        let paddedAddress = String(repeating: "0", count: addressDigits - address.count) + address
        let hexColumns = (0..<bytesPerRow).map { column in
            let index = start + column
            return index < bytes.count ? hexDigits[Int(bytes[index])] : "  "
        }
        let hex = hexColumns[0..<8].joined(separator: " ") + "  " + hexColumns[8...].joined(separator: " ")
        let ascii = String(row.map { (0x20...0x7e).contains($0) ? Character(UnicodeScalar($0)) : "." })
        return "\(paddedAddress)  \(hex)  |\(ascii)|"
    }.joined(separator: "\n")
}

private let hexDigits: [String] = (0...255).map { String(format: "%02x", $0) }
