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

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                if let png = cell.png, let image = NSImage(data: png) {
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: 16, height: 16)
                } else {
                    Text(cell.text ?? "")
                }
            }

            Spacer(minLength: 0)
        }
    }
}
