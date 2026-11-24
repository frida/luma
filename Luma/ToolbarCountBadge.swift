import SwiftUI

struct ToolbarCountBadge: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text("\(count)")
                .font(.caption2.bold())
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.red, in: Capsule())
                .foregroundStyle(.white)
                .offset(y: -6)
        }
    }
}
