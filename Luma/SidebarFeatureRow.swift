import LumaCore
import SwiftUI

struct SidebarFeatureRowLabel<Icon: View, Accessory: View>: View {
    @ViewBuilder var icon: () -> Icon
    let title: String
    var isDimmed: Bool = false
    var help: String = ""
    var indent: CGFloat = sidebarGrandchildIndent
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 6) {
            icon()
                .frame(width: sidebarChildIconWidth, alignment: .center)
                .foregroundStyle(.secondary)
            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)
            accessory()
            Spacer()
        }
        .font(.callout)
        .contentShape(Rectangle())
        .padding(.leading, indent)
        .opacity(isDimmed ? 0.5 : 1)
        .help(help)
    }
}

extension SidebarFeatureRowLabel where Accessory == EmptyView {
    init(
        @ViewBuilder icon: @escaping () -> Icon,
        title: String,
        isDimmed: Bool = false,
        help: String = "",
        indent: CGFloat = sidebarGrandchildIndent
    ) {
        self.init(icon: icon, title: title, isDimmed: isDimmed, help: help, indent: indent, accessory: { EmptyView() })
    }
}

struct SidebarBrowseAllRow<Popover: View>: View {
    let count: Int
    var indent: CGFloat = sidebarGrandchildIndent
    @ViewBuilder var popover: (_ dismiss: @escaping () -> Void) -> Popover

    @State private var isShowing = false

    var body: some View {
        Button {
            isShowing = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "ellipsis.circle")
                    .frame(width: sidebarChildIconWidth, alignment: .center)
                    .foregroundStyle(.secondary)
                Text("Browse all \(count)\u{2026}")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .font(.callout)
        .contentShape(Rectangle())
        .padding(.leading, indent)
        .popover(isPresented: $isShowing, arrowEdge: .trailing) {
            popover({ isShowing = false })
        }
    }
}
