import LumaCore
import SwiftUI
import SwiftyPharo

/// What one row of a view holds: a cell per column, each words or a picture.
protocol PharoCellContent {
    var text: String? { get }
    var png: Data? { get }
}

extension PharoCell: PharoCellContent {}

extension PharoSnapshot.View.Cell: PharoCellContent {}

struct PharoRowView: View {
    let cells: [any PharoCellContent]
    /// The widest leading cell in the view, so every row's second column starts
    /// in the same place instead of wherever its own key happens to end.
    let leadingCharacters: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(cells.enumerated()), id: \.offset) { column, cell in
                content(of: cell)
                    .frame(width: column == 0 ? leadingWidth : nil, alignment: .leading)
            }

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func content(of cell: any PharoCellContent) -> some View {
        if let png = cell.png, let image = NSImage(data: png) {
            Image(nsImage: image)
                .resizable()
                .frame(width: 16, height: 16)
        } else {
            Text(cell.text ?? "")
        }
    }

    private var leadingWidth: CGFloat? {
        guard cells.count > 1, leadingCharacters > 0 else { return nil }
        return CGFloat(leadingCharacters) * PharoRowView.characterWidth
    }

    private static let characterWidth = NSFont
        .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        .maximumAdvancement.width
}
