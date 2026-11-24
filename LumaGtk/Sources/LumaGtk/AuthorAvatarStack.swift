import Adw
import Foundation
import Gtk
import LumaCore

@MainActor
enum AuthorAvatarStack {
    static func make(_ authors: [LumaCore.Author], size avatarSize: Int) -> Widget {
        let overlap = 8
        let step = avatarSize - overlap
        let totalWidth = avatarSize + (authors.count - 1) * step

        let fixed = Fixed()
        fixed.setSizeRequest(width: totalWidth, height: avatarSize)
        fixed.halign = .start
        fixed.valign = .center

        for index in (0..<authors.count).reversed() {
            let x = Double(index * step)
            fixed.put(widget: avatar(of: authors[index], size: avatarSize), x: x, y: 0)
        }

        return fixed
    }

    private static func avatar(of author: LumaCore.Author, size: Int) -> Button {
        let name = author.name.isEmpty ? "@\(author.id)" : author.name
        let button = Button()
        button.hasFrame = false
        button.add(cssClass: "flat")
        button.add(cssClass: "luma-avatar-button")
        button.tooltipText = name

        button.set(child: picture(of: author, size: size))

        let profileURL = "https://github.com/\(author.id)"
        button.onClicked { clicked in
            MainActor.assumeIsolated {
                let launcher = UriLauncher(uri: profileURL)
                let parentWindow: Gtk.WindowRef?
                if let rootPtr = clicked.root?.ptr {
                    parentWindow = Gtk.WindowRef(raw: rootPtr)
                } else {
                    parentWindow = nil
                }
                launcher.launch(parent: parentWindow, cancellable: nil, callback: nil, userData: nil)
            }
        }

        return button
    }

    static func picture(of author: LumaCore.Author, size: Int) -> Adw.Avatar {
        let avatar = Adw.Avatar(size: size, text: author.name.isEmpty ? "@\(author.id)" : author.name, showInitials: true)
        avatar.add(cssClass: "luma-editor-avatar")
        if !author.avatarURL.isEmpty,
            let url = URL(string: "\(author.avatarURL)&s=48")
        {
            Task { @MainActor [avatar] in
                guard let texture = await AvatarCache.shared.texture(for: url) else { return }
                avatar.set(customImage: texture)
            }
        }
        return avatar
    }
}
