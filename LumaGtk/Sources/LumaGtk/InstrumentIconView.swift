import Foundation
import Gtk
import LumaCore

@MainActor
enum InstrumentIconView {
    static func make(for descriptor: InstrumentDescriptor) -> Widget {
        let box = Box(orientation: .horizontal, spacing: 6)
        let image = makeImage(for: descriptor.icon)
        image.pixelSize = 16
        box.append(child: image)
        return box
    }

    private static func makeImage(for icon: InstrumentIcon) -> Image {
        switch icon {
        case .file(let url):
            return Image(file: url.path)
        case .system(let name):
            return Image(iconName: gtkIconName(forSFSymbol: name))
        }
    }

    private static func gtkIconName(forSFSymbol name: String) -> String {
        switch name {
        case "puzzlepiece.extension":
            return "application-x-addon-symbolic"
        case "waveform":
            return "audio-x-generic-symbolic"
        case "doc.text":
            return "text-x-generic-symbolic"
        case "bolt":
            return "weather-storm-symbolic"
        default:
            return "application-x-executable-symbolic"
        }
    }
}
