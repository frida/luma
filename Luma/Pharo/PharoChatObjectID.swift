import LumaCore
import SwiftUI

struct PharoChatObjectID: View {
    let objectID: String
    let collaboration: CollaborationSession

    var body: some View {
        HStack(spacing: 3) {
            Text(base)
            if let maker, !collaboration.isSelf(maker) {
                makerMark(maker)
            }
        }
    }

    private var base: Substring {
        objectID.split(separator: ".", maxSplits: 1)[0]
    }

    private var maker: String? {
        let parts = objectID.split(separator: ".", maxSplits: 1)
        return parts.count > 1 ? String(parts[1]) : nil
    }

    @ViewBuilder
    private func makerMark(_ maker: String) -> some View {
        if let user = collaboration.members.first(where: { $0.user.id == maker })?.user {
            AuthorAvatar(author: Author(id: user.id, name: user.name, avatarURL: user.avatarURL?.absoluteString ?? ""), size: 12)
                .help("Made in \(user.name)'s Luma")
        } else {
            Text("@\(maker)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .help("Made in @\(maker)'s Luma")
        }
    }
}
