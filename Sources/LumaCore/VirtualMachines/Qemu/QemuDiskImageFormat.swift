import Foundation

enum QemuDiskImageFormat: String {
    case qcow2
    case vmdk
    case vpc
    case raw

    static func of(_ path: String) -> QemuDiskImageFormat {
        guard let file = FileHandle(forReadingAtPath: path) else { return .raw }
        defer { try? file.close() }

        let head = (try? file.read(upToCount: 8)) ?? Data()
        if head.starts(with: [0x51, 0x46, 0x49, 0xfb]) { return .qcow2 }
        if head.starts(with: "KDMV".utf8) || head.starts(with: "# Disk D".utf8) { return .vmdk }
        if head.starts(with: "conectix".utf8) { return .vpc }

        if let size = try? file.seekToEnd(), size >= 512 {
            try? file.seek(toOffset: size - 512)
            let footer = (try? file.read(upToCount: 8)) ?? Data()
            if footer.starts(with: "conectix".utf8) { return .vpc }
        }

        return .raw
    }
}
