import LumaCore
import SwiftUI

struct UserAvatarView: View {
    let user: LumaCore.CollaborationSession.UserInfo
    let size: CGFloat

    var body: some View {
        Group {
            if let url = sizedAvatarURL {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.secondary.opacity(0.15)
                }
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(
            Circle().strokeBorder(Color.secondary.opacity(0.3), lineWidth: 0.5)
        )
    }

    private var sizedAvatarURL: URL? {
        let pixels = Int(size * 2)
        return user.avatarURL.flatMap { URL(string: "\($0.absoluteString)&s=\(pixels)") }
    }
}
