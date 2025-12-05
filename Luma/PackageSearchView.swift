import Frida
import SwiftData
import SwiftUI

struct PackageSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @ObservedObject var workspace: Workspace
    @Binding var selection: SidebarItemID?

    @Query private var packageStates: [ProjectPackagesState]

    @State private var query: String = ""
    @State private var results: [Package] = []
    @State private var isSearching = false
    @State private var isInstalling = false
    @State private var selectedPackage: Package?
    @State private var packageSpecifier: String = ""
    @State private var globalAlias: String = ""
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    @FocusState private var isSearchFieldFocused: Bool

    private var canonicalizedPackageSpecifier: String {
        packageSpecifier.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canonicalizedGlobalAlias: String {
        globalAlias.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canInstall: Bool {
        (!canonicalizedPackageSpecifier.isEmpty || selectedPackage != nil) && !isInstalling
    }

    private let manager = PackageManager()

    private var projectPackages: ProjectPackagesState {
        if let state = packageStates.first {
            return state
        }
        let newState = ProjectPackagesState()
        modelContext.insert(newState)
        return newState
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Search npm registry…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isInstalling)
                    .focused($isSearchFieldFocused)

                if isSearching {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            List(selection: $selectedPackage) {
                ForEach(results, id: \.self) { pkg in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pkg.name)
                            .font(.headline)
                        Text(pkg.version)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let desc = pkg.descriptionText {
                            Text(desc)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .tag(pkg as Package?)
                }
            }

            LabeledContent("Install:") {
                TextField("name or name@version", text: $packageSpecifier)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isInstalling)
            }
            .font(.callout)
            .help("Enter a package name or name@version to install.")

            LabeledContent("Global alias:") {
                TextField("optional, e.g. ObjC", text: $globalAlias)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isInstalling)
            }
            .font(.callout)
            .help("Optional global alias to expose the package as a global (e.g. ObjC, Java, Swift).")

            if isInstalling {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Installing…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }

            ToolbarItem(placement: .confirmationAction) {
                Button("Add Package") {
                    installPackage()
                }
                .disabled(!canInstall)
            }
        }
        .onAppear {
            isSearchFieldFocused = true
        }
        .onChange(of: query) { _, newValue in
            Task {
                await performSearchDebounced(query: newValue)
            }
        }
        .onChange(of: selectedPackage) { _, pkg in
            if let pkg {
                packageSpecifier = "\(pkg.name)@\(pkg.version)"

                if canonicalizedGlobalAlias.isEmpty,
                    let alias = defaultGlobalAlias(forPackageName: pkg.name)
                {
                    globalAlias = alias
                }
            }
        }

    }

    @MainActor
    private func performSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            results = []
            statusMessage = nil
            errorMessage = nil
            isSearching = false
            return
        }

        isSearching = true
        errorMessage = nil
        statusMessage = "Searching…"
        results = []

        defer { isSearching = false }

        do {
            let options = PackageSearchOptions()
            options.limit = 25
            let result = try await manager.search(query: trimmed, options: options)
            results = result.packages

            if result.packages.isEmpty {
                statusMessage = "No packages found."
            } else {
                statusMessage = "Found \(result.packages.count) packages."
            }
        } catch {
            errorMessage = "Search failed: \(error.localizedDescription)"
            statusMessage = nil
        }
    }

    private func performSearchDebounced(query: String) async {
        try? await Task.sleep(nanoseconds: 300_000_000)
        if query == self.query {
            await performSearch()
        }
    }

    private func installPackage() {
        Task { @MainActor in
            let rawSpec = canonicalizedPackageSpecifier

            let name: String
            let versionSpec: String

            if !rawSpec.isEmpty {
                let parsed = parsePackageSpecifier(rawSpec)
                guard !parsed.name.isEmpty else { return }

                name = parsed.name
                versionSpec = parsed.versionSpec ?? "latest"
            } else if let pkg = selectedPackage {
                name = pkg.name
                versionSpec = pkg.version
            } else {
                return
            }

            let aliasText = canonicalizedGlobalAlias
            let alias: String? = !aliasText.isEmpty ? aliasText : nil

            isInstalling = true
            errorMessage = nil
            statusMessage = "Installing \(name)@\(versionSpec)…"
            defer { isInstalling = false }

            do {
                let installed = try await workspace.installPackage(
                    name: name,
                    versionSpec: versionSpec,
                    globalAlias: alias
                )
                statusMessage = "Installed \(name)@\(versionSpec)."

                selection = .package(installed.id)

                dismiss()
            } catch {
                errorMessage = "Install failed: \(error.localizedDescription)"
                statusMessage = nil
            }
        }
    }

}

private func parsePackageSpecifier(_ spec: String) -> (name: String, versionSpec: String?) {
    if let atIndex = spec.lastIndex(of: "@"),
        atIndex != spec.startIndex
    {
        let namePart = String(spec[..<atIndex])
        let versionPart = String(spec[spec.index(after: atIndex)...])

        if !namePart.isEmpty, !versionPart.isEmpty {
            return (namePart, versionPart)
        }
    }

    return (spec, nil)
}

private func defaultGlobalAlias(forPackageName name: String) -> String? {
    switch name {
    case "frida-objc-bridge": return "ObjC"
    case "frida-java-bridge": return "Java"
    case "frida-swift-bridge": return "Swift"
    default: return nil
    }
}
