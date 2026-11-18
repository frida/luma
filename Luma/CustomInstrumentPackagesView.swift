import LumaCore
import SwiftUI

struct CustomInstrumentPackagesPopover: View {
    let def: CustomInstrumentDef
    let engine: Engine
    @Binding var selection: SidebarItemID?
    @Environment(\.dismiss) private var dismiss

    @State private var isShowingPackageSearch = false

    private var dependencies: [String: String] {
        engine.customInstruments.def(withId: def.id)?.dependencies ?? def.dependencies
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Packages").font(.headline)
            Text("Packages this instrument imports. They are installed for this instrument alone and travel with it, ahead of the packages installed for the whole project.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if dependencies.isEmpty {
                Text("This instrument does not depend on any packages.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(dependencies.keys.sorted(), id: \.self) { name in
                        dependencyRow(name: name, versionSpec: dependencies[name]!)
                    }
                }
            }

            HStack {
                Button("Add Package\u{2026}") { isShowingPackageSearch = true }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .popoverFormSheet(width: 420)
        .sheet(isPresented: $isShowingPackageSearch) {
            VStack(alignment: .leading) {
                Text("Add Package")
                    .font(.title2)
                    .bold()
                    .padding(.bottom, 8)

                PackageSearchView(engine: engine, selection: $selection) { name, versionSpec in
                    setDependency(name: name, versionSpec: versionSpec)
                }
            }
            .padding()
        }
    }

    private func dependencyRow(name: String, versionSpec: String) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(versionSpec)
                .foregroundStyle(.secondary)
            Button {
                setDependency(name: name, versionSpec: nil)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .help("Remove Package")
        }
    }

    private func setDependency(name: String, versionSpec: String?) {
        guard var updated = engine.customInstruments.def(withId: def.id) else { return }
        updated.dependencies[name] = versionSpec
        engine.updateCustomInstrument(updated)
    }
}
