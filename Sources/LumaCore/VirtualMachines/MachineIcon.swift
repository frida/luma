import Foundation
import Frida

enum MachineIcon {
    static func named(_ name: String) -> Icon? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "MachineIcons"),
            let data = try? Data(contentsOf: url)
        else {
            return nil
        }
        return .png(data: [UInt8](data))
    }
}
