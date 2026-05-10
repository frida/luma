import LumaCore
import SwiftUI

private struct InstrumentSessionKey: EnvironmentKey {
    static let defaultValue: LumaCore.ProcessSession? = nil
}

private struct InstrumentInstanceKey: EnvironmentKey {
    static let defaultValue: LumaCore.InstrumentInstance? = nil
}

extension EnvironmentValues {
    var instrumentSession: LumaCore.ProcessSession? {
        get { self[InstrumentSessionKey.self] }
        set { self[InstrumentSessionKey.self] = newValue }
    }

    var instrumentInstance: LumaCore.InstrumentInstance? {
        get { self[InstrumentInstanceKey.self] }
        set { self[InstrumentInstanceKey.self] = newValue }
    }
}
