import LumaCore
import SwiftUI

struct StoreUpdateMark: View {
    let item: StoreItem

    var body: some View {
        Image(systemName: "arrow.down.circle")
            .font(.system(size: 10))
            .foregroundStyle(Color.accentColor)
            .help("Version \(item.version.description) is available")
            .accessibilityLabel("Update available")
    }
}

extension Storefront {
    func newerItem(forInstrument instance: LumaCore.InstrumentInstance) -> StoreItem? {
        guard instance.kind == .custom, let defID = UUID(uuidString: instance.sourceIdentifier) else { return nil }
        return newerItem(forCustomInstrument: defID)
    }

    func newerItem(forCustomInstrument defID: UUID) -> StoreItem? {
        linkedInstallation(ofCustomInstrument: defID)?.newerItem
    }
}
