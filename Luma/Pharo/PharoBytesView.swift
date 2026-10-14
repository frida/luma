import LumaCore
import SwiftUI

struct PharoBytesView: View {
    let reference: String

    var body: some View {
        if let bytes = PharoBytesReference(reference) {
            ScrollView(.vertical) {
                HexView(data: bytes.data, baseAddress: bytes.address) {
                    EmptyView()
                }
                .fixedSize(horizontal: true, vertical: false)
                .padding(8)
            }
        } else {
            ContentUnavailableView("These bytes could not be read", systemImage: "square.dashed")
        }
    }
}
