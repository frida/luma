import Foundation
import Gtk

@MainActor
enum HexBytesView {
    static func make(bytes: Data, baseAddress: UInt64 = 0, maxHeight: Int = 280) -> Widget {
        let label = Label(str: formatHexdump(data: bytes, baseAddress: baseAddress))
        label.add(cssClass: "monospace")
        label.halign = .start
        label.valign = .start
        label.selectable = true
        label.wrap = false

        let scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.vexpand = false
        scroll.setSizeRequest(width: -1, height: maxHeight)
        scroll.set(child: label)
        return scroll
    }

    static func formatHexdump(data: Data, baseAddress: UInt64) -> String {
        guard !data.isEmpty else { return "(no data)" }

        var out = ""
        out.reserveCapacity(data.count * 4)
        let lineCount = (data.count + 15) / 16

        for line in 0..<lineCount {
            let offset = line * 16
            let lineEnd = min(offset + 16, data.count)
            let lineLen = lineEnd - offset

            out += String(format: "0x%016llx  ", baseAddress + UInt64(offset))

            for i in 0..<16 {
                if i == 8 { out += " " }
                if i < lineLen {
                    out += String(format: "%02x ", data[offset + i])
                } else {
                    out += "   "
                }
            }

            out += " |"
            for i in 0..<lineLen {
                let byte = data[offset + i]
                if byte >= 0x20 && byte < 0x7f {
                    out.append(Character(UnicodeScalar(byte)))
                } else {
                    out.append(".")
                }
            }
            out += "|\n"
        }

        return out
    }
}
