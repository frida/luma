import CGtk
import Gtk

extension Widget {
    func centreOnFirstMonospaceLine() {
        valign = .start
        marginTop = max(0, (Self.monospaceLineHeight - naturalSize(along: .vertical)) / 2)
    }

    private static var monospaceLineHeight: Int {
        let line = Label(str: " ")
        line.add(cssClass: "monospace")
        return line.naturalSize(along: .vertical)
    }

    func naturalSize(along orientation: Orientation) -> Int {
        var size: gint = 0
        measure(orientation: orientation, for: -1, natural: &size)
        return Int(size)
    }
}
