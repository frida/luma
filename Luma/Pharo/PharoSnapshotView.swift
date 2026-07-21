import LumaCore
import SwiftUI

/// What a cell's last run produced, rendered without a VM. Same shape as the
/// live inspector, minus the drilling: a snapshot has no objects to open.
struct PharoSnapshotView: View {
    let snapshot: PharoSnapshot

    @State private var shown: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if snapshot.views.count > 1 {
                Picker("", selection: $shown) {
                    ForEach(snapshot.views, id: \.methodSelector) { view in
                        Text(view.title).tag(Optional(view.methodSelector))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(6)
            }

            Divider()
            body(of: shownView)
        }
        .onAppear { shown = shown ?? snapshot.views.first?.methodSelector }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(snapshot.printString)
                .font(.headline)
                .lineLimit(2)
                .accessibilityIdentifier("pharo.snapshot.printString")
            Text(snapshot.className)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(8)
    }

    @ViewBuilder
    private func body(of view: PharoSnapshot.View?) -> some View {
        switch view?.content {
        case .items(let kept, let total):
            List {
                ForEach(Array(kept.enumerated()), id: \.offset) { _, row in
                    PharoRowView(cells: row)
                }

                if kept.count < total {
                    Text("\(total - kept.count) more, kept out of the snapshot")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        case .text(let text):
            ScrollView {
                Text(text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
        case .empty, .none:
            ContentUnavailableView("Nothing captured", systemImage: "square.dashed")
        }
    }

    private var shownView: PharoSnapshot.View? {
        snapshot.views.first { $0.methodSelector == shown } ?? snapshot.views.first
    }
}
