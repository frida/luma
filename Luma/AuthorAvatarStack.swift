import LumaCore
import SwiftUI

struct AuthorAvatarStack: View {
    let authors: [Author]
    var avatarSize: CGFloat = 20

    var body: some View {
        if !authors.isEmpty {
            HStack(spacing: -avatarSize * 0.4) {
                ForEach(Array(authors.enumerated()), id: \.element.id) { index, author in
                    AuthorAvatar(author: author, size: avatarSize)
                        .zIndex(Double(authors.count - index))
                }
            }
        }
    }
}

struct AuthorAvatar: View {
    let author: Author
    var size: CGFloat = 20

    var body: some View {
        AsyncImage(url: URL(string: author.avatarURL)) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                Image(systemName: "person.crop.circle")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.platformWindowBackground, lineWidth: 2))
        .help(displayName)
        .onTapGesture {
            if let url = URL(string: "https://github.com/\(author.id)") {
                Platform.openURL(url)
            }
        }
    }

    private var displayName: String {
        author.name.isEmpty ? "@\(author.id)" : author.name
    }
}
