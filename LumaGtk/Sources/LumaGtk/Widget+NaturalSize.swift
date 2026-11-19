import CGtk
import Gtk

extension Widget {
    func naturalSize(along orientation: Orientation) -> Int {
        var size: gint = 0
        measure(orientation: orientation, for: -1, natural: &size)
        return Int(size)
    }
}
