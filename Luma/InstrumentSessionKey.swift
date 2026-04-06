import LumaCore
import SwiftUI

private struct InstrumentSessionKey: EnvironmentKey {
    static let defaultValue: LumaCore.ProcessSession? = nil
}

extension EnvironmentValues {
    var instrumentSession: LumaCore.ProcessSession? {
        get { self[InstrumentSessionKey.self] }
        set { self[InstrumentSessionKey.self] = newValue }
    }
}
