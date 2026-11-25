import LumaCore
import SwiftUI

struct NotInLabMark: View {
    var reason =
        "A member deleted it in the lab after you changed it, so your version is kept only here. "
        + "Add it to the lab again, or delete it."

    var body: some View {
        Text("Not in the lab")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize()
            .help(reason)
    }
}

extension NotInLabMark {
    static let localOnlyChat = NotInLabMark(
        reason: "This chat is about a session only you have, so the lab does not have the chat either.")
}

extension Engine {
    func isKeptFromLab(_ subject: LabSubject) -> Bool {
        collaboration.isCollaborative && subjectsKeptFromLab.contains(subject)
    }
}
