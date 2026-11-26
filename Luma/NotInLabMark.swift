import LumaCore
import SwiftUI

struct NotInLabMark: View {
    let reason: String

    var body: some View {
        Text("Not in the lab")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize()
            .help(reason)
    }
}

extension Engine {
    func isKeptFromLab(_ subject: LabSubject) -> Bool {
        collaboration.isCollaborative && subjectsKeptFromLab.contains(subject)
    }
}
