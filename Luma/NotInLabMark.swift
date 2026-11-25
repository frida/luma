import LumaCore
import SwiftUI

struct NotInLabMark: View {
    var body: some View {
        Text("Not in the lab")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize()
            .help(
                "A member deleted it in the lab after you changed it, so your version is kept only here. "
                    + "Add it to the lab again, or delete it.")
    }
}

extension Engine {
    func isKeptFromLab(_ subject: LabSubject) -> Bool {
        collaboration.isCollaborative && subjectsKeptFromLab.contains(subject)
    }
}
