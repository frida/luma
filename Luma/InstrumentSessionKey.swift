import SwiftUI

private struct InstrumentSessionKey: EnvironmentKey {
    static let defaultValue: ProcessSession? = nil
}

extension EnvironmentValues {
    var instrumentSession: ProcessSession? {
        get { self[InstrumentSessionKey.self] }
        set { self[InstrumentSessionKey.self] = newValue }
    }
}
