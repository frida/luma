import LumaCore
import SwiftUI

struct ExecutorWaitNote: View {
    let executorName: String
    let hold: ObjectChatCallHold?

    var body: some View {
        Text(hold.map { "Waiting: \($0.reason(executorName: executorName))" } ?? "Waiting for \(executorName)")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

extension ObjectChatCallHold {
    func reason(executorName: String) -> String {
        switch self {
        case .executorOffline:
            "\(executorName) is offline."
        case .executorNoLongerHosts(let currentHost):
            "\(executorName) no longer hosts this session" + (currentHost.map { "; \($0.name) does now." } ?? ".")
        case .sessionDetached:
            "the session is not attached."
        }
    }
}
