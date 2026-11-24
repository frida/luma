import LumaCore
import SwiftUI

struct CustomInstrumentCompatibilityPopover: View {
    let def: CustomInstrumentDef
    let engine: Engine
    @Environment(\.dismiss) private var dismiss

    @State private var draftPlatforms: Set<String> = []
    @State private var draftOSIDs: Set<String> = []
    @State private var draftArchs: Set<String> = []
    @State private var isCancelled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Compatibility").font(.headline)
            Text("Restrict which devices this instrument can be added to. Leave a section empty to allow any value for that axis.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            axisSection(
                "Platforms",
                known: InstrumentCompatibility.knownPlatforms,
                displayName: InstrumentCompatibility.platformDisplayName,
                selection: $draftPlatforms
            )
            axisSection(
                "Operating Systems",
                known: InstrumentCompatibility.knownOSIDs,
                displayName: InstrumentCompatibility.osDisplayName,
                selection: $draftOSIDs
            )
            axisSection(
                "Architectures",
                known: InstrumentCompatibility.knownArchs,
                displayName: InstrumentCompatibility.archDisplayName,
                selection: $draftArchs
            )

            HStack {
                Spacer()
                Button("Cancel") {
                    isCancelled = true
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Save") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .popoverFormSheet(width: 480)
        .onAppear { syncDraft() }
        .onDisappear {
            if !isCancelled { commit() }
        }
    }

    private func axisSection(
        _ title: String,
        known: [String],
        displayName: @escaping (String) -> String,
        selection: Binding<Set<String>>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: gridColumnMinimum), alignment: .leading)],
                alignment: .leading,
                spacing: 4
            ) {
                ForEach(orderedValues(known: known, extra: selection.wrappedValue), id: \.self) { value in
                    valueToggle(value, displayName: displayName, selection: selection)
                }
            }
        }
    }

    private func valueToggle(_ value: String, displayName: (String) -> String, selection: Binding<Set<String>>) -> some View {
        Toggle(isOn: bindingForValue(value, in: selection)) {
            Text(displayName(value))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .platformCheckboxToggleStyle()
    }

    private var gridColumnMinimum: CGFloat {
        #if canImport(UIKit)
        return 160
        #else
        return 100
        #endif
    }

    private func bindingForValue(_ value: String, in selection: Binding<Set<String>>) -> Binding<Bool> {
        Binding(
            get: { selection.wrappedValue.contains(value) },
            set: { isOn in
                if isOn {
                    selection.wrappedValue.insert(value)
                } else {
                    selection.wrappedValue.remove(value)
                }
            }
        )
    }

    private func orderedValues(known: [String], extra: Set<String>) -> [String] {
        known + extra.subtracting(known).sorted()
    }

    private func syncDraft() {
        draftPlatforms = def.compatibility.platforms ?? []
        draftOSIDs = def.compatibility.osIDs ?? []
        draftArchs = def.compatibility.archs ?? []
    }

    private func commit() {
        let compatibility = InstrumentCompatibility(platforms: draftPlatforms, osIDs: draftOSIDs, archs: draftArchs)
        engine.updateCustomInstrument(def.id) { $0.compatibility = compatibility }
    }
}
