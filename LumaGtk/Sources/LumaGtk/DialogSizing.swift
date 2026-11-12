import Adw
import Gtk

extension Adw.Dialog {
    func sizeToContent(within window: WidgetProtocol) {
        var naturalWidth: Int32 = 0
        child!.measure(orientation: .horizontal, for: -1, natural: &naturalWidth)
        let height = min(window.height, maximumLines * lineHeight)
        let goldenWidth = Int(Double(height) * 1.618)
        set(contentWidth: min(max(Int(naturalWidth), goldenWidth), window.width))
        set(contentHeight: height)
    }

    private var maximumLines: Int { 36 }

    private var lineHeight: Int {
        var height: Int32 = 0
        createPangoLayout(text: "M").getPixelSize(height: &height)
        return Int(height)
    }
}
